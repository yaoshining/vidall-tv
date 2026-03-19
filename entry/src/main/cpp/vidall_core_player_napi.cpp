#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>
#include <cctype>
#include <algorithm>
#include <mutex>
#include <thread>
#include <queue>
#include <condition_variable>
#include <atomic>

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/avplayer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <hilog/log.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>  // B4：PCM 格式转换（fltp/s16/etc → s16 for OH_AudioRenderer）
#include <libswscale/swscale.h>        // B6：视频像素格式转换（yuv420p10le/etc → yuv420p，修复 HDR/DV 黑屏）
}

#if !defined(VIDALL_HAS_LIBCURL)
#define VIDALL_HAS_LIBCURL 0
#endif

#if VIDALL_HAS_LIBCURL
#include <curl/curl.h>
#endif

// B3：EGL + OpenGL ES 2.0（YUV 渲染管线）
#include <EGL/egl.h>
#include <EGL/eglext.h>  // EGL_OPENGL_ES3_BIT_KHR
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
// GL_RED / GL_R8 在 GLES 2.0 头文件中未定义，GLES 3.0 引入；此处补充宏定义供 GLES 3 context 使用。
#ifndef GL_RED
#  define GL_RED 0x1903
#endif
#ifndef GL_R8
#  define GL_R8 0x8229
#endif
// EGL_OPENGL_ES3_BIT 在部分旧版 EGL 头中仅以 KHR 扩展名存在；补充宏定义确保可用。
#ifndef EGL_OPENGL_ES3_BIT
#  define EGL_OPENGL_ES3_BIT EGL_OPENGL_ES3_BIT_KHR
#endif

// B4：OH_AudioRenderer（PCM 送显）
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

namespace {

constexpr bool kEnableNativeSubtitleDiagLog = false;
constexpr int64_t kDefaultAudioHardwareSafetyOffsetMs = 120;

static void ThrowTypeError(napi_env env, const char *message);
static bool ReadUtf8String(napi_env env, napi_value value, std::string &output);

struct ProbeInterruptContext {
  int64_t startTimeUs = 0;
  int64_t timeoutUs = 0;
};

struct FfprobeAsyncContext {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string url;
  std::string headerLines;
  int64_t timeoutMs = 0;
  std::string jsonResult;
  std::string errorMessage;
};

static int ProbeInterruptCallback(void *opaque) {
  if (opaque == nullptr) {
    return 0;
  }
  ProbeInterruptContext *context = static_cast<ProbeInterruptContext *>(opaque);
  if (context->timeoutUs <= 0) {
    return 0;
  }
  const int64_t nowUs = av_gettime_relative();
  if (nowUs - context->startTimeUs >= context->timeoutUs) {
    return 1;
  }
  return 0;
}

static std::string JsonEscape(const std::string &value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (char ch : value) {
    switch (ch) {
      case '\\':
        escaped += "\\\\";
        break;
      case '"':
        escaped += "\\\"";
        break;
      case '\b':
        escaped += "\\b";
        break;
      case '\f':
        escaped += "\\f";
        break;
      case '\n':
        escaped += "\\n";
        break;
      case '\r':
        escaped += "\\r";
        break;
      case '\t':
        escaped += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          char buffer[7] = { 0 };
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch & 0xff);
          escaped += buffer;
        } else {
          escaped += ch;
        }
        break;
    }
  }
  return escaped;
}

static void AppendJsonStringField(std::string &json, const char *key, const std::string &value, bool &firstField) {
  if (!firstField) {
    json += ",";
  }
  firstField = false;
  json += "\"";
  json += key;
  json += "\":\"";
  json += JsonEscape(value);
  json += "\"";
}

static void AppendJsonIntField(std::string &json, const char *key, int64_t value, bool &firstField) {
  if (!firstField) {
    json += ",";
  }
  firstField = false;
  json += "\"";
  json += key;
  json += "\":";
  json += std::to_string(value);
}

static std::string FfmpegErrorToString(int errnum) {
  char buffer[AV_ERROR_MAX_STRING_SIZE] = { 0 };
  av_make_error_string(buffer, sizeof(buffer), errnum);
  return std::string(buffer);
}

struct CurlRequestResult {
  long statusCode = 0;
  std::string body;
  std::string error;
};

struct CurlDownloadResult {
  long statusCode = 0;
  int64_t downloadedBytes = 0;
  std::string error;
};

#if VIDALL_HAS_LIBCURL
/**
 * 将 CURLcode 格式化为带错误码前缀的结构化错误字符串，便于上层解析。
 * 格式：[CURL:{code}] {curl_easy_strerror 描述}
 * 例：[CURL:60] SSL peer certificate or SSH remote key was not OK
 */
static std::string FormatCurlError(CURLcode code) {
  std::string prefix = "[CURL:";
  prefix += std::to_string(static_cast<int>(code));
  prefix += "] ";
  prefix += curl_easy_strerror(code);
  return prefix;
}

static size_t CurlWriteToString(void *contents, size_t size, size_t nmemb, void *userp) {
  size_t totalSize = size * nmemb;
  if (userp == nullptr || contents == nullptr || totalSize == 0) {
    return 0;
  }
  std::string *output = static_cast<std::string *>(userp);
  output->append(static_cast<const char *>(contents), totalSize);
  return totalSize;
}

struct CurlFileWriterContext {
  FILE *file = nullptr;
  int64_t bytesWritten = 0;
};

static size_t CurlWriteToFile(void *contents, size_t size, size_t nmemb, void *userp) {
  size_t totalSize = size * nmemb;
  if (userp == nullptr || contents == nullptr || totalSize == 0) {
    return 0;
  }
  CurlFileWriterContext *context = static_cast<CurlFileWriterContext *>(userp);
  if (context->file == nullptr) {
    return 0;
  }
  size_t wrote = fwrite(contents, 1, totalSize, context->file);
  context->bytesWritten += static_cast<int64_t>(wrote);
  return wrote;
}

static std::vector<std::string> SplitHeaderLines(const std::string &headerLines) {
  std::vector<std::string> result;
  if (headerLines.empty()) {
    return result;
  }
  size_t start = 0;
  while (start < headerLines.size()) {
    size_t end = headerLines.find("\r\n", start);
    if (end == std::string::npos) {
      end = headerLines.size();
    }
    if (end > start) {
      result.push_back(headerLines.substr(start, end - start));
    }
    if (end >= headerLines.size()) {
      break;
    }
    start = end + 2;
  }
  return result;
}
#endif

static CurlRequestResult RunCurlRequest(
  const std::string &method,
  const std::string &url,
  const std::string &headerLines,
  const std::string &body,
  int64_t timeoutMs,
  bool allowSelfSigned = false
) {
  CurlRequestResult result;
#if !VIDALL_HAS_LIBCURL
  (void)method;
  (void)url;
  (void)headerLines;
  (void)body;
  (void)timeoutMs;
  result.error = "libcurl disabled";
  return result;
#else
  CURL *curl = curl_easy_init();
  if (curl == nullptr) {
    result.error = "curl_easy_init failed";
    return result;
  }

  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
  // 生产环境默认严格校验：SSL_VERIFYPEER=1, SSL_VERIFYHOST=2。
  // 仅当 allowSelfSigned=true（受控启用）时关闭校验，不允许作为全局默认行为。
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, allowSelfSigned ? 0L : 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, allowSelfSigned ? 0L : 2L);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, CurlWriteToString);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &result.body);

  if (timeoutMs > 0) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, static_cast<long>(timeoutMs));
  }

  if (!body.empty()) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
  }

  struct curl_slist *headers = nullptr;
  std::vector<std::string> headerItems = SplitHeaderLines(headerLines);
  for (size_t i = 0; i < headerItems.size(); ++i) {
    headers = curl_slist_append(headers, headerItems[i].c_str());
  }
  if (headers != nullptr) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  }

  CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    result.error = FormatCurlError(code);
  } else {
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &result.statusCode);
  }

  if (headers != nullptr) {
    curl_slist_free_all(headers);
  }
  curl_easy_cleanup(curl);
  return result;
#endif
}

static CurlDownloadResult RunCurlDownloadToFile(
  const std::string &method,
  const std::string &url,
  const std::string &headerLines,
  const std::string &body,
  int64_t timeoutMs,
  const std::string &outputPath,
  bool allowSelfSigned = false
) {
  CurlDownloadResult result;
#if !VIDALL_HAS_LIBCURL
  (void)method;
  (void)url;
  (void)headerLines;
  (void)body;
  (void)timeoutMs;
  (void)outputPath;
  result.error = "libcurl disabled";
  return result;
#else
  FILE *file = fopen(outputPath.c_str(), "wb");
  if (file == nullptr) {
    result.error = std::string("open output file failed: ") + std::strerror(errno);
    return result;
  }

  CURL *curl = curl_easy_init();
  if (curl == nullptr) {
    fclose(file);
    result.error = "curl_easy_init failed";
    return result;
  }

  CurlFileWriterContext writerContext;
  writerContext.file = file;

  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
  // 生产环境默认严格校验；allowSelfSigned=true 时为受控启用，不允许作为默认行为。
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, allowSelfSigned ? 0L : 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, allowSelfSigned ? 0L : 2L);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, CurlWriteToFile);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &writerContext);

  if (timeoutMs > 0) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, static_cast<long>(timeoutMs));
  }

  if (!body.empty()) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
  }

  struct curl_slist *headers = nullptr;
  std::vector<std::string> headerItems = SplitHeaderLines(headerLines);
  for (size_t i = 0; i < headerItems.size(); ++i) {
    headers = curl_slist_append(headers, headerItems[i].c_str());
  }
  if (headers != nullptr) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  }

  CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    result.error = FormatCurlError(code);
  } else {
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &result.statusCode);
    result.downloadedBytes = writerContext.bytesWritten;
    if (result.statusCode < 200 || result.statusCode >= 300) {
      result.error = std::string("HTTP ") + std::to_string(result.statusCode);
    }
  }

  if (headers != nullptr) {
    curl_slist_free_all(headers);
  }
  curl_easy_cleanup(curl);
  fclose(file);

  if (!result.error.empty()) {
    std::remove(outputPath.c_str());
  }
  return result;
#endif
}

static std::string CodecTypeToString(AVMediaType mediaType) {
  switch (mediaType) {
    case AVMEDIA_TYPE_VIDEO:
      return "video";
    case AVMEDIA_TYPE_AUDIO:
      return "audio";
    case AVMEDIA_TYPE_SUBTITLE:
      return "subtitle";
    default:
      return "unknown";
  }
}

static std::string RationalToString(AVRational value) {
  return std::to_string(value.num) + "/" + std::to_string(value.den);
}

static std::string DescribeVideoProfile(const AVCodecParameters *codecpar) {
  if (codecpar == nullptr || codecpar->codec_type != AVMEDIA_TYPE_VIDEO || codecpar->profile < 0) {
    return "";
  }
  const char *profileName = avcodec_profile_name(codecpar->codec_id, codecpar->profile);
  if (profileName == nullptr) {
    return "";
  }
  return std::string(profileName);
}

static std::string DescribeVideoPixelFormat(const AVCodecParameters *codecpar) {
  if (codecpar == nullptr || codecpar->codec_type != AVMEDIA_TYPE_VIDEO || codecpar->format < 0) {
    return "";
  }
  const char *pixelFormatName = av_get_pix_fmt_name(static_cast<AVPixelFormat>(codecpar->format));
  if (pixelFormatName == nullptr) {
    return "";
  }
  return std::string(pixelFormatName);
}

static int32_t ResolveVideoBitDepth(const AVCodecParameters *codecpar) {
  if (codecpar == nullptr || codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
    return 0;
  }
  if (codecpar->bits_per_raw_sample > 0) {
    return codecpar->bits_per_raw_sample;
  }
  if (codecpar->format < 0) {
    return 0;
  }
  const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(codecpar->format));
  if (descriptor == nullptr) {
    return 0;
  }
  int32_t maxDepth = 0;
  for (int32_t componentIndex = 0; componentIndex < descriptor->nb_components; ++componentIndex) {
    maxDepth = std::max(maxDepth, descriptor->comp[componentIndex].depth);
  }
  return maxDepth;
}

static std::string ReadMetadataValue(AVDictionary *metadata, const char *key) {
  AVDictionaryEntry *entry = av_dict_get(metadata, key, nullptr, 0);
  if (entry == nullptr || entry->value == nullptr) {
    return "";
  }
  return std::string(entry->value);
}

static std::string DescribeChannelLayout(const AVCodecParameters *codecpar) {
  if (codecpar == nullptr) {
    return "";
  }
  char buffer[128] = { 0 };
  if (av_channel_layout_describe(&codecpar->ch_layout, buffer, sizeof(buffer)) < 0) {
    return "";
  }
  return std::string(buffer);
}

static std::string BuildProbeJson(AVFormatContext *formatContext) {
  std::string json = "{\"streams\":[";
  bool firstStream = true;
  for (unsigned int index = 0; index < formatContext->nb_streams; ++index) {
    AVStream *stream = formatContext->streams[index];
    if (stream == nullptr || stream->codecpar == nullptr) {
      continue;
    }

    if (!firstStream) {
      json += ",";
    }
    firstStream = false;

    const AVCodecParameters *codecpar = stream->codecpar;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(codecpar->codec_id);
    const std::string codecName = std::string(avcodec_get_name(codecpar->codec_id));
    const std::string codecLongName = descriptor != nullptr && descriptor->long_name != nullptr
      ? std::string(descriptor->long_name)
      : codecName;
    const std::string language = ReadMetadataValue(stream->metadata, "language");
    const std::string title = ReadMetadataValue(stream->metadata, "title");

    json += "{";
    bool firstField = true;
    AppendJsonIntField(json, "index", static_cast<int64_t>(stream->index), firstField);
    AppendJsonStringField(json, "codec_type", CodecTypeToString(codecpar->codec_type), firstField);
    AppendJsonStringField(json, "codec_name", codecName, firstField);
    AppendJsonStringField(json, "codec_long_name", codecLongName, firstField);

    if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      const std::string videoProfile = DescribeVideoProfile(codecpar);
      const std::string pixelFormat = DescribeVideoPixelFormat(codecpar);
      const int32_t bitDepth = ResolveVideoBitDepth(codecpar);
      AppendJsonIntField(json, "width", codecpar->width, firstField);
      AppendJsonIntField(json, "height", codecpar->height, firstField);
      AppendJsonStringField(json, "r_frame_rate", RationalToString(stream->r_frame_rate), firstField);
      AppendJsonStringField(json, "avg_frame_rate", RationalToString(stream->avg_frame_rate), firstField);
      if (!videoProfile.empty()) {
        AppendJsonStringField(json, "profile", videoProfile, firstField);
      }
      if (!pixelFormat.empty()) {
        AppendJsonStringField(json, "pix_fmt", pixelFormat, firstField);
      }
      if (bitDepth > 0) {
        AppendJsonStringField(json, "bits_per_raw_sample", std::to_string(bitDepth), firstField);
      }
      if (codecpar->bit_rate > 0) {
        AppendJsonStringField(json, "bit_rate", std::to_string(codecpar->bit_rate), firstField);
      }
      // HDR color metadata：BT.2020 primaries = 9, SMPTE2084(PQ) transfer = 16, HLG = 18
      if (codecpar->color_primaries != AVCOL_PRI_UNSPECIFIED) {
        AppendJsonIntField(json, "color_primaries", static_cast<int64_t>(codecpar->color_primaries), firstField);
      }
      if (codecpar->color_trc != AVCOL_TRC_UNSPECIFIED) {
        AppendJsonIntField(json, "color_transfer", static_cast<int64_t>(codecpar->color_trc), firstField);
      }
      if (codecpar->color_space != AVCOL_SPC_UNSPECIFIED) {
        AppendJsonIntField(json, "color_space", static_cast<int64_t>(codecpar->color_space), firstField);
      }
      if (codecpar->color_range != AVCOL_RANGE_UNSPECIFIED) {
        AppendJsonIntField(json, "color_range", static_cast<int64_t>(codecpar->color_range), firstField);
      }
      // Dolby Vision：从 codecpar coded_side_data 读取 AVDOVIDecoderConfigurationRecord
      {
        const AVDOVIDecoderConfigurationRecord *dovi = nullptr;
        for (int sdIdx = 0; sdIdx < codecpar->nb_coded_side_data; ++sdIdx) {
          const AVPacketSideData &sd = codecpar->coded_side_data[sdIdx];
          if (sd.type == AV_PKT_DATA_DOVI_CONF &&
              sd.size >= static_cast<size_t>(sizeof(AVDOVIDecoderConfigurationRecord))) {
            dovi = reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(sd.data);
            break;
          }
        }
        if (dovi != nullptr) {
          AppendJsonIntField(json, "dv_profile", static_cast<int64_t>(dovi->dv_profile), firstField);
          AppendJsonIntField(json, "dv_level", static_cast<int64_t>(dovi->dv_level), firstField);
          AppendJsonIntField(json, "dv_bl_signal_compatibility_id",
            static_cast<int64_t>(dovi->dv_bl_signal_compatibility_id), firstField);
        }
      }
    } else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
      if (codecpar->sample_rate > 0) {
        AppendJsonStringField(json, "sample_rate", std::to_string(codecpar->sample_rate), firstField);
      }
      if (codecpar->ch_layout.nb_channels > 0) {
        AppendJsonIntField(json, "channels", codecpar->ch_layout.nb_channels, firstField);
      }
      const std::string channelLayout = DescribeChannelLayout(codecpar);
      if (!channelLayout.empty()) {
        AppendJsonStringField(json, "channel_layout", channelLayout, firstField);
      }
      if (codecpar->bit_rate > 0) {
        AppendJsonStringField(json, "bit_rate", std::to_string(codecpar->bit_rate), firstField);
      }
    }

    if (!language.empty() || !title.empty()) {
      if (!firstField) {
        json += ",";
      }
      json += "\"tags\":{";
      bool firstTagField = true;
      if (!language.empty()) {
        AppendJsonStringField(json, "language", language, firstTagField);
      }
      if (!title.empty()) {
        AppendJsonStringField(json, "title", title, firstTagField);
      }
      json += "}";
      firstField = false;
    }
    json += "}";
  }

  json += "],\"format\":{";
  bool firstFormatField = true;
  if (formatContext->duration != AV_NOPTS_VALUE && formatContext->duration > 0) {
    const double durationSeconds = static_cast<double>(formatContext->duration) / static_cast<double>(AV_TIME_BASE);
    AppendJsonStringField(json, "duration", std::to_string(durationSeconds), firstFormatField);
  }
  if (formatContext->bit_rate > 0) {
    AppendJsonStringField(json, "bit_rate", std::to_string(formatContext->bit_rate), firstFormatField);
  }
  if (formatContext->iformat != nullptr && formatContext->iformat->name != nullptr) {
    AppendJsonStringField(json, "format_name", std::string(formatContext->iformat->name), firstFormatField);
  }
  json += "}}";
  return json;
}

static bool RunFfprobe(
  const std::string &url,
  const std::string &headerLines,
  int64_t timeoutMs,
  std::string &jsonResult,
  std::string &errorMessage
) {
  avformat_network_init();

  ProbeInterruptContext interruptContext;
  interruptContext.startTimeUs = av_gettime_relative();
  interruptContext.timeoutUs = timeoutMs > 0 ? timeoutMs * 1000 : 0;

  AVFormatContext *formatContext = avformat_alloc_context();
  if (formatContext == nullptr) {
    errorMessage = "ffprobe failed: cannot allocate format context";
    return false;
  }

  formatContext->interrupt_callback.callback = ProbeInterruptCallback;
  formatContext->interrupt_callback.opaque = &interruptContext;

  AVDictionary *options = nullptr;
  if (!headerLines.empty()) {
    av_dict_set(&options, "headers", headerLines.c_str(), 0);
  }

  int openResult = avformat_open_input(&formatContext, url.c_str(), nullptr, &options);
  av_dict_free(&options);
  if (openResult < 0) {
    errorMessage = "ffprobe open input failed: " + FfmpegErrorToString(openResult);
    if (formatContext != nullptr) {
      avformat_close_input(&formatContext);
    }
    return false;
  }

  int findInfoResult = avformat_find_stream_info(formatContext, nullptr);
  if (findInfoResult < 0) {
    errorMessage = "ffprobe find stream info failed: " + FfmpegErrorToString(findInfoResult);
    avformat_close_input(&formatContext);
    return false;
  }

  jsonResult = BuildProbeJson(formatContext);
  avformat_close_input(&formatContext);
  return true;
}

static void ExecuteFfprobeAsync(napi_env env, void *data) {
  (void)env;
  FfprobeAsyncContext *context = static_cast<FfprobeAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }
  RunFfprobe(context->url, context->headerLines, context->timeoutMs, context->jsonResult, context->errorMessage);
}

static void CompleteFfprobeAsync(napi_env env, napi_status status, void *data) {
  FfprobeAsyncContext *context = static_cast<FfprobeAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }

  napi_value settleValue = nullptr;
  if (status == napi_ok && context->errorMessage.empty()) {
    if (napi_create_string_utf8(env, context->jsonResult.c_str(), NAPI_AUTO_LENGTH, &settleValue) == napi_ok) {
      napi_resolve_deferred(env, context->deferred, settleValue);
    } else {
      context->errorMessage = "ffprobe failed to create result string";
    }
  }

  if (!context->errorMessage.empty()) {
    napi_value messageValue = nullptr;
    napi_value errorValue = nullptr;
    if (napi_create_string_utf8(env, context->errorMessage.c_str(), NAPI_AUTO_LENGTH, &messageValue) == napi_ok &&
      napi_create_error(env, nullptr, messageValue, &errorValue) == napi_ok) {
      napi_reject_deferred(env, context->deferred, errorValue);
    }
  }

  if (context->work != nullptr) {
    napi_delete_async_work(env, context->work);
  }
  delete context;
}

static napi_value Ffprobe(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = { nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "ffprobe failed to read args");
    return nullptr;
  }
  if (argc < 3) {
    ThrowTypeError(env, "ffprobe requires (url, headerLines, timeoutMs)");
    return nullptr;
  }

  std::string url;
  std::string headerLines;
  int64_t timeoutMs = 0;
  if (!ReadUtf8String(env, args[0], url)) {
    ThrowTypeError(env, "ffprobe url must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[1], headerLines)) {
    ThrowTypeError(env, "ffprobe headerLines must be string");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[2], &timeoutMs) != napi_ok) {
    ThrowTypeError(env, "ffprobe timeoutMs must be int64");
    return nullptr;
  }

  FfprobeAsyncContext *context = new FfprobeAsyncContext();
  context->url = url;
  context->headerLines = headerLines;
  context->timeoutMs = timeoutMs;

  napi_value promise = nullptr;
  if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
    delete context;
    ThrowTypeError(env, "ffprobe failed to create promise");
    return nullptr;
  }

  napi_value resourceName = nullptr;
  if (napi_create_string_utf8(env, "ffprobeAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
    delete context;
    ThrowTypeError(env, "ffprobe failed to create resource name");
    return nullptr;
  }

  if (napi_create_async_work(env, nullptr, resourceName, ExecuteFfprobeAsync, CompleteFfprobeAsync, context, &context->work) != napi_ok) {
    delete context;
    ThrowTypeError(env, "ffprobe failed to create async work");
    return nullptr;
  }

  if (napi_queue_async_work(env, context->work) != napi_ok) {
    napi_delete_async_work(env, context->work);
    delete context;
    ThrowTypeError(env, "ffprobe failed to queue async work");
    return nullptr;
  }

  return promise;
}

// ---------------------------------------------------------------------------
// B1：FFmpeg 自研解码路径 — packet 队列 + demux 线程
// B2：视频/音频解码线程 + 帧队列
// ---------------------------------------------------------------------------

// 线程安全的 AVPacket 队列（视频/音频各一个）
struct AVPacketQueue {
  std::queue<AVPacket *> packets;
  std::mutex mtx;
  std::condition_variable cv;
  bool abort = false;
  int maxSize = 64;
};

// B2：线程安全的 AVFrame 队列（解码输出，供渲染/音频线程消费）
struct AVFrameQueue {
  std::queue<AVFrame *> frames;
  std::mutex mtx;
  std::condition_variable cv;
  bool abort = false;
  int maxSize = 4;  // 视频帧不需要太大，以控制内存压力
};

// 前向声明，供 FfmpegContext 持有反向指针（FFmpeg ctx 由 state 独占拥有，生命周期安全）
struct NativePlayerSkeletonState;

// B3：GL 函数指针（通过 eglGetProcAddress 加载，适配 HarmonyOS GLES dispatch 机制）
struct GlFunctions {
    // Shader
    GLuint (*CreateShader)(GLenum) = nullptr;
    void (*ShaderSource)(GLuint, GLsizei, const GLchar**, const GLint*) = nullptr;
    void (*CompileShader)(GLuint) = nullptr;
    void (*GetShaderiv)(GLuint, GLenum, GLint*) = nullptr;
    void (*GetShaderInfoLog)(GLuint, GLsizei, GLsizei*, GLchar*) = nullptr;
    void (*DeleteShader)(GLuint) = nullptr;
    // Program
    GLuint (*CreateProgram)() = nullptr;
    void (*AttachShader)(GLuint, GLuint) = nullptr;
    void (*BindAttribLocation)(GLuint, GLuint, const GLchar*) = nullptr;
    void (*LinkProgram)(GLuint) = nullptr;
    void (*DeleteProgram)(GLuint) = nullptr;
    void (*GetProgramiv)(GLuint, GLenum, GLint*) = nullptr;
    void (*UseProgram)(GLuint) = nullptr;
    GLint (*GetUniformLocation)(GLuint, const GLchar*) = nullptr;
    void (*Uniform1i)(GLint, GLint) = nullptr;
    // Texture
    void (*GenTextures)(GLsizei, GLuint*) = nullptr;
    void (*BindTexture)(GLenum, GLuint) = nullptr;
    void (*TexParameteri)(GLenum, GLenum, GLint) = nullptr;
    void (*TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*) = nullptr;
    void (*TexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void*) = nullptr;
    void (*ActiveTexture)(GLenum) = nullptr;
    void (*DeleteTextures)(GLsizei, const GLuint*) = nullptr;
    // Buffer
    void (*GenBuffers)(GLsizei, GLuint*) = nullptr;
    void (*BindBuffer)(GLenum, GLuint) = nullptr;
    void (*BufferData)(GLenum, GLsizeiptr, const void*, GLenum) = nullptr;
    void (*DeleteBuffers)(GLsizei, const GLuint*) = nullptr;
    // Draw
    void (*VertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void*) = nullptr;
    void (*EnableVertexAttribArray)(GLuint) = nullptr;
    void (*DisableVertexAttribArray)(GLuint) = nullptr;
    void (*DrawArrays)(GLenum, GLint, GLsizei) = nullptr;
    // State
    void (*Viewport)(GLint, GLint, GLsizei, GLsizei) = nullptr;
    void (*ClearColor)(GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
    void (*Clear)(GLbitfield) = nullptr;
    void (*PixelStorei)(GLenum, GLint) = nullptr;
    GLenum (*GetError)() = nullptr;
    const GLubyte* (*GetString)(GLenum) = nullptr;
    void (*GetIntegerv)(GLenum, GLint*) = nullptr;
};

// FFmpeg 上下文：格式探测 + demux 线程 + 双队列
struct FfmpegContext {
  AVFormatContext *fmtCtx = nullptr;
  int videoStreamIdx = -1;
  std::atomic<int32_t> audioStreamIdx{-1};
  AVPacketQueue videoQueue;
  AVPacketQueue audioQueue;
  std::thread demuxThread;
  std::atomic<bool> demuxRunning{false};
  // 中断标志：StopFfmpegDemux 设为 true，让阻塞的 av_read_frame 尽快返回
  std::atomic<bool> interruptFlag{false};
  // HTTP headers（"Key: Value\r\n" 格式，供 avformat_open_input 使用）
  std::string httpHeaders;

  // B2：解码器上下文
  AVCodecContext *videoCodecCtx = nullptr;
  AVCodecContext *audioCodecCtx = nullptr;

  // B2：解码线程
  std::thread videoDecodeThread;
  std::thread audioDecodeThread;
  std::atomic<bool> decodeRunning{false};

  // HW-B：OH_VideoDecoder + FFmpeg 音频混合路径
  OH_AVCodec *hwVideoDecoder{nullptr};
  AVBSFContext *hwBsfCtx{nullptr};  // MKV→Annex-B 转换 BSF
  bool useHwVideoDecoder{false};
  std::atomic<bool> hwVideoRunning{false};
  std::atomic<bool> hwVideoFlushPending{false};
  std::thread hwVideoFeedThread;
  std::thread hwVideoRenderThread;

  struct HwInputEntry { uint32_t index; OH_AVBuffer *buffer; };
  struct HwOutputEntry { uint32_t index; int64_t ptsMs; bool isEos; };

  std::queue<HwInputEntry> hwInputPool;
  std::mutex hwInputMtx;
  std::condition_variable hwInputCv;

  std::queue<HwOutputEntry> hwOutputQueue;
  std::mutex hwOutputMtx;
  std::condition_variable hwOutputCv;

  // B2：解码帧输出队列
  AVFrameQueue videoFrameQueue;
  AVFrameQueue audioFrameQueue;

  // B3：EGL 上下文（只在渲染线程内操作）
  EGLDisplay eglDisplay = EGL_NO_DISPLAY;
  EGLSurface eglSurface = EGL_NO_SURFACE;
  EGLContext eglContext = EGL_NO_CONTEXT;

  // B3：通过 eglGetProcAddress 加载的 GL 函数指针（适配 HarmonyOS GLES dispatch 机制）
  GlFunctions gl;

  // B3：OpenGL ES 资源（在渲染线程 makeCurrent 后初始化）
  GLuint yuvProgram = 0;   // YUV→RGB GLSL program
  GLuint rgbaTexture = 0;  // RGBA 纹理（sws_scale CPU 侧 YUV→RGBA 后上传，GL_RGBA/GL_UNSIGNED_BYTE）
  GLuint quadVBO = 0;      // 全屏四边形顶点缓冲

  // Fix #48-B6: 首帧后置 true，后续帧用 TexSubImage2D 避免每帧重分配 GPU 纹理存储
  bool texturesInitialized = false;
  int  textureW = 0;       // 当前已分配纹理宽（用于 sizeChanged 校验）
  int  textureH = 0;       // 当前已分配纹理高

  // B3：渲染线程
  std::thread renderThread;
  std::atomic<bool> renderRunning{false};

  // B4：音频渲染（OH_AudioRenderer，回调模型，由音频系统线程驱动）
  OH_AudioRenderer *audioRenderer = nullptr;
  OH_AudioStreamBuilder *audioBuilder = nullptr;
  SwrContext *swrCtx = nullptr;          // libswresample 重采样上下文（源格式 → stereo S16 48kHz）
  SwsContext *swsCtx = nullptr;          // libswscale：所有格式 → RGBA（CPU 侧 YUV→RGB 转换，B6 HDR/DV 修复）
  int lastSwsSrcFmt = -1;  // 上次 swsCtx 对应的源像素格式（格式或尺寸变化时重建）
  int lastSwsSrcW   = -1;  // 上次 swsCtx 对应的源宽度
  std::vector<int16_t> pcmLeftover;      // swr_convert 溢出缓冲：跨 callback 的剩余 PCM 数据
  std::mutex audioCallbackStateMutex;
  std::condition_variable audioCallbackStateCv;
  std::atomic<int32_t> audioCallbackActiveCount{0};
  std::atomic<bool> audioRendererSwitching{false};
  std::mutex audioRenderStateMutex;

  // B5：音频时钟（主时钟）
  std::atomic<int64_t> audioPtsSamples{0};        // 已喂给 renderer 的真实媒体样本数，供音频主时钟估算
  int audioSampleRate{0};                         // swr 输出采样率（48000），FfmpegInitSwr 后固定
  std::atomic<int64_t> audioClockBaseMs{0};       // 当前播放锚点对应的媒体时间
  std::atomic<int64_t> audioClockFloorMs{0};      // AudioClock 减去 hwOffset 后的下界：切音轨时=liveClockMs，seek时=目标位置，初始=0
  std::atomic<int64_t> audioClockAnchorFramePosition{-1}; // 当前锚点对应的 renderer 累计 framePosition；-1 表示尚未建立有效锚点
  std::atomic<int64_t> audioClockAnchorFramesWritten{-1}; // 当前锚点对应的累计 written；-1 表示尚未建立有效锚点
  std::atomic<int64_t> audioClockStartRealtimeMs{0}; // 当前播放锚点对应的 steady_clock 时间；暂停时为 0
  std::atomic<int64_t> audioClockLastReportedMs{0};  // 单调保护：避免 renderer timestamp 抖动导致时间倒退
  std::atomic<int64_t> audioClockLastDiagRealtimeMs{0}; // 低频同步诊断日志节流
  std::atomic<int64_t> audioHardwareSafetyOffsetMs{kDefaultAudioHardwareSafetyOffsetMs}; // 当前实例音频硬件补偿
  std::atomic<bool> playbackPaused{false};        // FFmpeg 路径的真实暂停态：音频回调/视频渲染均需读取
  std::atomic<int32_t> videoSyncGraceFrames{0}; // seek/启动后前若干帧绕过 AV sync，先让画面稳定出帧
  int droppedDecodeFrames = 0;                    // 诊断：当前会话累计丢弃的解码帧
  int droppedLateFrames = 0;                      // 诊断：当前会话累计丢弃的渲染晚到帧
  std::atomic<int64_t> lastRenderedVideoPtsMs{-1}; // 渲染线程最后实际渲染帧的视频 PTS（ms）；-1 表示尚未渲染任何帧
  bool firstFrameLogged = false;                  // 诊断：每个会话仅打印一次首帧日志
  bool firstDrawLogged = false;                   // 诊断：每个会话仅打印一次首个 glDrawArrays 日志
  bool firstSwapLogged = false;                   // 诊断：每个会话仅打印一次首个 eglSwapBuffers 日志

  // B5：seek 请求（Seek() NAPI 写入，DemuxThreadFunc 消费）
  std::atomic<bool> seekRequested{false};
  std::atomic<int64_t> seekTargetMs{-1};
  std::atomic<bool> selectTrackRequested{false};
  std::atomic<int32_t> selectTrackTargetIndex{-1};

  // B5：反向指针，供 DemuxThreadFunc 发出 seekDone TSF；生命周期安全（state 独占拥有 ffmpegCtx）
  // B5-QA fix：改为 atomic ptr，消除 StopFfmpegDemux(主线程) 写 nullptr 与
  //            DemuxThreadFunc(demux 线程) 读+解引用之间的 data race（UB）。
  std::atomic<NativePlayerSkeletonState *> ownerState{nullptr};

  // B6：seek 与 decode 线程之间的 codec 操作互斥锁
  // avcodec_flush_buffers / avcodec_send_packet / avcodec_receive_frame 不是线程安全的，
  // 必须通过此 mutex 串行化访问同一个 AVCodecContext。
  std::mutex codecMutex;

  // B6 安全析构兜底：正常路径由 StopFfmpegDemux 先 join 所有线程再 reset()。
  // 若存在异常路径导致析构器直接被调用（如 unique_ptr 提前 reset），先广播所有
  // abort/interrupt 标志，再按 Render→Decode→Demux 顺序 join，线程会迅速响应标志退出。
  // 禁止 detach：detach 后线程仍会访问已释放的 FfmpegContext 成员，导致 UAF。
  ~FfmpegContext() {
    interruptFlag.store(true, std::memory_order_release);
    demuxRunning.store(false, std::memory_order_release);
    decodeRunning.store(false, std::memory_order_release);
    renderRunning.store(false, std::memory_order_release);
    hwVideoRunning.store(false, std::memory_order_release);
    ownerState.store(nullptr, std::memory_order_release);

    // 唤醒所有阻塞在 cv.wait 的线程，使其检查 abort 标志后退出
    { std::lock_guard<std::mutex> lk(videoFrameQueue.mtx); videoFrameQueue.abort = true; }
    videoFrameQueue.cv.notify_all();
    { std::lock_guard<std::mutex> lk(audioFrameQueue.mtx); audioFrameQueue.abort = true; }
    audioFrameQueue.cv.notify_all();
    { std::lock_guard<std::mutex> lk(videoQueue.mtx); videoQueue.abort = true; }
    videoQueue.cv.notify_all();
    { std::lock_guard<std::mutex> lk(audioQueue.mtx); audioQueue.abort = true; }
    audioQueue.cv.notify_all();
    hwInputCv.notify_all();
    hwOutputCv.notify_all();

    // join 顺序：render（依赖 videoFrameQueue）→ decode（依赖 packet 队列）→ demux（生产者）
    // HW path 线程也在此 join
    if (hwVideoRenderThread.joinable()) hwVideoRenderThread.join();
    if (hwVideoFeedThread.joinable())   hwVideoFeedThread.join();
    if (renderThread.joinable())        renderThread.join();
    if (videoDecodeThread.joinable())   videoDecodeThread.join();
    if (audioDecodeThread.joinable())   audioDecodeThread.join();
    if (demuxThread.joinable())         demuxThread.join();

    // 释放 OH_VideoDecoder（HW path）
    if (hwVideoDecoder != nullptr) {
      OH_VideoDecoder_Stop(hwVideoDecoder);
      OH_VideoDecoder_Destroy(hwVideoDecoder);
      hwVideoDecoder = nullptr;
    }
    if (hwBsfCtx != nullptr) {
      av_bsf_free(&hwBsfCtx);
      hwBsfCtx = nullptr;
    }

    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
        "FfmpegContext: safety destructor joined remaining threads");
    // 释放 SwsContext（视频格式转换，B6 HDR/DV 修复）
    if (swsCtx != nullptr) {
      sws_freeContext(swsCtx);
      swsCtx = nullptr;
      lastSwsSrcFmt = -1;
      lastSwsSrcW   = -1;
    }
  }
};

enum class NativePreferredDecodePath {
  HARDWARE_PREFERRED = 0,
  FFMPEG_ONLY = 1
};

static const char *PreferredDecodePathToString(NativePreferredDecodePath path) {
  switch (path) {
    case NativePreferredDecodePath::FFMPEG_ONLY:
      return "ffmpeg_only";
    case NativePreferredDecodePath::HARDWARE_PREFERRED:
    default:
      return "hardware_preferred";
  }
}

struct NativePlayerSkeletonState {
  std::string url;
  std::string headersJson;
  std::string xComponentId;
  OHNativeWindow *nativeWindow = nullptr;  // 渲染目标 Surface，生命周期归 XComponent，不 retain/release
  OH_AVPlayer *avPlayer = nullptr;          // OH_AVPlayer 实例，由 Prepare 创建，Release 销毁
  bool surfaceReady = false;               // OnSurfaceCreated 已触发
  bool pendingPrepare = false;             // A5修复: surface未就绪时暂缓 Prepare，待 OnSurfaceCreated 后补发
  bool prepared = false;
  bool playing = false;
  int32_t selectedTrackIndex = -1;
  int64_t currentTimeMs = 0;
  int64_t durationMs = 0;
  int64_t lastRealtimeMs = 0;
  // ArkTS callback refs (set via setCallbacks, called on the JS thread)
  napi_env callbackEnv = nullptr;
  napi_ref onPreparedRef = nullptr;
  napi_ref onErrorRef = nullptr;
  napi_ref onTimeUpdateRef = nullptr;
  napi_ref onCompletedRef = nullptr;
  napi_ref onBufferingChangeRef = nullptr;
  napi_ref onSeekDoneRef = nullptr;
  napi_ref onSubtitleUpdateRef = nullptr;
  // A4：threadsafe function handles（媒体线程 → JS 线程回调）
  napi_threadsafe_function tsfOnPrepared = nullptr;
  napi_threadsafe_function tsfOnCompleted = nullptr;
  napi_threadsafe_function tsfOnTimeUpdate = nullptr;
  napi_threadsafe_function tsfOnError = nullptr;
  // PR#49 修复：新增 buffering=false 和 seekDone TSF，供媒体线程异步触发
  napi_threadsafe_function tsfOnBufferingFalse = nullptr;
  napi_threadsafe_function tsfOnSeekDone = nullptr;
  napi_threadsafe_function tsfOnSubtitleUpdate = nullptr;
  // B6修复：FFmpeg 接管时通知 ArkTS 重置 native 就绪守卫计时器，防止 3.5s 误 fallback
  napi_threadsafe_function tsfOnFfmpegSwitching = nullptr;
  // PR#49 修复（问题6）：per-player mutex，保护 state 字段的跨线程读写
  // 注意：std::mutex 不可拷贝/移动；unordered_map 通过节点指针操作，不需要拷贝值
  std::mutex stateMutex;
  NativePreferredDecodePath preferredDecodePath = NativePreferredDecodePath::HARDWARE_PREFERRED;
  std::atomic<int64_t> audioHardwareSafetyOffsetMs{kDefaultAudioHardwareSafetyOffsetMs};
  // B1：FFmpeg 自研路径标志与上下文
  bool useFfmpegPath = false;  // OH_AVPlayer 报错后设为 true，切换到 FFmpeg 路径
  std::unique_ptr<FfmpegContext> ffmpegCtx;
  // B2：媒体信息（解码器初始化后填充，供 onPrepared 回调使用）
  int32_t ffmpegWidth = 0;
  int32_t ffmpegHeight = 0;
  double ffmpegFps = 0.0;
  int64_t ffmpegDurationMs = 0;
  // B3：nativeWindow 尚未就绪时（OnXCSurfaceCreated 还未触发）延迟启动渲染线程的标志
  bool pendingFfmpegRender = false;
  // B6：AVPlayer 报错切 FFmpeg 时，先异步释放 AVPlayer 对 NativeWindow 的占用，再启动 FFmpeg。
  std::thread ffmpegFallbackThread;
  bool ffmpegFallbackInProgress = false;
  bool cancelPendingFfmpegFallback = false;
};

static std::unordered_map<int32_t, NativePlayerSkeletonState> g_players;
static int32_t g_nextHandle = 1;
// A4：保护 g_players 跨线程访问（XC 表面回调来自 UI 线程，AV 回调来自媒体线程）
static std::mutex g_playersMutex;

// 修复 #48-A5：pending window 缓存
// 根因：RegisterCallback 在 SetXComponent（onLoad 回调）中调用时 surface 已创建完毕，
// OnSurfaceCreated 不会补发，nativeWindow 永远 nullptr。
// 正确做法：在 Init() 中注册，此时 surface 尚未创建；若 OnSurfaceCreated 先于
// SetXComponent 触发，缓存到 g_pendingWindows 待关联。
struct PendingWindowInfo {
  OH_NativeXComponent *nativeXC = nullptr;
  OHNativeWindow *nativeWindow = nullptr;
};
// xcId → (nativeXC*, nativeWindow*)，供 SetXComponent 延迟关联
static std::unordered_map<std::string, PendingWindowInfo> g_pendingWindows;
// xcId → 当前仍然存活的 surface window。即使 player release，只要 XComponent 未销毁就可复用。
static std::unordered_map<std::string, PendingWindowInfo> g_liveWindows;
// Init() 期间从 OH_NATIVE_XCOMPONENT_OBJ 取到的 nativeXC，
// SetXComponent 用它判断是否需要重复注册（同一个 XComponent 无需重复注册）
static OH_NativeXComponent *g_pendingXC = nullptr;

#ifndef VIDALL_MAX_PLAYER_COUNT
#define VIDALL_MAX_PLAYER_COUNT 100000UL
#endif
static constexpr size_t MAX_PLAYER_COUNT = static_cast<size_t>(VIDALL_MAX_PLAYER_COUNT);

static constexpr int32_t ERR_PREPARE_EMPTY_URL = 1001;
static constexpr int32_t ERR_PREPARE_EMPTY_XCOMPONENT = 1002;
static constexpr int32_t ERR_PLAY_NOT_PREPARED = 1003;
static constexpr int32_t ERR_SELECT_TRACK_NOT_PREPARED = 1004;
static constexpr int32_t ERR_PAUSE_NOT_PREPARED = 1005;
static constexpr int32_t ERR_SEEK_NOT_PREPARED = 1006;
static constexpr int32_t ERR_SELECT_TRACK_INVALID_INDEX = 1007;
static constexpr int32_t ERR_SELECT_TRACK_UNSUPPORTED = 1008;
static constexpr int32_t ERR_SELECT_TRACK_FAILED = 1009;

static void ThrowTypeError(napi_env env, const char *message) {
  napi_throw_type_error(env, nullptr, message);
}

static void ThrowRangeError(napi_env env, const char *message) {
  napi_throw_range_error(env, nullptr, message);
}

static NativePlayerSkeletonState *FindPlayerOrThrow(napi_env env, int32_t handle) {
  std::lock_guard<std::mutex> lock(g_playersMutex); // PR#49（问题3）：保护 g_players 跨线程访问
  auto iter = g_players.find(handle);
  if (iter == g_players.end()) {
    ThrowRangeError(env, "invalid player handle");
    return nullptr;
  }
  return &iter->second;
}

static napi_value CreateInt32(napi_env env, int32_t value) {
  napi_value result = nullptr;
  if (napi_create_int32(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

static napi_value CreateInt64(napi_env env, int64_t value) {
  napi_value result = nullptr;
  if (napi_create_int64(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

static napi_value CreateUint32(napi_env env, uint32_t value) {
  napi_value result = nullptr;
  if (napi_create_uint32(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

static napi_value CreateString(napi_env env, const char *value) {
  napi_value result = nullptr;
  if (napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

static napi_value CreateBoolean(napi_env env, bool value) {
  napi_value result = nullptr;
  if (napi_get_boolean(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

static napi_value CreateUndefined(napi_env env) {
  napi_value result = nullptr;
  if (napi_get_undefined(env, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

static napi_value ReturnInt32OrThrow(napi_env env, int32_t value, const char *context) {
  napi_value result = CreateInt32(env, value);
  if (result == nullptr) {
    ThrowTypeError(env, context);
  }
  return result;
}

static napi_value ReturnInt64OrThrow(napi_env env, int64_t value, const char *context) {
  napi_value result = CreateInt64(env, value);
  if (result == nullptr) {
    ThrowTypeError(env, context);
  }
  return result;
}

static napi_value ReturnUndefinedOrThrow(napi_env env, const char *context) {
  napi_value result = CreateUndefined(env);
  if (result == nullptr) {
    ThrowTypeError(env, context);
  }
  return result;
}

static bool ReadHandleArg(napi_env env, napi_callback_info info, size_t argcExpected, int32_t &handle) {
  size_t argc = argcExpected;
  napi_value args[4] = { nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    return false;
  }
  if (argc < 1) {
    return false;
  }
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    return false;
  }
  return true;
}

static bool ReadUtf8String(napi_env env, napi_value value, std::string &output) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return false;
  }
  std::vector<char> buffer(length + 1, '\0');
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
    return false;
  }
  output.assign(buffer.data(), length);
  return true;
}

static bool EnsureFunctionArg(napi_env env, napi_value arg, const char *name) {
  napi_valuetype type = napi_undefined;
  if (napi_typeof(env, arg, &type) != napi_ok) {
    ThrowTypeError(env, "failed to read callback argument type");
    return false;
  }
  if (type != napi_function) {
    ThrowTypeError(env, name);
    return false;
  }
  return true;
}

static bool EnsureObjectArg(napi_env env, napi_value arg, const char *name) {
  napi_valuetype type = napi_undefined;
  if (napi_typeof(env, arg, &type) != napi_ok) {
    ThrowTypeError(env, "failed to read object argument type");
    return false;
  }
  if (type != napi_object) {
    ThrowTypeError(env, name);
    return false;
  }
  return true;
}

static bool CallJsFunction(
  napi_env env,
  napi_ref fnRef,
  size_t argc,
  napi_value *argv
) {
  if (env == nullptr || fnRef == nullptr) {
    return false;
  }

  napi_value fn = nullptr;
  if (napi_get_reference_value(env, fnRef, &fn) != napi_ok || fn == nullptr) {
    return false;
  }

  napi_value globalObj = nullptr;
  if (napi_get_global(env, &globalObj) != napi_ok || globalObj == nullptr) {
    return false;
  }

  return napi_call_function(env, globalObj, fn, argc, argv, nullptr) == napi_ok;
}

static void EmitTimeUpdate(const NativePlayerSkeletonState &state) {
  if (state.onTimeUpdateRef == nullptr || state.callbackEnv == nullptr) {
    return;
  }
  napi_value positionValue = CreateInt64(state.callbackEnv, state.currentTimeMs);
  if (positionValue == nullptr) {
    return;
  }
  napi_value argv[1] = { positionValue };
  if (!CallJsFunction(state.callbackEnv, state.onTimeUpdateRef, 1, argv)) {
    return;
  }
}

static void EmitError(const NativePlayerSkeletonState &state, int32_t code, const char *message) {
  if (state.onErrorRef == nullptr || state.callbackEnv == nullptr) {
    return;
  }
  napi_value argv[2] = { nullptr, nullptr };
  argv[0] = CreateInt32(state.callbackEnv, code);
  if (argv[0] == nullptr) {
    return;
  }
  if (napi_create_string_utf8(state.callbackEnv, message, NAPI_AUTO_LENGTH, &argv[1]) != napi_ok) {
    return;
  }
  if (!CallJsFunction(state.callbackEnv, state.onErrorRef, 2, argv)) {
    return;
  }
}

static void DeleteRefIfPresent(napi_env env, napi_ref &ref) {
  if (env != nullptr && ref != nullptr) {
    napi_delete_reference(env, ref);
  }
  ref = nullptr;
}

// A4：中止并释放 threadsafe function（napi_tsfn_abort 丢弃所有待处理回调，防止 Release 后悬挂访问）
static void ReleaseTsfIfPresent(napi_threadsafe_function &tsf) {
  if (tsf != nullptr) {
    napi_release_threadsafe_function(tsf, napi_tsfn_abort);
    tsf = nullptr;
  }
}

static void EmitCompleted(const NativePlayerSkeletonState &state) {
  if (state.onCompletedRef == nullptr || state.callbackEnv == nullptr) {
    return;
  }
  if (!CallJsFunction(state.callbackEnv, state.onCompletedRef, 0, nullptr)) {
    return;
  }
}

static void EmitBufferingChange(const NativePlayerSkeletonState &state, bool isBuffering) {
  if (state.onBufferingChangeRef == nullptr || state.callbackEnv == nullptr) {
    return;
  }
  napi_value argv[1] = { nullptr };
  if (napi_get_boolean(state.callbackEnv, isBuffering, &argv[0]) != napi_ok) {
    return;
  }
  CallJsFunction(state.callbackEnv, state.onBufferingChangeRef, 1, argv);
}

static void EmitSeekDone(const NativePlayerSkeletonState &state) {
  if (state.onSeekDoneRef == nullptr || state.callbackEnv == nullptr) {
    return;
  }
  CallJsFunction(state.callbackEnv, state.onSeekDoneRef, 0, nullptr);
}

static void ClearCallbackRefs(NativePlayerSkeletonState &state, napi_env fallbackEnv) {
  napi_env deleteEnv = state.callbackEnv != nullptr ? state.callbackEnv : fallbackEnv;
  DeleteRefIfPresent(deleteEnv, state.onPreparedRef);
  DeleteRefIfPresent(deleteEnv, state.onErrorRef);
  DeleteRefIfPresent(deleteEnv, state.onTimeUpdateRef);
  DeleteRefIfPresent(deleteEnv, state.onCompletedRef);
  DeleteRefIfPresent(deleteEnv, state.onBufferingChangeRef);
  DeleteRefIfPresent(deleteEnv, state.onSeekDoneRef);
  DeleteRefIfPresent(deleteEnv, state.onSubtitleUpdateRef);
  // A4：释放 threadsafe functions（abort 确保已入队的回调不再执行，防止 Release 后悬挂访问）
  ReleaseTsfIfPresent(state.tsfOnPrepared);
  ReleaseTsfIfPresent(state.tsfOnCompleted);
  ReleaseTsfIfPresent(state.tsfOnTimeUpdate);
  ReleaseTsfIfPresent(state.tsfOnError);
  // PR#49：新增两个 TSF
  ReleaseTsfIfPresent(state.tsfOnBufferingFalse);
  ReleaseTsfIfPresent(state.tsfOnSeekDone);
  ReleaseTsfIfPresent(state.tsfOnSubtitleUpdate);
  // B6修复：释放 FFmpeg 接管通知 TSF
  ReleaseTsfIfPresent(state.tsfOnFfmpegSwitching);
}

static bool EnsurePreparedOrEmitError(
  NativePlayerSkeletonState &state,
  int32_t code,
  const char *message
) {
  if (state.prepared) {
    return true;
  }
  EmitError(state, code, message);
  return false;
}

static int64_t NowRealtimeMs() {
  auto now = std::chrono::steady_clock::now();
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
  return static_cast<int64_t>(ms.count());
}

static int64_t NowRealtimeNs() {
  auto now = std::chrono::steady_clock::now();
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch());
  return static_cast<int64_t>(ns.count());
}

static void AdvancePlaybackClockIfNeeded(NativePlayerSkeletonState &state) {
  if (!state.playing) {
    return;
  }
  const int64_t nowMs = NowRealtimeMs();
  if (state.lastRealtimeMs <= 0) {
    state.lastRealtimeMs = nowMs;
    return;
  }
  const int64_t deltaMs = nowMs - state.lastRealtimeMs;
  if (deltaMs <= 0) {
    return;
  }
  state.currentTimeMs += deltaMs;
  state.lastRealtimeMs = nowMs;
  if (state.durationMs > 0 && state.currentTimeMs >= state.durationMs) {
    state.currentTimeMs = state.durationMs;
    state.playing = false;
    state.lastRealtimeMs = 0;
    EmitTimeUpdate(state);
    EmitCompleted(state);
  }
}

static void ResetRuntimeState(NativePlayerSkeletonState &state) {
  state.prepared = false;
  state.playing = false;
  state.pendingPrepare = false;  // A5修复: 切换 surface 时清除延迟标志
  state.selectedTrackIndex = -1;
  state.currentTimeMs = 0;
  state.durationMs = 0;
  state.lastRealtimeMs = 0;
}

static bool ParsePreferredDecodePath(
  const std::string &rawPath,
  NativePreferredDecodePath &preferredDecodePath
) {
  if (rawPath == "ffmpeg_only") {
    preferredDecodePath = NativePreferredDecodePath::FFMPEG_ONLY;
    return true;
  }
  if (rawPath == "hardware_preferred") {
    preferredDecodePath = NativePreferredDecodePath::HARDWARE_PREFERRED;
    return true;
  }
  return false;
}

static void JoinFfmpegFallbackThread(NativePlayerSkeletonState &state) {
  std::thread threadToJoin;
  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    if (state.ffmpegFallbackThread.joinable()) {
      std::swap(threadToJoin, state.ffmpegFallbackThread);
    }
  }
  if (threadToJoin.joinable()) {
    if (threadToJoin.get_id() == std::this_thread::get_id()) {
      threadToJoin.detach();
    } else {
      threadToJoin.join();
    }
  }
}

static napi_value CreatePlayer(napi_env env, napi_callback_info info) {
  (void)info;
  std::lock_guard<std::mutex> lock(g_playersMutex); // PR#49（问题3）：保护 g_players 写操作
  if (g_players.size() >= MAX_PLAYER_COUNT) {
    ThrowRangeError(env, "player count limit reached");
    return nullptr;
  }
  if (g_nextHandle <= 0) {
    ThrowRangeError(env, "player handle overflow");
    return nullptr;
  }
  const int32_t handle = g_nextHandle++;
  // 使用 operator[] 原地默认构造（NativePlayerSkeletonState 含 std::mutex，不可拷贝/移动赋值）
  (void)g_players[handle];
  napi_value handleValue = ReturnInt32OrThrow(env, handle, "createPlayer failed to create return handle");
  if (handleValue == nullptr) {
    g_players.erase(handle);
    g_nextHandle = handle;
    return nullptr;
  }
  return handleValue;
}

static napi_value SetSource(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setSource failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "setSource requires (handle, url)");
    return nullptr;
  }
  int32_t handle = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "setSource handle must be int32");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  std::string url;
  if (!ReadUtf8String(env, args[1], url)) {
    ThrowTypeError(env, "setSource url must be string");
    return nullptr;
  }
  state->url = url;
  // 更换 source 后重置骨架态，避免沿用旧 prepared/时间轴状态。
  ResetRuntimeState(*state);
  EmitTimeUpdate(*state);
  return ReturnUndefinedOrThrow(env, "setSource failed to create return value");
}

static napi_value SetPreferredDecodePath(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setPreferredDecodePath failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "setPreferredDecodePath requires (handle, path)");
    return nullptr;
  }
  int32_t handle = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "setPreferredDecodePath handle must be int32");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  std::string rawPath;
  if (!ReadUtf8String(env, args[1], rawPath)) {
    ThrowTypeError(env, "setPreferredDecodePath path must be string");
    return nullptr;
  }
  NativePreferredDecodePath preferredDecodePath = NativePreferredDecodePath::HARDWARE_PREFERRED;
  if (!ParsePreferredDecodePath(rawPath, preferredDecodePath)) {
    ThrowTypeError(env, "setPreferredDecodePath path must be 'hardware_preferred' or 'ffmpeg_only'");
    return nullptr;
  }
  {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    state->preferredDecodePath = preferredDecodePath;
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "SetPreferredDecodePath: handle=%d preferred=%s",
               handle, PreferredDecodePathToString(preferredDecodePath));
  return ReturnUndefinedOrThrow(env, "setPreferredDecodePath failed to create return value");
}

static napi_value SetAudioHardwareSafetyOffset(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setAudioHardwareSafetyOffset failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "setAudioHardwareSafetyOffset requires (handle, offsetMs)");
    return nullptr;
  }
  int32_t handle = 0;
  int32_t offsetMs = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok ||
      napi_get_value_int32(env, args[1], &offsetMs) != napi_ok) {
    ThrowTypeError(env, "setAudioHardwareSafetyOffset requires int32 handle and int32 offsetMs");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  const int32_t normalizedOffsetMs = std::max<int32_t>(-1500, std::min<int32_t>(offsetMs, 1500));
  state->audioHardwareSafetyOffsetMs.store(normalizedOffsetMs, std::memory_order_relaxed);
  if (state->ffmpegCtx != nullptr) {
    state->ffmpegCtx->audioHardwareSafetyOffsetMs.store(normalizedOffsetMs, std::memory_order_relaxed);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "SetAudioHardwareSafetyOffset: handle=%d offsetMs=%d hasFfmpegCtx=%d",
               handle, normalizedOffsetMs, state->ffmpegCtx != nullptr ? 1 : 0);
  return ReturnUndefinedOrThrow(env, "setAudioHardwareSafetyOffset failed to create return value");
}

static napi_value SetDurationHint(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setDurationHint failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "setDurationHint requires (handle, durationMs)");
    return nullptr;
  }
  int32_t handle = 0;
  int64_t durationMs = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "setDurationHint handle must be int32");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[1], &durationMs) != napi_ok) {
    ThrowTypeError(env, "setDurationHint durationMs must be int64");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  if (durationMs < 0) {
    durationMs = 0;
  }
  state->durationMs = durationMs;
  if (state->durationMs > 0 && state->currentTimeMs > state->durationMs) {
    state->currentTimeMs = state->durationMs;
  }
  EmitTimeUpdate(*state);
  return ReturnUndefinedOrThrow(env, "setDurationHint failed to create return value");
}

static napi_value SetHeaders(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setHeaders failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "setHeaders requires (handle, headersJson)");
    return nullptr;
  }
  int32_t handle = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "setHeaders handle must be int32");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  std::string headersJson;
  if (!ReadUtf8String(env, args[1], headersJson)) {
    ThrowTypeError(env, "setHeaders headersJson must be string");
    return nullptr;
  }
  state->headersJson = headersJson;
  return ReturnUndefinedOrThrow(env, "setHeaders failed to create return value");
}

// ---------------------------------------------------------------------------
// OH_NativeXComponent 静态回调（供所有 player 共用一套函数指针）
// ---------------------------------------------------------------------------

// PR#49 修复（问题5）：OnAVPlayerErrorCB 携带 code+msg 两个字段，TSF data 指针
struct ErrorData {
  int32_t code;
  std::string *msg;  // heap-allocated，由 tsfOnError call_js_cb 负责 delete
};

struct SubtitleData {
  int64_t durationMs{0};
  int64_t startTimeMs{0};
  std::string *text{nullptr};
};

// ---------------------------------------------------------------------------
// B1：FFmpeg demux 路径辅助函数
// ---------------------------------------------------------------------------

static int ReopenFfmpegAudioCodec(FfmpegContext *ctx);
static void StopFfmpegAudioDecodeThread(FfmpegContext *ctx);
static void StartFfmpegAudioDecodeThread(FfmpegContext *ctx);
static bool StartFfmpegAudio(NativePlayerSkeletonState *state, int64_t clockBaseMs, bool startRenderer);
static void StopFfmpegAudio(NativePlayerSkeletonState *state);
static void FlushFfmpegAudioBuffers(FfmpegContext *ctx);
static double AudioClock(FfmpegContext *ctx);
static bool FfmpegInitSwr(FfmpegContext *ctx);

// av_read_frame 中断回调：interruptFlag 置 true 时让 FFmpeg 立即退出阻塞 IO
static int FfmpegInterruptCallback(void *opaque) {
  if (opaque == nullptr) {
    return 0;
  }
  const auto *flag = static_cast<std::atomic<bool> *>(opaque);
  return flag->load() ? 1 : 0;
}

// 将 headersJson（JSON 对象字符串）转换为 FFmpeg 所需的 "Key: Value\r\n" 格式。
// 仅做轻量级手写解析，满足 WebDAV 鉴权场景（Authorization 等单层键值对）。
// 复杂嵌套/转义场景不在 B1 范围内。
static std::string BuildFfmpegHeadersFromJson(const std::string &headersJson) {
  if (headersJson.empty() || headersJson.front() != '{') {
    return {};
  }
  std::string result;
  const std::string &src = headersJson;
  const size_t len = src.size();
  size_t i = 1; // 跳过 '{'
  while (i < len) {
    // 跳过空白
    while (i < len && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r')) {
      ++i;
    }
    if (i >= len || src[i] == '}') {
      break;
    }
    // 解析 key（期望 "key"）
    if (src[i] != '"') {
      break;
    }
    ++i; // skip opening quote
    std::string key;
    while (i < len && src[i] != '"') {
      if (src[i] == '\\' && i + 1 < len) {
        ++i; // skip escape
      }
      key += src[i++];
    }
    if (i < len) {
      ++i; // skip closing quote
    }
    // 跳到 ':'
    while (i < len && src[i] != ':') {
      ++i;
    }
    if (i < len) {
      ++i; // skip ':'
    }
    // 跳过空白
    while (i < len && (src[i] == ' ' || src[i] == '\t')) {
      ++i;
    }
    // 解析 value（期望 "value"）
    if (i >= len || src[i] != '"') {
      break;
    }
    ++i;
    std::string value;
    while (i < len && src[i] != '"') {
      if (src[i] == '\\' && i + 1 < len) {
        ++i;
      }
      value += src[i++];
    }
    if (i < len) {
      ++i;
    }
    if (!key.empty()) {
      result += key + ": " + value + "\r\n";
    }
    // 跳到 ',' 或 '}'
    while (i < len && src[i] != ',' && src[i] != '}') {
      ++i;
    }
    if (i < len && src[i] == ',') {
      ++i;
    }
  }
  return result;
}

// 打开 FFmpeg 格式上下文（含 HTTP Authorization 头与超时配置）
static int FfmpegOpenInput(FfmpegContext *ctx, const std::string &url) {
  if (ctx == nullptr) {
    return AVERROR(EINVAL);
  }
  avformat_network_init();

  ctx->fmtCtx = avformat_alloc_context();
  if (ctx->fmtCtx == nullptr) {
    return AVERROR(ENOMEM);
  }
  // 注册中断回调，以便 StopFfmpegDemux 能及时中断阻塞 IO
  ctx->fmtCtx->interrupt_callback.callback = FfmpegInterruptCallback;
  ctx->fmtCtx->interrupt_callback.opaque = &ctx->interruptFlag;

  AVDictionary *opts = nullptr;
  av_dict_set(&opts, "timeout", "10000000", 0);       // 10s open timeout（微秒）
  av_dict_set(&opts, "reconnect", "1", 0);
  av_dict_set(&opts, "reconnect_streamed", "1", 0);
  if (!ctx->httpHeaders.empty()) {
    av_dict_set(&opts, "headers", ctx->httpHeaders.c_str(), 0);
  }

  int ret = avformat_open_input(&ctx->fmtCtx, url.c_str(), nullptr, &opts);
  av_dict_free(&opts);
  if (ret < 0) {
    avformat_free_context(ctx->fmtCtx);
    ctx->fmtCtx = nullptr;
    return ret;
  }

  ret = avformat_find_stream_info(ctx->fmtCtx, nullptr);
  if (ret < 0) {
    avformat_close_input(&ctx->fmtCtx);
    return ret;
  }

  ctx->videoStreamIdx = av_find_best_stream(ctx->fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
  ctx->audioStreamIdx.store(
      av_find_best_stream(ctx->fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0),
      std::memory_order_relaxed);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegOpenInput: url=%s videoIdx=%d audioIdx=%d",
               url.c_str(), ctx->videoStreamIdx, ctx->audioStreamIdx.load(std::memory_order_relaxed));
  return 0;
}

// ---------------------------------------------------------------------------
// B5：音频时钟辅助（主时钟，单位：秒）
// ---------------------------------------------------------------------------

static void ResetAudioClockAnchorLocked(FfmpegContext *ctx) {
  if (ctx == nullptr || ctx->audioRenderer == nullptr) {
    return;
  }
  int64_t framePosition = 0;
  int64_t timestampNs = 0;
  int64_t framesWritten = 0;
  const OH_AudioStream_Result tsRet =
      OH_AudioRenderer_GetTimestamp(ctx->audioRenderer, CLOCK_MONOTONIC, &framePosition, &timestampNs);
  const OH_AudioStream_Result writtenRet =
      OH_AudioRenderer_GetFramesWritten(ctx->audioRenderer, &framesWritten);
  if (tsRet == AUDIOSTREAM_SUCCESS) {
    ctx->audioClockAnchorFramePosition.store(std::max<int64_t>(0, framePosition), std::memory_order_relaxed);
  } else {
    ctx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
  }
  if (writtenRet == AUDIOSTREAM_SUCCESS) {
    ctx->audioClockAnchorFramesWritten.store(std::max<int64_t>(0, framesWritten), std::memory_order_relaxed);
  } else {
    ctx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
  }
}

static void EmitAsyncError(NativePlayerSkeletonState *state, int32_t code, const char *message) {
  if (state == nullptr || state->tsfOnError == nullptr) {
    return;
  }
  auto *errData = new ErrorData{
    code,
    new std::string(message != nullptr ? message : "native async error")
  };
  napi_call_threadsafe_function(state->tsfOnError, errData, napi_tsfn_nonblocking);
}

static void ProcessPendingAudioTrackSwitch(FfmpegContext *ctx, int32_t trackIndex) {
  if (ctx == nullptr || ctx->fmtCtx == nullptr) {
    return;
  }
  NativePlayerSkeletonState *state = ctx->ownerState.load(std::memory_order_acquire);
  if (state == nullptr) {
    return;
  }
  if (trackIndex < 0 || trackIndex >= static_cast<int32_t>(ctx->fmtCtx->nb_streams)) {
    EmitAsyncError(state, ERR_SELECT_TRACK_INVALID_INDEX,
      "selectTrack failed: FFmpeg audio stream index is out of range");
    return;
  }
  AVStream *targetStream = ctx->fmtCtx->streams[trackIndex];
  if (targetStream == nullptr || targetStream->codecpar == nullptr ||
      targetStream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
    EmitAsyncError(state, ERR_SELECT_TRACK_INVALID_INDEX,
      "selectTrack failed: target stream is not audio");
    return;
  }

  int64_t currentTimeMs = 0;
  bool wasPlaying = false;
  int32_t previousTrackIndex = -1;
  {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    currentTimeMs = state->currentTimeMs;
    wasPlaying = state->playing;
    previousTrackIndex = state->selectedTrackIndex;
  }
  if (wasPlaying) {
    const int64_t hwOffsetMs = ctx->audioHardwareSafetyOffsetMs.load(std::memory_order_relaxed);
    const int64_t liveClockMs = static_cast<int64_t>(AudioClock(ctx) * 1000.0);
    const int64_t videoPosMsAtSwitch = ctx->lastRenderedVideoPtsMs.load(std::memory_order_relaxed);
    // 选择参考时间：
    //   正常情况：使用 AudioClock（用户正在听到的媒体位置），保持音频内容连续，无跳跃。
    //   异常情况：若 AudioClock 比视频帧 PTS 落后 5 秒以上（通常发生在 session 刚开始、
    //             AudioClock 尚未建立有效值时），回退到视频 PTS，防止 baseMs=0 引发画面冻结。
    int64_t refMs;
    if (videoPosMsAtSwitch >= 0 && liveClockMs < videoPosMsAtSwitch - 5000) {
      refMs = videoPosMsAtSwitch;  // AudioClock 严重落后，用视频 PTS 兜底
    } else if (liveClockMs > 0) {
      refMs = liveClockMs;         // 正常路径：用 AudioClock 保持音频连续
    } else {
      refMs = (videoPosMsAtSwitch >= 0) ? videoPosMsAtSwitch : currentTimeMs;
    }
    currentTimeMs = refMs + hwOffsetMs;
  }
  // audioClockFloorMs：切音轨时将 AudioClock 的下界设为 refMs（= liveClockMs 或 videoPts）；
  // AudioClock 减去 hwOffset 后 max(floor, ...) 使时钟从 liveClockMs 开始而非 liveClockMs+hwOffset，
  // 避免切轨后视频需要快进 hwOffset(~900ms) 追赶音频时钟。
  {
    const int64_t hwOffset = ctx->audioHardwareSafetyOffsetMs.load(std::memory_order_relaxed);
    const int64_t floorMs = wasPlaying ? (currentTimeMs - hwOffset) : currentTimeMs;
    ctx->audioClockFloorMs.store(floorMs, std::memory_order_relaxed);
  }
  const int previousAudioStreamIdx = ctx->audioStreamIdx.load(std::memory_order_relaxed);
  if (previousAudioStreamIdx == trackIndex) {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    state->selectedTrackIndex = trackIndex;
    return;
  }

  // 快速路径：AudioRenderer 始终以相同格式创建（48kHz/stereo/S16LE），
  // 切轨时不需要销毁+重建，只需 Pause+Flush+复用，将切换窗口从 ~450ms 压缩到 ~50ms。
  ctx->audioRendererSwitching.store(true, std::memory_order_release);
  OH_AudioRenderer *existingRenderer = nullptr;
  {
    std::lock_guard<std::mutex> lk(ctx->audioRenderStateMutex);
    existingRenderer = ctx->audioRenderer;
  }
  const bool fastPath = (existingRenderer != nullptr);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "SelectTrackAsync: previous=%{public}d target=%{public}d wasPlaying=%{public}d "
               "currentTimeMs=%{public}lld fastPath=%{public}d",
               previousTrackIndex, trackIndex, wasPlaying ? 1 : 0,
               static_cast<long long>(currentTimeMs), fastPath ? 1 : 0);

  if (fastPath) {
    // Pause renderer：OS 停止调用 AudioWriteDataCallback
    OH_AudioRenderer_Pause(existingRenderer);
    // 释放 swrCtx（切轨后需为新 codec 重建）
    {
      std::lock_guard<std::mutex> lk(ctx->audioRenderStateMutex);
      swr_free(&ctx->swrCtx);
      ctx->pcmLeftover.clear();
    }
    // 等待已进入的回调退出（由于 audioRendererSwitching=true，它们会立即填静音并返回）
    {
      std::unique_lock<std::mutex> lk(ctx->audioCallbackStateMutex);
      ctx->audioCallbackStateCv.wait_for(lk, std::chrono::milliseconds(50), [ctx] {
        return ctx->audioCallbackActiveCount.load(std::memory_order_acquire) == 0;
      });
    }
  } else {
    StopFfmpegAudio(state);  // 无现有渲染器，走全量停止
  }

  StopFfmpegAudioDecodeThread(ctx);
  FlushFfmpegAudioBuffers(ctx);  // 清空 packet/frame 队列（pcmLeftover 已在 fastPath 中清空）

  // 音频解码线程已在上面停掉，视频解码线程不访问 audioCodecCtx，
  // 不能持有 codecMutex 来做 ReopenFfmpegAudioCodec：avcodec_open2 可能耗时较长，
  // 持锁会阻塞视频解码线程 → 视频帧队列耗尽 → 画面冻结。
  bool reopenOk = false;
  ctx->audioStreamIdx.store(trackIndex, std::memory_order_relaxed);
  int reopenRet = ReopenFfmpegAudioCodec(ctx);
  if (reopenRet >= 0) {
    reopenOk = true;
  } else {
    ctx->audioStreamIdx.store(previousAudioStreamIdx, std::memory_order_relaxed);
    if (ReopenFfmpegAudioCodec(ctx) >= 0) {
      StartFfmpegAudioDecodeThread(ctx);
      if (fastPath) {
        // codec 回退到旧轨，快速路径放弃：释放渲染器，走全量重建
        {
          std::lock_guard<std::mutex> lk(ctx->audioRenderStateMutex);
          ctx->audioRenderer = nullptr;
        }
        OH_AudioRenderer_Stop(existingRenderer);
        OH_AudioRenderer_Release(existingRenderer);
        OH_AudioStreamBuilder_Destroy(ctx->audioBuilder);
        ctx->audioBuilder = nullptr;
      }
      (void)StartFfmpegAudio(state, currentTimeMs, false);
    }
  }
  if (!reopenOk) {
    EmitAsyncError(state, ERR_SELECT_TRACK_FAILED,
      "selectTrack failed: FFmpeg audio decoder reopen failed");
    return;
  }
  StartFfmpegAudioDecodeThread(ctx);

  if (fastPath) {
    // 快速路径：Flush OS 缓冲 + 重置时钟 + 复用渲染器
    if (!FfmpegInitSwr(ctx)) {
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                   "SelectTrackAsync: FfmpegInitSwr failed in fast path, falling back");
      // swr 失败，降级为全量重建
      {
        std::lock_guard<std::mutex> lk(ctx->audioRenderStateMutex);
        ctx->audioRenderer = nullptr;
      }
      OH_AudioRenderer_Stop(existingRenderer);
      OH_AudioRenderer_Release(existingRenderer);
      OH_AudioStreamBuilder_Destroy(ctx->audioBuilder);
      ctx->audioBuilder = nullptr;
      if (!StartFfmpegAudio(state, currentTimeMs, wasPlaying)) {
        EmitAsyncError(state, ERR_SELECT_TRACK_FAILED,
          "selectTrack failed: FFmpeg audio renderer restart failed (fallback)");
        return;
      }
    } else {
      OH_AudioRenderer_Flush(existingRenderer);  // 清空 OS 硬件缓冲区内的旧轨音频
      ctx->playbackPaused.store(!wasPlaying, std::memory_order_relaxed);
      ctx->audioClockBaseMs.store(currentTimeMs, std::memory_order_relaxed);
      ctx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
      ctx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
      ctx->audioClockStartRealtimeMs.store(NowRealtimeMs(), std::memory_order_relaxed);
      ctx->audioClockLastReportedMs.store(currentTimeMs, std::memory_order_relaxed);
      ctx->audioPtsSamples.store(0, std::memory_order_relaxed);
      ctx->videoSyncGraceFrames.store(90, std::memory_order_relaxed);
      if (wasPlaying) {
        const OH_AudioStream_Result startResult = OH_AudioRenderer_Start(existingRenderer);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "SelectTrackAsync: fast path Start result=%{public}d baseMs=%{public}lld",
                     startResult, static_cast<long long>(currentTimeMs));
      }
      ctx->audioRendererSwitching.store(false, std::memory_order_release);
    }
  } else {
    if (!StartFfmpegAudio(state, currentTimeMs, wasPlaying)) {
      EmitAsyncError(state, ERR_SELECT_TRACK_FAILED,
        "selectTrack failed: FFmpeg audio renderer restart failed");
      return;
    }
  }
  {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    state->selectedTrackIndex = trackIndex;
    state->currentTimeMs = currentTimeMs;
  }
}

static double AudioClock(FfmpegContext *ctx) {
  const int64_t baseMs = ctx->audioClockBaseMs.load(std::memory_order_relaxed);
  if (ctx->playbackPaused.load(std::memory_order_relaxed)) {
    return static_cast<double>(baseMs) / 1000.0;
  }

  int64_t candidateMs = baseMs;
  int64_t mediaFedUpperBoundMs = baseMs;
  bool hasRendererTimestamp = false;
  bool anchorJustInitialized = false;
  if (ctx->audioSampleRate > 0) {
    const int64_t fedSamples = ctx->audioPtsSamples.load(std::memory_order_relaxed);
    if (fedSamples > 0) {
      mediaFedUpperBoundMs =
          baseMs + (fedSamples * 1000LL) / static_cast<int64_t>(ctx->audioSampleRate);
    }
  }
  if (!ctx->audioRendererSwitching.load(std::memory_order_acquire) &&
      ctx->audioRenderer != nullptr && ctx->audioSampleRate > 0) {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    if (ctx->audioRenderer != nullptr) {
      int64_t framePosition = 0;
      int64_t timestampNs = 0;
      const OH_AudioStream_Result tsRet =
          OH_AudioRenderer_GetTimestamp(ctx->audioRenderer, CLOCK_MONOTONIC, &framePosition, &timestampNs);
      if (tsRet == AUDIOSTREAM_SUCCESS) {
        hasRendererTimestamp = true;
        const int64_t nowNs = NowRealtimeNs();
        const int64_t nowMs = nowNs / 1000000LL;
        const int64_t elapsedNsSinceTs = std::max<int64_t>(0, nowNs - timestampNs);
        const int64_t renderedSinceTs =
            (elapsedNsSinceTs * static_cast<int64_t>(ctx->audioSampleRate)) / 1000000000LL;
        int64_t anchorFramePosition =
            ctx->audioClockAnchorFramePosition.load(std::memory_order_relaxed);
        int64_t anchorFramesWritten =
            ctx->audioClockAnchorFramesWritten.load(std::memory_order_relaxed);
        if (anchorFramePosition < 0) {
          anchorFramePosition = std::max<int64_t>(0, framePosition);
          ctx->audioClockAnchorFramePosition.store(anchorFramePosition, std::memory_order_relaxed);
          anchorJustInitialized = true;
        }
        int64_t framesWritten = 0;
        const OH_AudioStream_Result writtenRet =
            OH_AudioRenderer_GetFramesWritten(ctx->audioRenderer, &framesWritten);
        if (writtenRet == AUDIOSTREAM_SUCCESS && anchorFramesWritten < 0) {
          anchorFramesWritten = std::max<int64_t>(0, framesWritten);
          ctx->audioClockAnchorFramesWritten.store(anchorFramesWritten, std::memory_order_relaxed);
          anchorJustInitialized = true;
        } else if (anchorFramesWritten < 0) {
          anchorFramesWritten = 0;
        }
        // framesAdvanced > 0 时才加 renderedSinceTs：
        // 若 framesAdvanced = 0（anchor 刚初始化，或 GetTimestamp 返回的是 Pause 前的
        // stale framePosition），renderedSinceTs = (now - T_stale) * sampleRate 可能包含
        // 整个暂停时长，导致 candidateMs 虚假跳跃，引起概率性音画不同步。
        // 当 framesAdvanced = 0 时直接令 effectivePlayedFrames = 0，
        // 等待硬件真正输出新帧后再用渐进推进，monotonicity 保护不回退。
        const int64_t framesAdvanced =
            std::max<int64_t>(0, framePosition - anchorFramePosition);
        const int64_t effectivePlayedFrames =
            framesAdvanced > 0 ? framesAdvanced + renderedSinceTs : 0LL;
        const int64_t playedMs =
            (effectivePlayedFrames * 1000LL) / static_cast<int64_t>(ctx->audioSampleRate);
        candidateMs = baseMs + playedMs;

        int64_t pendingMs = 0;
        if (writtenRet == AUDIOSTREAM_SUCCESS && !anchorJustInitialized) {
          const int64_t effectiveWrittenFrames =
              std::max<int64_t>(0, framesWritten - anchorFramesWritten);
          const int64_t pendingFrames =
              std::max<int64_t>(0, effectiveWrittenFrames - effectivePlayedFrames);
          if (pendingFrames > 0) {
            pendingMs = (pendingFrames * 1000LL) / static_cast<int64_t>(ctx->audioSampleRate);
            const int64_t cappedPendingMs = std::min<int64_t>(pendingMs, 1500);
            candidateMs = std::max<int64_t>(baseMs, candidateMs - cappedPendingMs);
          }
        }
  const int64_t hardwareOffsetMs = ctx->audioHardwareSafetyOffsetMs.load(std::memory_order_relaxed);
        // 使用 audioClockFloorMs 而非 baseMs 作为 hwOffset 减法后的下界：
        // - 切音轨时 floor = liveClockMs（而非 liveClockMs+hwOffset），使时钟从视频同步点开始
        // - seek/初始启动时 floor = seekTarget/0，与旧行为等价
        const int64_t clockFloor = ctx->audioClockFloorMs.load(std::memory_order_relaxed);
        candidateMs = std::max<int64_t>(clockFloor, candidateMs - hardwareOffsetMs);
        int64_t lastDiagRealtimeMs = ctx->audioClockLastDiagRealtimeMs.load(std::memory_order_relaxed);
        if (nowMs - lastDiagRealtimeMs >= 1000 &&
            ctx->audioClockLastDiagRealtimeMs.compare_exchange_strong(
                lastDiagRealtimeMs, nowMs, std::memory_order_relaxed, std::memory_order_relaxed)) {
          OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                       "[AVSyncDiag] baseMs=%{public}lld framePos=%{public}lld renderedSinceTs=%{public}lld written=%{public}lld pendingMs=%{public}lld hwOffsetMs=%{public}lld candidateMs=%{public}lld",
                       static_cast<long long>(baseMs),
                       static_cast<long long>(framePosition),
                       static_cast<long long>(renderedSinceTs),
                       static_cast<long long>(framesWritten),
                       static_cast<long long>(pendingMs),
                       static_cast<long long>(hardwareOffsetMs),
                       static_cast<long long>(candidateMs));
        }
      }
    }
  }
  if (candidateMs <= baseMs && !hasRendererTimestamp) {
    // 切音轨窗口（audioRendererSwitching=true）期间：HW 时间戳不可用，startRealtimeMs 也已清零。
    // 此时 candidateMs 会卡在 baseMs（= liveClockMs+hwOffset），导致视频以为落后900ms而快进。
    // 修复：用 audioClockFloorMs（= liveClockMs）代替 baseMs，让 AudioClock 在切轨期间
    // 停在视频当前位置，而不是跳到 baseMs（liveClockMs+hwOffset）。
    if (ctx->audioRendererSwitching.load(std::memory_order_acquire)) {
      const int64_t floorMs = ctx->audioClockFloorMs.load(std::memory_order_relaxed);
      if (floorMs > 0) {
        candidateMs = floorMs; // 切轨期间 hold 在 liveClockMs，单调保护会确保不回退
      }
    } else {
      const int64_t startRealtimeMs = ctx->audioClockStartRealtimeMs.load(std::memory_order_relaxed);
      if (startRealtimeMs > 0) {
        const int64_t nowMs = NowRealtimeMs();
        const int64_t deltaMs = std::max<int64_t>(0, nowMs - startRealtimeMs);
        candidateMs = baseMs + deltaMs;
      }
    }
  }
  // Post-seek/flush warmup：candidateMs <= floor 表明 hardware pipeline 仍在预热阶段。
  // 用纯 wall-clock 推进 AudioClock，避免视频在 seek/启动后因 hwOffset 偏移冻帧数百毫秒。
  // 以前公式 "floor - hwOff + elapsed" 当 hwOff 较大（如 900ms）时会导致：
  //   1. 前 hwOff ms 内 wallMs=floor → 时钟冻结，视频 20fps（每帧 sleep 50ms）
  //   2. 此后 wallMs 始终比 lastReportedMs 低 hwOff → 单调保护永远占主导 → 时钟持续卡住
  // 改为 "floor + elapsed"（纯 wall-clock），时钟从 floor 以 1ms/ms 推进，
  // 视频以正常帧率播放。hwOffset 的 AV 补偿仅在 HW candidateMs > floor 时由稳态公式承担。
  // audioRendererSwitching=true 时（切音轨窗口）由 Round2 fix 处理，此处跳过。
  {
    const int64_t floorMs2 = ctx->audioClockFloorMs.load(std::memory_order_relaxed);
    if (candidateMs <= floorMs2 && !ctx->audioRendererSwitching.load(std::memory_order_acquire)) {
      const int64_t startRt = ctx->audioClockStartRealtimeMs.load(std::memory_order_relaxed);
      if (startRt > 0) {
        const int64_t elapsed = std::max<int64_t>(0, NowRealtimeMs() - startRt);
        // 纯 wall-clock：clock = floor + elapsed（不减 hwOff），视频正常帧率播放
        const int64_t wallMs = floorMs2 + elapsed;
        if (wallMs > candidateMs) {
          candidateMs = wallMs;
        }
      }
    }
  }
  // 只在已有真实音频数据时才应用 mediaFedUpperBound 上限；
  // audioPtsSamples==0 时跳过此 cap，防止切音轨/seek 初期管线尚未就绪时 cap 把时钟永久锁死。
  if (ctx->audioPtsSamples.load(std::memory_order_relaxed) > 0 &&
      candidateMs > mediaFedUpperBoundMs) {
    candidateMs = mediaFedUpperBoundMs;
  }
  if (anchorJustInitialized) {
    // Pause/Resume 时 lastReportedMs = pausedClockMs（Pause handler 设置）。
    // anchorJustInitialized 首次调用 candidateMs = baseMs - hwOffset = pausedClockMs - 900ms，
    // 直接覆写会导致时钟倒退 900ms，触发"画面滞后声音"。
    // 修复：此处同样应用单调保护，保持时钟不回退。
    // - Pause/Resume：max(pausedClockMs - 900, pausedClockMs) = pausedClockMs，时钟不变
    // - Seek：lastReportedMs 已由 DemuxThread 重置为 seekTarget，max(seekTarget, seekTarget) = seekTarget ✓
    // - 初始播放：lastReportedMs = 0，max(0, 0) = 0 ✓
    const int64_t lastMs = ctx->audioClockLastReportedMs.load(std::memory_order_relaxed);
    if (candidateMs < lastMs) candidateMs = lastMs;
    ctx->audioClockLastReportedMs.store(candidateMs, std::memory_order_relaxed);
    return static_cast<double>(candidateMs) / 1000.0;
  }
  int64_t lastReportedMs = ctx->audioClockLastReportedMs.load(std::memory_order_relaxed);
  while (candidateMs > lastReportedMs &&
         !ctx->audioClockLastReportedMs.compare_exchange_weak(
             lastReportedMs, candidateMs, std::memory_order_relaxed, std::memory_order_relaxed)) {
  }
  if (candidateMs < lastReportedMs) {
    candidateMs = lastReportedMs;
  }
  return static_cast<double>(candidateMs) / 1000.0;
}

static double VideoFramePtsSeconds(const FfmpegContext *ctx, const AVFrame *frame) {
  if (ctx == nullptr || frame == nullptr || ctx->videoStreamIdx < 0 || ctx->fmtCtx == nullptr) {
    return 0.0;
  }
  const int64_t frameTs = (frame->best_effort_timestamp != AV_NOPTS_VALUE)
      ? frame->best_effort_timestamp
      : frame->pts;
  if (frameTs == AV_NOPTS_VALUE) {
    return 0.0;
  }
  return frameTs * av_q2d(ctx->fmtCtx->streams[ctx->videoStreamIdx]->time_base);
}

// ---------------------------------------------------------------------------
// B5：清空所有 packet/frame 队列（seek 时调用，清除过期数据）
// ---------------------------------------------------------------------------

static void FlushFfmpegQueues(FfmpegContext *ctx) {
  {
    std::lock_guard<std::mutex> lk(ctx->videoQueue.mtx);
    while (!ctx->videoQueue.packets.empty()) {
      AVPacket *p = ctx->videoQueue.packets.front();
      ctx->videoQueue.packets.pop();
      av_packet_free(&p);
    }
  }
  ctx->videoQueue.cv.notify_all();

  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    while (!ctx->audioQueue.packets.empty()) {
      AVPacket *p = ctx->audioQueue.packets.front();
      ctx->audioQueue.packets.pop();
      av_packet_free(&p);
    }
  }
  ctx->audioQueue.cv.notify_all();

  {
    std::lock_guard<std::mutex> lk(ctx->videoFrameQueue.mtx);
    while (!ctx->videoFrameQueue.frames.empty()) {
      AVFrame *f = ctx->videoFrameQueue.frames.front();
      ctx->videoFrameQueue.frames.pop();
      av_frame_free(&f);
    }
  }
  ctx->videoFrameQueue.cv.notify_all();

  {
    std::lock_guard<std::mutex> lk(ctx->audioFrameQueue.mtx);
    while (!ctx->audioFrameQueue.frames.empty()) {
      AVFrame *f = ctx->audioFrameQueue.frames.front();
      ctx->audioFrameQueue.frames.pop();
      av_frame_free(&f);
    }
  }
  ctx->audioFrameQueue.cv.notify_all();

  {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    ctx->pcmLeftover.clear();
  }
}

static void FlushFfmpegAudioBuffers(FfmpegContext *ctx) {
  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    while (!ctx->audioQueue.packets.empty()) {
      AVPacket *p = ctx->audioQueue.packets.front();
      ctx->audioQueue.packets.pop();
      av_packet_free(&p);
    }
  }
  ctx->audioQueue.cv.notify_all();

  {
    std::lock_guard<std::mutex> lk(ctx->audioFrameQueue.mtx);
    while (!ctx->audioFrameQueue.frames.empty()) {
      AVFrame *f = ctx->audioFrameQueue.frames.front();
      ctx->audioFrameQueue.frames.pop();
      av_frame_free(&f);
    }
  }
  ctx->audioFrameQueue.cv.notify_all();
  {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    ctx->pcmLeftover.clear();
  }
}

// 前向声明：HW 路径 flush（实现在 VideoDecodeThreadFunc 之后）
static void FlushHwVideoDecoder(FfmpegContext *ctx);

// demux 线程主循环：持续读帧，分发至视频/音频队列
static void DemuxThreadFunc(FfmpegContext *ctx) {
  if (ctx == nullptr || ctx->fmtCtx == nullptr) {
    return;
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "DemuxThread: started");

  AVPacket *pkt = av_packet_alloc();
  if (pkt == nullptr) {
    ctx->demuxRunning.store(false);
    return;
  }

  while (ctx->demuxRunning.load()) {
    if (ctx->selectTrackRequested.exchange(false, std::memory_order_acq_rel)) {
      const int32_t trackIndex = ctx->selectTrackTargetIndex.load(std::memory_order_relaxed);
      ProcessPendingAudioTrackSwitch(ctx, trackIndex);
    }
    // B5：检查 seek 请求（由 Seek() NAPI 设置，在 demux 线程消费以保证 avformat 线程安全）
    if (ctx->seekRequested.exchange(false)) {
      const int64_t targetMs = ctx->seekTargetMs.load();
      const int64_t targetUs = targetMs * 1000LL;  // AV_TIME_BASE = 1e6
      // Fix #48-B6-2：seek 前先 unref pkt，防止 fmtCtx 持有上次 av_read_frame 残留数据
      // 导致 seek 后首次 av_read_frame 触发 FFmpeg 内部状态机断言 (SIGABRT)。
      av_packet_unref(pkt);
      // B5-QA fix：检查 av_seek_frame 返回值；失败时跳过 flush/reset/seekDone，
      //            避免在无效位置继续解码并产生误导性回调。
      int seekRet = av_seek_frame(ctx->fmtCtx, -1, targetUs, AVSEEK_FLAG_BACKWARD);
      if (seekRet < 0) {
        char errBuf[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(seekRet, errBuf, sizeof(errBuf));
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "DemuxThread: av_seek_frame failed: %s", errBuf);
        // seek 失败不 continue：让后续 av_read_frame 继续在原位置读包，避免卡死。
      } else {
        ctx->audioRendererSwitching.store(true, std::memory_order_release);
        // 清空所有 packet/frame 队列（旧数据）
        FlushFfmpegQueues(ctx);
        // 刷新解码器内部缓冲区（hold codecMutex 防止与 decode 线程并发）
        {
          std::lock_guard<std::mutex> codecLk(ctx->codecMutex);
          if (ctx->videoCodecCtx != nullptr) avcodec_flush_buffers(ctx->videoCodecCtx);
          if (ctx->audioCodecCtx != nullptr) avcodec_flush_buffers(ctx->audioCodecCtx);
        }
        // HW path：刷新 OH_VideoDecoder
        if (ctx->useHwVideoDecoder && ctx->hwVideoDecoder != nullptr) {
          FlushHwVideoDecoder(ctx);
        }
        // seek 后重置 renderer 缓冲与音频时钟：新时钟 = 目标位置 + 之后已渲染样本
        if (ctx->audioRenderer != nullptr) {
          std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
          const OH_AudioStream_Result flushResult = OH_AudioRenderer_Flush(ctx->audioRenderer);
          ctx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
          ctx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
          OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                       "DemuxThread: OH_AudioRenderer_Flush result=%{public}d",
                       static_cast<int32_t>(flushResult));
        }
        ctx->audioClockBaseMs.store(targetMs, std::memory_order_relaxed);
        ctx->audioClockFloorMs.store(targetMs, std::memory_order_relaxed);  // seek：floor = 目标位置（与 baseMs 相同）
        // seek 后清零 startRealtimeMs；音频 callback 在首批真实样本写入时再设，
        // 避免 demux 读取耗时（100-300ms）被计入 wall-clock 导致 AudioClock 超前。
        ctx->audioClockStartRealtimeMs.store(0, std::memory_order_relaxed);
        ctx->audioClockLastReportedMs.store(targetMs, std::memory_order_relaxed);
        ctx->audioPtsSamples.store(0, std::memory_order_relaxed);
        ctx->videoSyncGraceFrames.store(90, std::memory_order_relaxed);
        ctx->droppedDecodeFrames = 0;
        ctx->droppedLateFrames = 0;
        ctx->audioRendererSwitching.store(false, std::memory_order_release);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "DemuxThread: seeked to %lld ms", static_cast<long long>(targetMs));
        // 发出 seekDone TSF 通知 ArkTS
        // B5-QA fix：通过 atomic load(acquire) 读取 ownerState，消除与主线程写 nullptr 的竞态；
        //            两次独立 load 分别保护"写 currentTimeMs"和"调用 TSF"两个临界区。
        {
          NativePlayerSkeletonState *st = ctx->ownerState.load(std::memory_order_acquire);
          if (st != nullptr) {
            std::lock_guard<std::mutex> lk(st->stateMutex);
            st->currentTimeMs = targetMs;
          }
        }
        {
          NativePlayerSkeletonState *st = ctx->ownerState.load(std::memory_order_acquire);
          if (st != nullptr && st->tsfOnTimeUpdate != nullptr) {
            napi_call_threadsafe_function(st->tsfOnTimeUpdate, nullptr, napi_tsfn_nonblocking);
          }
        }
        {
          NativePlayerSkeletonState *st = ctx->ownerState.load(std::memory_order_acquire);
          if (st != nullptr && st->tsfOnSeekDone != nullptr) {
            napi_call_threadsafe_function(st->tsfOnSeekDone, nullptr, napi_tsfn_nonblocking);
          }
        }
      } // end else (seekRet >= 0)
    } // end if (seekRequested)

    int ret = av_read_frame(ctx->fmtCtx, pkt);
    if (ret == AVERROR_EOF) {
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "DemuxThread: EOF reached");
      break;
    }
    if (ret == AVERROR(EAGAIN)) {
      // 暂时无数据，短暂休眠后重试
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    if (ret < 0) {
      char errbuf[128] = {0};
      av_strerror(ret, errbuf, sizeof(errbuf));
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                   "DemuxThread: av_read_frame error: %s", errbuf);
      break;
    }

    if (pkt->stream_index == ctx->videoStreamIdx && ctx->videoStreamIdx >= 0) {
      AVPacket *pktCopy = av_packet_alloc();
      if (pktCopy != nullptr && av_packet_ref(pktCopy, pkt) == 0) {
        std::unique_lock<std::mutex> lock(ctx->videoQueue.mtx);
        ctx->videoQueue.cv.wait(lock, [&] {
          return static_cast<int>(ctx->videoQueue.packets.size()) < ctx->videoQueue.maxSize
              || ctx->videoQueue.abort;
        });
        if (!ctx->videoQueue.abort) {
          ctx->videoQueue.packets.push(pktCopy);
        } else {
          av_packet_free(&pktCopy);
        }
        lock.unlock();
        ctx->videoQueue.cv.notify_all();
      } else if (pktCopy != nullptr) {
        av_packet_free(&pktCopy);
      }
    } else {
      const int audioStreamIdx = ctx->audioStreamIdx.load(std::memory_order_relaxed);
      if (pkt->stream_index == audioStreamIdx && audioStreamIdx >= 0) {
      AVPacket *pktCopy = av_packet_alloc();
      if (pktCopy != nullptr && av_packet_ref(pktCopy, pkt) == 0) {
        std::unique_lock<std::mutex> lock(ctx->audioQueue.mtx);
        ctx->audioQueue.cv.wait(lock, [&] {
          return static_cast<int>(ctx->audioQueue.packets.size()) < ctx->audioQueue.maxSize
              || ctx->audioQueue.abort;
        });
        if (!ctx->audioQueue.abort) {
          ctx->audioQueue.packets.push(pktCopy);
        } else {
          av_packet_free(&pktCopy);
        }
        lock.unlock();
        ctx->audioQueue.cv.notify_all();
      } else if (pktCopy != nullptr) {
        av_packet_free(&pktCopy);
      }
      }
    }
    av_packet_unref(pkt);
  }

  av_packet_free(&pkt);
  ctx->demuxRunning.store(false);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "DemuxThread: exited");
}

// 启动 FFmpeg demux 线程（在 OH_AVPlayer 报错后从媒体线程调用）
static void StartFfmpegDecode(NativePlayerSkeletonState *state);
static void StopFfmpegDecode(NativePlayerSkeletonState *state);

// ---------------------------------------------------------------------------
// B2：解码器初始化
// ---------------------------------------------------------------------------

static int FfmpegInitCodecs(FfmpegContext *ctx) {
  // 视频解码器：HW path 下跳过 FFmpeg 视频软解器初始化
  if (ctx->videoStreamIdx >= 0 && !ctx->useHwVideoDecoder) {
    AVStream *vs = ctx->fmtCtx->streams[ctx->videoStreamIdx];
    const AVCodec *codec = avcodec_find_decoder(vs->codecpar->codec_id);
    if (!codec) {
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                   "FfmpegInitCodecs: no video decoder for codec_id=%d", vs->codecpar->codec_id);
      return AVERROR_DECODER_NOT_FOUND;
    }
    ctx->videoCodecCtx = avcodec_alloc_context3(codec);
    if (!ctx->videoCodecCtx) {
      return AVERROR(ENOMEM);
    }
    int ret = avcodec_parameters_to_context(ctx->videoCodecCtx, vs->codecpar);
    if (ret < 0) {
      avcodec_free_context(&ctx->videoCodecCtx);
      return ret;
    }
    // 多线程解码（frame-level），4K/10bit 软解场景优先提高吞吐
    const unsigned int hwThreads = std::thread::hardware_concurrency();
    const int decodeThreads = static_cast<int>(std::min<unsigned int>(hwThreads > 0 ? hwThreads : 4, 8));
    ctx->videoCodecCtx->thread_count = std::max(4, decodeThreads);
    ctx->videoCodecCtx->thread_type = FF_THREAD_FRAME;
    ret = avcodec_open2(ctx->videoCodecCtx, codec, nullptr);
    if (ret < 0) {
      avcodec_free_context(&ctx->videoCodecCtx);
      return ret;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "FfmpegInitCodecs: video decoder opened: %s %dx%d threads=%d",
                 codec->name, ctx->videoCodecCtx->width, ctx->videoCodecCtx->height,
                 ctx->videoCodecCtx->thread_count);
  }

  // 音频解码器
  const int audioStreamIdx = ctx->audioStreamIdx.load(std::memory_order_relaxed);
  if (audioStreamIdx >= 0) {
    AVStream *as = ctx->fmtCtx->streams[audioStreamIdx];
    const AVCodec *codec = avcodec_find_decoder(as->codecpar->codec_id);
    if (!codec) {
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                   "FfmpegInitCodecs: no audio decoder for codec_id=%d", as->codecpar->codec_id);
      return AVERROR_DECODER_NOT_FOUND;
    }
    ctx->audioCodecCtx = avcodec_alloc_context3(codec);
    if (!ctx->audioCodecCtx) {
      return AVERROR(ENOMEM);
    }
    int ret = avcodec_parameters_to_context(ctx->audioCodecCtx, as->codecpar);
    if (ret < 0) {
      avcodec_free_context(&ctx->audioCodecCtx);
      return ret;
    }
    ret = avcodec_open2(ctx->audioCodecCtx, codec, nullptr);
    if (ret < 0) {
      avcodec_free_context(&ctx->audioCodecCtx);
      return ret;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "FfmpegInitCodecs: audio decoder opened: %s ch=%d sr=%d",
                 codec->name, ctx->audioCodecCtx->ch_layout.nb_channels,
                 ctx->audioCodecCtx->sample_rate);
  }
  return 0;
}

static int ReopenFfmpegAudioCodec(FfmpegContext *ctx) {
  if (ctx == nullptr || ctx->fmtCtx == nullptr) {
    return AVERROR(EINVAL);
  }
  const int audioStreamIdx = ctx->audioStreamIdx.load(std::memory_order_relaxed);
  if (audioStreamIdx < 0 || audioStreamIdx >= static_cast<int>(ctx->fmtCtx->nb_streams)) {
    return AVERROR_STREAM_NOT_FOUND;
  }
  AVStream *audioStream = ctx->fmtCtx->streams[audioStreamIdx];
  if (audioStream == nullptr || audioStream->codecpar == nullptr ||
      audioStream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
    return AVERROR(EINVAL);
  }

  const AVCodec *codec = avcodec_find_decoder(audioStream->codecpar->codec_id);
  if (codec == nullptr) {
    return AVERROR_DECODER_NOT_FOUND;
  }
  AVCodecContext *nextAudioCodecCtx = avcodec_alloc_context3(codec);
  if (nextAudioCodecCtx == nullptr) {
    return AVERROR(ENOMEM);
  }

  int ret = avcodec_parameters_to_context(nextAudioCodecCtx, audioStream->codecpar);
  if (ret < 0) {
    avcodec_free_context(&nextAudioCodecCtx);
    return ret;
  }
  ret = avcodec_open2(nextAudioCodecCtx, codec, nullptr);
  if (ret < 0) {
    avcodec_free_context(&nextAudioCodecCtx);
    return ret;
  }

  if (ctx->audioCodecCtx != nullptr) {
    avcodec_free_context(&ctx->audioCodecCtx);
  }
  ctx->audioCodecCtx = nextAudioCodecCtx;
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "ReopenFfmpegAudioCodec: stream=%{public}d codec=%{public}s",
               audioStreamIdx, codec->name);
  return 0;
}

// ---------------------------------------------------------------------------
// B2：视频解码线程
// ---------------------------------------------------------------------------

static void VideoDecodeThreadFunc(FfmpegContext *ctx) {
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VideoDecodeThread: started");
  AVFrame *frame = av_frame_alloc();
  if (!frame) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll", "VideoDecodeThread: av_frame_alloc failed");
    return;
  }

  while (ctx->decodeRunning.load()) {
    // 从 videoQueue 取 packet（背压等待）
    AVPacket *pkt = nullptr;
    {
      std::unique_lock<std::mutex> lock(ctx->videoQueue.mtx);
      ctx->videoQueue.cv.wait(lock, [&] {
        return !ctx->videoQueue.packets.empty() || ctx->videoQueue.abort || !ctx->decodeRunning.load();
      });
      if (!ctx->decodeRunning.load() || ctx->videoQueue.abort) {
        break;
      }
      pkt = ctx->videoQueue.packets.front();
      ctx->videoQueue.packets.pop();
    }
    ctx->videoQueue.cv.notify_all();  // 唤醒 demux 线程（队列有空位）

    // 发送到解码器
    int ret;
    {
      std::lock_guard<std::mutex> codecLk(ctx->codecMutex);
      ret = avcodec_send_packet(ctx->videoCodecCtx, pkt);
    }
    av_packet_free(&pkt);
    if (ret < 0) {
      if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
        char errbuf[64] = {0};
        av_strerror(ret, errbuf, sizeof(errbuf));
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "VideoDecodeThread: send_packet error: %s", errbuf);
      }
      continue;
    }

    // 接收所有可用解码帧
    while (ctx->decodeRunning.load()) {
      int receiveRet;
      {
        std::lock_guard<std::mutex> codecLk(ctx->codecMutex);
        receiveRet = avcodec_receive_frame(ctx->videoCodecCtx, frame);
      }
      if (receiveRet == AVERROR(EAGAIN) || receiveRet == AVERROR_EOF) {
        break;
      }
      if (receiveRet < 0) {
        break;
      }

      if (ctx->videoSyncGraceFrames.load(std::memory_order_relaxed) <= 0
          && !ctx->playbackPaused.load(std::memory_order_relaxed)) {
        const double videoPts = VideoFramePtsSeconds(ctx, frame);
        const double audioClock = AudioClock(ctx);
        const double diff = videoPts - audioClock;
        if (videoPts > 0.0 && diff < -3.0) {
          ctx->droppedDecodeFrames++;
          if (ctx->droppedDecodeFrames == 1 || (ctx->droppedDecodeFrames % 30) == 0) {
            int packetBacklog = 0;
            {
              std::lock_guard<std::mutex> lock(ctx->videoQueue.mtx);
              packetBacklog = static_cast<int>(ctx->videoQueue.packets.size());
            }
            OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                         "VideoDecodeThread: skip severely late frame diffMs=%{public}d videoPtsMs=%{public}d audioClockMs=%{public}d packetBacklog=%{public}d count=%{public}d",
                         static_cast<int>(diff * 1000.0),
                         static_cast<int>(videoPts * 1000.0),
                         static_cast<int>(audioClock * 1000.0),
                         packetBacklog,
                         ctx->droppedDecodeFrames);
          }
          av_frame_unref(frame);
          continue;
        }
        ctx->droppedDecodeFrames = 0;
      }

      // 将帧移入 videoFrameQueue（背压等待，防止解码过快撑爆内存）
      // ── B6：格式转换 + 超 1920 降采样 + CPU 侧 YUV→RGBA 转换 ──
      // 1. 所有格式统一通过 sws_scale 转换为 AV_PIX_FMT_RGBA（包括 yuv420p10le/yuv420p）
      // 2. 4K 内容（3840×2160）宽度超过 1920 时同步降采样（保持宽高比）
      // 3. 使用 GL_RGBA/GL_UNSIGNED_BYTE 上传单张纹理，规避设备驱动对 GL_R8/GL_LUMINANCE 的 OOM bug
      static const int DEFAULT_MAX_RENDER_W = 1920;
      static const int HEAVY_4K_MAX_RENDER_W = 1280;
      // 计算目标渲染分辨率（降采样到 1920 时保持宽高比，行/列对齐到偶数）
      int dstW = frame->width;
      int dstH = frame->height;
      int maxRenderW = DEFAULT_MAX_RENDER_W;
      if (frame->width >= 3840 &&
          (frame->format == AV_PIX_FMT_YUV420P10LE || frame->format == AV_PIX_FMT_P010LE)) {
        maxRenderW = HEAVY_4K_MAX_RENDER_W;
      }
      if (dstW > maxRenderW) {
        dstH = dstH * maxRenderW / dstW;
        dstW = maxRenderW;
        dstH = (dstH + 1) & ~1;  // 偶数对齐
      }
      // 始终转换到 RGBA：yuv420p 也需要转换（CPU 侧 YUV→RGB），消除 GL 侧单通道 OOM
      bool needConvert = true;
      AVFrame *renderFrame = frame;
      AVFrame *convertedFrame = nullptr;
      if (needConvert) {
        // 格式或源宽度变化时重建 SwsContext
        if (ctx->swsCtx == nullptr
            || ctx->lastSwsSrcFmt != frame->format
            || ctx->lastSwsSrcW   != frame->width) {
          if (ctx->swsCtx != nullptr) {
            sws_freeContext(ctx->swsCtx);
            ctx->swsCtx = nullptr;
          }
          ctx->swsCtx = sws_getContext(
              frame->width, frame->height, static_cast<AVPixelFormat>(frame->format),
              dstW, dstH, AV_PIX_FMT_RGBA,
              SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
            ctx->lastSwsSrcFmt = frame->format;
            ctx->lastSwsSrcW   = frame->width;
            OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                        "VideoDecodeThread: SwsContext created %{public}dx%{public}d srcFmt=%{public}d"
                        " -> %{public}dx%{public}d RGBA maxRenderW=%{public}d",
                        frame->width, frame->height, frame->format, dstW, dstH, maxRenderW);
          }
        if (ctx->swsCtx != nullptr) {
          convertedFrame = av_frame_alloc();
          if (convertedFrame != nullptr) {
            convertedFrame->format = AV_PIX_FMT_RGBA;
            convertedFrame->width  = dstW;
            convertedFrame->height = dstH;
            if (av_frame_get_buffer(convertedFrame, 32) == 0) {
              sws_scale(ctx->swsCtx,
                        reinterpret_cast<const uint8_t * const *>(frame->data),
                        frame->linesize, 0, frame->height,
                        convertedFrame->data, convertedFrame->linesize);
              convertedFrame->pts     = frame->pts;
              convertedFrame->best_effort_timestamp = frame->best_effort_timestamp;
              convertedFrame->pkt_dts = frame->pkt_dts;
              renderFrame = convertedFrame;
            } else {
              av_frame_free(&convertedFrame);
              convertedFrame = nullptr;
              OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                           "VideoDecodeThread: av_frame_get_buffer failed, fallback to raw frame");
            }
          }
        }
      }
      // ── 结束格式转换与降采样 ──

      AVFrame *frameCopy = av_frame_alloc();
      if (frameCopy) {
        // 使用 renderFrame（可能是转换后的 convertedFrame，也可能是原始 frame）
        av_frame_move_ref(frameCopy, renderFrame);
        std::unique_lock<std::mutex> lock(ctx->videoFrameQueue.mtx);
        ctx->videoFrameQueue.cv.wait(lock, [&] {
          return static_cast<int>(ctx->videoFrameQueue.frames.size()) < ctx->videoFrameQueue.maxSize
              || ctx->videoFrameQueue.abort
              || !ctx->decodeRunning.load();
        });
        if (!ctx->videoFrameQueue.abort && ctx->decodeRunning.load()) {
          ctx->videoFrameQueue.frames.push(frameCopy);
          lock.unlock();
          ctx->videoFrameQueue.cv.notify_all();
        } else {
          lock.unlock();
          av_frame_free(&frameCopy);
        }
      }
      // 释放 convertedFrame shell（move_ref 已转走数据引用，此处 free 空帧，安全）
      if (convertedFrame != nullptr) {
        av_frame_free(&convertedFrame);
      }
      // 清理原始 frame 数据引用（convertedFrame 转换时 frame 仍持有原始数据）
      av_frame_unref(frame);
    }  // end inner while (receive_frame loop)
  }

  av_frame_free(&frame);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VideoDecodeThread: exited");
}

// ---------------------------------------------------------------------------
// HW-B：OH_VideoDecoder + FFmpeg 音频混合路径
// ---------------------------------------------------------------------------

static void OnHwVideoError(OH_AVCodec *, int32_t err, void *userData) {
  (void)userData;
  OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll", "[HwVideoDecode] onError err=%{public}d", err);
}

static void OnHwVideoFormatChanged(OH_AVCodec *, OH_AVFormat *format, void *userData) {
  (void)format;
  (void)userData;
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] onStreamChanged");
}

// 解码器准备好输入 buffer 时回调 → 放入 hwInputPool 供 FeedThread 使用
static void OnHwVideoNeedInputBuffer(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *userData) {
  FfmpegContext *ctx = static_cast<FfmpegContext *>(userData);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "[HwVideoDecode] onNeedInputBuffer index=%{public}u bufCap=%{public}d",
               index, OH_AVBuffer_GetCapacity(buffer));
  {
    std::lock_guard<std::mutex> lk(ctx->hwInputMtx);
    ctx->hwInputPool.push({index, buffer});
  }
  ctx->hwInputCv.notify_one();
}

// 解码完成，输出 buffer 就绪 → 放入 hwOutputQueue 供 RenderThread 消费
static void OnHwVideoNewOutputBuffer(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *userData) {
  FfmpegContext *ctx = static_cast<FfmpegContext *>(userData);
  OH_AVCodecBufferAttr attr{};
  OH_AVBuffer_GetBufferAttr(buffer, &attr);
  const int64_t ptsMs = attr.pts / 1000;
  const bool isEos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
  {
    std::lock_guard<std::mutex> lk(ctx->hwOutputMtx);
    ctx->hwOutputQueue.push({index, ptsMs, isEos});
  }
  ctx->hwOutputCv.notify_one();
}

// Feed 线程：从 videoQueue 取 AVPacket，经 BSF 转换后塞入 OH_VideoDecoder 输入 buffer
static void HwVideoFeedThreadFunc(FfmpegContext *ctx) {
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] HwVideoFeedThread: started");

  // 辅助 lambda：等待一个 hwInputPool entry
  auto getInputEntry = [&](FfmpegContext::HwInputEntry &entry, bool &running) -> bool {
    std::unique_lock<std::mutex> lk(ctx->hwInputMtx);
    ctx->hwInputCv.wait_for(lk, std::chrono::milliseconds(200), [&] {
      return !ctx->hwInputPool.empty() || !ctx->hwVideoRunning.load();
    });
    if (!ctx->hwVideoRunning.load()) { running = false; return false; }
    if (ctx->hwInputPool.empty()) { return false; }
    entry = ctx->hwInputPool.front();
    ctx->hwInputPool.pop();
    return true;
  };

  // 辅助 lambda：将一个 AVPacket 推入 HW 解码器
  auto pushPktToDecoder = [&](AVPacket *pkt) -> bool {
    bool running = true;
    FfmpegContext::HwInputEntry entry{};
    if (!getInputEntry(entry, running)) {
      if (!running) return false;
      // 等待超时：打印诊断日志（每 10 次静默一次）
      static int timeoutCount = 0;
      if (++timeoutCount % 10 == 1) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "[HwVideoDecode] FeedThread: hwInputPool timeout #%{public}d (decoder not calling onNeedInputBuffer?)",
                     timeoutCount);
      }
      return true; // 丢弃这个 packet，继续
    }

    const uint8_t *bufPtr = OH_AVBuffer_GetAddr(entry.buffer);
    const int32_t capacity = OH_AVBuffer_GetCapacity(entry.buffer);
    if (bufPtr == nullptr || capacity < pkt->size) {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                   "[HwVideoDecode] FeedThread: buffer too small cap=%{public}d pktSize=%{public}d",
                   capacity, pkt->size);
      std::lock_guard<std::mutex> lk(ctx->hwInputMtx);
      ctx->hwInputPool.push(entry);
      ctx->hwInputCv.notify_one();
      return true;
    }
    std::memcpy(const_cast<uint8_t *>(bufPtr), pkt->data, static_cast<size_t>(pkt->size));

    const AVStream *vs = ctx->fmtCtx->streams[ctx->videoStreamIdx];
    const int64_t ptsUs = (pkt->pts != AV_NOPTS_VALUE)
        ? av_rescale_q(pkt->pts, vs->time_base, {1, 1000000}) : 0;

    OH_AVCodecBufferAttr attr{};
    attr.pts = ptsUs;
    attr.size = pkt->size;
    attr.offset = 0;
    attr.flags = (pkt->flags & AV_PKT_FLAG_KEY) ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : 0;
    OH_AVBuffer_SetBufferAttr(entry.buffer, &attr);
    OH_VideoDecoder_PushInputBuffer(ctx->hwVideoDecoder, entry.index);
    return true;
  };

  AVPacket *filteredPkt = av_packet_alloc();
  static int feedCount = 0;

  while (ctx->hwVideoRunning.load()) {
    if (ctx->hwVideoFlushPending.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }

    // 从 videoQueue 取 packet
    AVPacket *pkt = nullptr;
    {
      std::unique_lock<std::mutex> lk(ctx->videoQueue.mtx);
      ctx->videoQueue.cv.wait_for(lk, std::chrono::milliseconds(50), [&] {
        return !ctx->videoQueue.packets.empty() || ctx->videoQueue.abort || !ctx->hwVideoRunning.load();
      });
      if (!ctx->hwVideoRunning.load() || ctx->videoQueue.abort) break;
      if (ctx->videoQueue.packets.empty()) continue;
      pkt = ctx->videoQueue.packets.front();
      ctx->videoQueue.packets.pop();
    }
    ctx->videoQueue.cv.notify_all();

    if (++feedCount <= 5 || feedCount % 100 == 0) {
      const AVStream *vs = ctx->fmtCtx->streams[ctx->videoStreamIdx];
      const int64_t ptsMs = (pkt && pkt->pts != AV_NOPTS_VALUE)
          ? av_rescale_q(pkt->pts, vs->time_base, {1, 1000}) : -1;
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "[HwVideoDecode] FeedThread: got pkt #%{public}d ptsMs=%{public}lld size=%{public}d poolSize=%{public}zu",
                   feedCount, static_cast<long long>(ptsMs), pkt ? pkt->size : 0,
                   ctx->hwInputPool.size());
    }

    // EOS packet
    if (pkt == nullptr || pkt->size <= 0) {
      bool running = true;
      FfmpegContext::HwInputEntry entry{};
      if (getInputEntry(entry, running)) {
        OH_AVCodecBufferAttr attr{};
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(entry.buffer, &attr);
        OH_VideoDecoder_PushInputBuffer(ctx->hwVideoDecoder, entry.index);
      }
      if (pkt) av_packet_free(&pkt);
      break;
    }

    if (ctx->hwBsfCtx != nullptr) {
      // 通过 BSF 将 MPEG-4/HVCC 格式转换为 Annex-B
      int ret = av_bsf_send_packet(ctx->hwBsfCtx, pkt);
      av_packet_free(&pkt);
      if (ret < 0) continue;
      while (av_bsf_receive_packet(ctx->hwBsfCtx, filteredPkt) == 0) {
        pushPktToDecoder(filteredPkt);
        av_packet_unref(filteredPkt);
        if (!ctx->hwVideoRunning.load()) break;
      }
    } else {
      pushPktToDecoder(pkt);
      av_packet_free(&pkt);
    }
  }

  if (filteredPkt) av_packet_free(&filteredPkt);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] HwVideoFeedThread: exited");
}

// Render 线程：从 hwOutputQueue 取帧，AV Sync 后调用 RenderOutputBuffer / FreeOutputBuffer
static void HwVideoRenderThreadFunc(FfmpegContext *ctx) {
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] HwVideoRenderThread: started");
  int64_t renderCount = 0;
  int64_t lastRenderRealtimeMs = 0;  // 用于最小帧间隔限速，防止 burst → diff 骤增 → 冻帧的反馈环
  while (ctx->hwVideoRunning.load()) {
    // [Fix-Pause] pause 期间不消耗帧，让 HW 解码器自然因 output buffer 耗尽而暂停。
    // 这样 resume 后 ptsMs 仍在 pause 前的位置，避免 diff 虚高（曾导致 2-3 秒冻帧）。
    if (ctx->playbackPaused.load(std::memory_order_relaxed)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      continue;
    }

    FfmpegContext::HwOutputEntry entry{};
    {
      std::unique_lock<std::mutex> lk(ctx->hwOutputMtx);
      ctx->hwOutputCv.wait_for(lk, std::chrono::milliseconds(50), [&] {
        return !ctx->hwOutputQueue.empty() || !ctx->hwVideoRunning.load();
      });
      if (!ctx->hwVideoRunning.load() && ctx->hwOutputQueue.empty()) break;
      if (ctx->hwOutputQueue.empty()) continue;
      entry = ctx->hwOutputQueue.front();
      ctx->hwOutputQueue.pop();
    }

    if (entry.isEos) {
      OH_VideoDecoder_FreeOutputBuffer(ctx->hwVideoDecoder, entry.index);
      break;
    }

    // flush 期间：不调用 FreeOutputBuffer —— Flush 后 buffer index 已失效，
    // 调用 FreeOutputBuffer 会让解码器进入错误状态导致 onNewOutputBuffer 永久停止。
    // OH_VideoDecoder_Flush 会自动回收所有 pending buffer，无需手动释放。
    if (ctx->hwVideoFlushPending.load()) {
      continue;
    }

    // Seek 时钟门控：audioClockStartRealtimeMs=0 表示 seek 后时钟尚未开启，
    // 需要等 HW 解码器解完 keyframe pre-roll 到 seekTarget 附近再开门，
    // 防止时钟过早推进导致所有帧因"太迟"被丢弃（永久冻帧）。
    if (ctx->audioClockStartRealtimeMs.load(std::memory_order_relaxed) == 0) {
      const int64_t seekFloor = ctx->audioClockFloorMs.load(std::memory_order_relaxed);
      if (entry.ptsMs < seekFloor - 200) {
        // Pre-roll 帧（远早于 seek target），快速丢弃，不占用 grace counter
        OH_VideoDecoder_FreeOutputBuffer(ctx->hwVideoDecoder, entry.index);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "[HwVideoDecode] RenderThread: drop preroll ptsMs=%{public}lld floor=%{public}lld",
                     static_cast<long long>(entry.ptsMs), static_cast<long long>(seekFloor));
        continue;
      }
      // 到达 seek target 附近：开门，设置 wall-clock 锚点，后续走正常 AV sync
      const int64_t nowMs = NowRealtimeMs();
      ctx->audioClockStartRealtimeMs.store(nowMs, std::memory_order_relaxed);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "[AVSync] ClockGate OPEN: ptsMs=%{public}lld floor=%{public}lld nowMs=%{public}lld grace=%{public}d",
                   static_cast<long long>(entry.ptsMs),
                   static_cast<long long>(ctx->audioClockFloorMs.load(std::memory_order_relaxed)),
                   static_cast<long long>(nowMs),
                   static_cast<int>(ctx->videoSyncGraceFrames.load(std::memory_order_relaxed)));
    }

    // AV Sync：调用 AudioClock() 推进并读取当前音频时钟
    // 注意：HW 路径中没有其他线程调 AudioClock()，必须在这里调，否则 audioClockLastReportedMs 永远为 0
    const int64_t clockMs = static_cast<int64_t>(AudioClock(ctx) * 1000.0);
    const int64_t diffMs = entry.ptsMs - clockMs;

    // seek/startup 后前 N 帧使用 grace 模式：保护帧不被 drop，但仍做超前等待（防止撕裂/声音滞后）
    const bool inGrace = ctx->videoSyncGraceFrames.load(std::memory_order_relaxed) > 0;
    if (!inGrace && diffMs < -200) {
      // 帧明显落后（非 grace 期），丢弃；grace 期间不 drop，让画面先稳定出帧
      OH_VideoDecoder_FreeOutputBuffer(ctx->hwVideoDecoder, entry.index);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "[HwVideoDecode] RenderThread: drop late frame ptsMs=%{public}lld clockMs=%{public}lld",
                   static_cast<long long>(entry.ptsMs), static_cast<long long>(clockMs));
      continue;
    }
    if (inGrace) {
      ctx->videoSyncGraceFrames.fetch_sub(1, std::memory_order_relaxed);
    }
    // 渲染前限速：最小帧间隔 33ms（≈30fps 上限），防止 diff<0 时帧突发堆积
    if (lastRenderRealtimeMs > 0) {
      const int64_t sinceLastMs = NowRealtimeMs() - lastRenderRealtimeMs;
      const int64_t minIntervalMs = 33;  // ~30fps 限速
      if (sinceLastMs < minIntervalMs) {
        std::this_thread::sleep_for(std::chrono::milliseconds(minIntervalMs - sinceLastMs));
      }
    }
    // AV sync 等待：视频帧超前时钟时 sleep，上限 50ms/帧（保持 decoder output queue 持续消耗）。
    // diff 缓慢收敛：sleep=50ms → 每帧 realtime=83ms，clock 推进 83ms，PTS 推进 42ms → diff 每帧 -41ms
    // 收敛时间：diff=1000ms → 约 25 帧 × 83ms ≈ 2s；diff=4000ms → 约 98 帧 ≈ 8s
    // 不设 skip-wait：PTS 跳变（如流内 GOP 边界）时 clock 正常递增，跳过等待会使 diff 持续扩大
    if (diffMs > 10) {
      const int64_t sleepMs = std::min(diffMs - 5, (int64_t)50);
      std::this_thread::sleep_for(std::chrono::milliseconds(sleepMs));
      if (diffMs > 500) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "[AVSync] LargeSync ptsMs=%{public}lld clockMs=%{public}lld diff=%{public}lld",
                     static_cast<long long>(entry.ptsMs), static_cast<long long>(clockMs),
                     static_cast<long long>(diffMs));
      }
    }

    // 渲染到 Surface
    OH_VideoDecoder_RenderOutputBuffer(ctx->hwVideoDecoder, entry.index);
    lastRenderRealtimeMs = NowRealtimeMs();
    renderCount++;
    // [AVSync-Summary] 每300帧输出一次AV同步摘要，用于诊断声音滞后（过滤关键词: AVSync-Summary）
    if (renderCount % 300 == 1 || renderCount <= 5) {
      const int64_t ptsSamples = ctx->audioPtsSamples.load(std::memory_order_relaxed);
      const int64_t startRt = ctx->audioClockStartRealtimeMs.load(std::memory_order_relaxed);
      const int64_t baseMs2 = ctx->audioClockBaseMs.load(std::memory_order_relaxed);
      const int64_t sampleRate = ctx->audioSampleRate > 0 ? ctx->audioSampleRate : 48000;
      const int64_t ptsSamplesMs = ptsSamples * 1000LL / sampleRate;
      const int64_t elapsedMs = startRt > 0 ? (NowRealtimeMs() - startRt) : 0;
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "[AVSync-Summary] frame#%{public}lld ptsMs=%{public}lld clockMs=%{public}lld diff=%{public}lld "
                   "baseMs=%{public}lld ptsSampMs=%{public}lld elapsed=%{public}lld grace=%{public}d",
                   static_cast<long long>(renderCount),
                   static_cast<long long>(entry.ptsMs),
                   static_cast<long long>(clockMs),
                   static_cast<long long>(diffMs),
                   static_cast<long long>(baseMs2),
                   static_cast<long long>(ptsSamplesMs),
                   static_cast<long long>(elapsedMs),
                   static_cast<int>(inGrace));
    } else {
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "[HwVideoDecode] RenderThread: render ptsMs=%{public}lld clockMs=%{public}lld diff=%{public}lld grace=%{public}d",
                   static_cast<long long>(entry.ptsMs), static_cast<long long>(clockMs),
                   static_cast<long long>(diffMs),
                   static_cast<int>(inGrace));
    }
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] HwVideoRenderThread: exited");
}

// 初始化 OH_VideoDecoder，绑定 Surface，成功返回 true
static bool InitHwVideoDecoder(FfmpegContext *ctx, const char *mime, OHNativeWindow *window) {
  OH_AVCodec *decoder = OH_VideoDecoder_CreateByMime(mime);
  if (decoder == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "[HwVideoDecode] InitHwVideoDecoder: CreateByMime failed mime=%{public}s", mime);
    return false;
  }

  // 从 FFmpeg 流信息获取宽高
  int32_t width = 1920, height = 1080;
  if (ctx->videoStreamIdx >= 0 && ctx->fmtCtx != nullptr) {
    AVCodecParameters *par = ctx->fmtCtx->streams[ctx->videoStreamIdx]->codecpar;
    width = par->width > 0 ? par->width : 1920;
    height = par->height > 0 ? par->height : 1080;
  }

  // 1. RegisterCallback 必须在 Configure 之前（官方要求：Create→Register→Configure→SetSurface→Prepare→Start）
  OH_AVCodecCallback cb{};
  cb.onError = OnHwVideoError;
  cb.onStreamChanged = OnHwVideoFormatChanged;
  cb.onNeedInputBuffer = OnHwVideoNeedInputBuffer;
  cb.onNewOutputBuffer = OnHwVideoNewOutputBuffer;
  int32_t rc = OH_VideoDecoder_RegisterCallback(decoder, cb, ctx);
  if (rc != AV_ERR_OK) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "[HwVideoDecode] InitHwVideoDecoder: RegisterCallback failed rc=%{public}d", rc);
    OH_VideoDecoder_Destroy(decoder);
    return false;
  }

  // 2. Configure（Surface 输出模式下不设 OH_MD_KEY_PIXEL_FORMAT，由 Surface 决定格式）
  OH_AVFormat *format = OH_AVFormat_Create();
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);

  rc = OH_VideoDecoder_Configure(decoder, format);
  OH_AVFormat_Destroy(format);
  if (rc != AV_ERR_OK) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "[HwVideoDecode] InitHwVideoDecoder: Configure failed rc=%{public}d", rc);
    OH_VideoDecoder_Destroy(decoder);
    return false;
  }

  // 3. 绑定 NativeWindow（Surface 输出）
  rc = OH_VideoDecoder_SetSurface(decoder, window);
  if (rc != AV_ERR_OK) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "[HwVideoDecode] InitHwVideoDecoder: SetSurface failed rc=%{public}d", rc);
    OH_VideoDecoder_Destroy(decoder);
    return false;
  }

  // HDR 色彩空间：根据视频流 color_trc 设置 NativeWindow 色彩空间，使显示器启用 HDR 渲染
  // DV Profile 8 / HDR10 → PQ (SMPTE2084, color_trc=16)；HLG → color_trc=18
  if (ctx->videoStreamIdx >= 0 && ctx->fmtCtx != nullptr) {
    AVCodecParameters *par = ctx->fmtCtx->streams[ctx->videoStreamIdx]->codecpar;
    OH_NativeBuffer_ColorSpace csTarget = OH_COLORSPACE_NONE;
    if (par->color_trc == AVCOL_TRC_SMPTEST2084) {           // PQ / HDR10 / DolbyVision BL
      csTarget = OH_COLORSPACE_BT2020_PQ_LIMIT;
    } else if (par->color_trc == AVCOL_TRC_ARIB_STD_B67) {  // HLG
      csTarget = OH_COLORSPACE_BT2020_HLG_LIMIT;
    }
    if (csTarget != OH_COLORSPACE_NONE) {
      const int32_t csRc = OH_NativeWindow_SetColorSpace(window, csTarget);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "[HwVideoDecode] InitHwVideoDecoder: SetColorSpace colorSpace=%{public}d rc=%{public}d",
                   static_cast<int32_t>(csTarget), csRc);
    }
  }

  rc = OH_VideoDecoder_Prepare(decoder);
  if (rc != AV_ERR_OK) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "[HwVideoDecode] InitHwVideoDecoder: Prepare failed rc=%{public}d", rc);
    OH_VideoDecoder_Destroy(decoder);
    return false;
  }

  rc = OH_VideoDecoder_Start(decoder);
  if (rc != AV_ERR_OK) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "[HwVideoDecode] InitHwVideoDecoder: Start failed rc=%{public}d", rc);
    OH_VideoDecoder_Destroy(decoder);
    return false;
  }

  ctx->hwVideoDecoder = decoder;
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "[HwVideoDecode] InitHwVideoDecoder: OK mime=%{public}s %{public}dx%{public}d",
               mime, width, height);
  return true;
}

// Seek 时刷新 HW 解码器
static void FlushHwVideoDecoder(FfmpegContext *ctx) {
  if (ctx->hwVideoDecoder == nullptr) return;

  ctx->hwVideoFlushPending.store(true, std::memory_order_release);

  // Flush BSF：清除内部残留的 NALU 分包状态，否则 seek 后会把旧 Annex-B 残片混入新数据
  if (ctx->hwBsfCtx != nullptr) {
    av_bsf_flush(ctx->hwBsfCtx);
  }

  // 清空 hwInputPool（Flush 会重新触发 onNeedInputBuffer 补充 inputPool）
  {
    std::lock_guard<std::mutex> lk(ctx->hwInputMtx);
    while (!ctx->hwInputPool.empty()) ctx->hwInputPool.pop();
  }
  ctx->hwInputCv.notify_all();  // 唤醒 FeedThread 感知 pool 已清空

  // 先将 hwOutputQueue 里的帧正式归还给解码器，再调 Flush。
  // 若直接 Flush 而不 Free，RenderThread 可能用失效 index 调 FreeOutputBuffer，
  // 导致解码器进入错误状态并永久停止输出（seek 后黑屏/冻帧根因）。
  {
    std::lock_guard<std::mutex> lk(ctx->hwOutputMtx);
    while (!ctx->hwOutputQueue.empty()) {
      const auto &e = ctx->hwOutputQueue.front();
      if (!e.isEos) {
        OH_VideoDecoder_FreeOutputBuffer(ctx->hwVideoDecoder, e.index);
      }
      ctx->hwOutputQueue.pop();
    }
  }
  ctx->hwOutputCv.notify_all();

  // Flush decoder
  OH_AVErrCode flushRet = OH_VideoDecoder_Flush(ctx->hwVideoDecoder);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "[HwVideoDecode] FlushHwVideoDecoder: OH_VideoDecoder_Flush ret=%{public}d", static_cast<int>(flushRet));

  // OH_VideoDecoder_Flush 后必须重新 Start，否则解码器不再触发 onNeedInputBuffer
  OH_AVErrCode startRet = OH_VideoDecoder_Start(ctx->hwVideoDecoder);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "[HwVideoDecode] FlushHwVideoDecoder: OH_VideoDecoder_Start ret=%{public}d", static_cast<int>(startRet));

  // Start 后等待解码器调用 onNeedInputBuffer，确保 FeedThread 有可用 slot 再接收第一个 keyframe。
  // 若 keyframe 在 onNeedInputBuffer 触发前被 FeedThread 因超时丢弃，解码器将永远没有参考帧输出。
  {
    std::unique_lock<std::mutex> lk(ctx->hwInputMtx);
    const bool ready = ctx->hwInputCv.wait_for(lk, std::chrono::milliseconds(1500), [&] {
      return !ctx->hwInputPool.empty() || !ctx->hwVideoRunning.load();
    });
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "[HwVideoDecode] FlushHwVideoDecoder: post-Start ready=%d poolSize=%{public}zu",
                 ready ? 1 : 0, ctx->hwInputPool.size());
  }

  ctx->hwVideoFlushPending.store(false, std::memory_order_release);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] FlushHwVideoDecoder: done");
}

// 停止并销毁 HW 解码器（由 StopFfmpegDecode 调用）
static void DestroyHwVideoDecoder(FfmpegContext *ctx) {
  ctx->hwVideoRunning.store(false, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lk(ctx->videoQueue.mtx);
    ctx->videoQueue.abort = true;
  }
  ctx->videoQueue.cv.notify_all();
  ctx->hwInputCv.notify_all();
  ctx->hwOutputCv.notify_all();

  if (ctx->hwVideoRenderThread.joinable()) ctx->hwVideoRenderThread.join();
  if (ctx->hwVideoFeedThread.joinable())   ctx->hwVideoFeedThread.join();

  if (ctx->hwVideoDecoder != nullptr) {
    OH_VideoDecoder_Stop(ctx->hwVideoDecoder);
    OH_VideoDecoder_Destroy(ctx->hwVideoDecoder);
    ctx->hwVideoDecoder = nullptr;
  }
  if (ctx->hwBsfCtx != nullptr) {
    av_bsf_free(&ctx->hwBsfCtx);
    ctx->hwBsfCtx = nullptr;
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "[HwVideoDecode] DestroyHwVideoDecoder: done");
}

// ---------------------------------------------------------------------------
// B2：音频解码线程
// ---------------------------------------------------------------------------

static void AudioDecodeThreadFunc(FfmpegContext *ctx) {
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "AudioDecodeThread: started");
  AVFrame *frame = av_frame_alloc();
  if (!frame) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll", "AudioDecodeThread: av_frame_alloc failed");
    return;
  }

  while (ctx->decodeRunning.load()) {
    // 从 audioQueue 取 packet
    AVPacket *pkt = nullptr;
    {
      std::unique_lock<std::mutex> lock(ctx->audioQueue.mtx);
      ctx->audioQueue.cv.wait(lock, [&] {
        return !ctx->audioQueue.packets.empty() || ctx->audioQueue.abort || !ctx->decodeRunning.load();
      });
      if (!ctx->decodeRunning.load() || ctx->audioQueue.abort) {
        break;
      }
      pkt = ctx->audioQueue.packets.front();
      ctx->audioQueue.packets.pop();
    }
    ctx->audioQueue.cv.notify_all();

    // 发送到解码器
    int ret;
    {
      std::lock_guard<std::mutex> codecLk(ctx->codecMutex);
      ret = avcodec_send_packet(ctx->audioCodecCtx, pkt);
    }
    av_packet_free(&pkt);
    if (ret < 0) {
      if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
        char errbuf[64] = {0};
        av_strerror(ret, errbuf, sizeof(errbuf));
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "AudioDecodeThread: send_packet error: %s", errbuf);
      }
      continue;
    }

    // 接收所有可用解码帧（PCM，格式转换在 B4 做）
    while (ctx->decodeRunning.load()) {
      int receiveRet;
      {
        std::lock_guard<std::mutex> codecLk(ctx->codecMutex);
        receiveRet = avcodec_receive_frame(ctx->audioCodecCtx, frame);
      }
      if (receiveRet == AVERROR(EAGAIN) || receiveRet == AVERROR_EOF) {
        break;
      }
      if (receiveRet < 0) {
        break;
      }

      AVFrame *frameCopy = av_frame_alloc();
      if (frameCopy) {
        av_frame_move_ref(frameCopy, frame);
        std::unique_lock<std::mutex> lock(ctx->audioFrameQueue.mtx);
        ctx->audioFrameQueue.cv.wait(lock, [&] {
          return static_cast<int>(ctx->audioFrameQueue.frames.size()) < ctx->audioFrameQueue.maxSize
              || ctx->audioFrameQueue.abort
              || !ctx->decodeRunning.load();
        });
        if (!ctx->audioFrameQueue.abort && ctx->decodeRunning.load()) {
          ctx->audioFrameQueue.frames.push(frameCopy);
          lock.unlock();
          ctx->audioFrameQueue.cv.notify_all();
        } else {
          lock.unlock();
          av_frame_free(&frameCopy);
        }
      }
    }
  }

  av_frame_free(&frame);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "AudioDecodeThread: exited");
}

static void StopFfmpegAudioDecodeThread(FfmpegContext *ctx) {
  if (ctx == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lk(ctx->audioFrameQueue.mtx);
    ctx->audioFrameQueue.abort = true;
  }
  ctx->audioFrameQueue.cv.notify_all();
  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    ctx->audioQueue.abort = true;
  }
  ctx->audioQueue.cv.notify_all();
  if (ctx->audioDecodeThread.joinable()) {
    ctx->audioDecodeThread.join();
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegAudioDecodeThread: audio decode thread stopped");
}

static void StartFfmpegAudioDecodeThread(FfmpegContext *ctx) {
  if (ctx == nullptr || ctx->audioCodecCtx == nullptr || !ctx->decodeRunning.load()) {
    return;
  }
  {
    std::lock_guard<std::mutex> lk(ctx->audioFrameQueue.mtx);
    ctx->audioFrameQueue.abort = false;
  }
  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    ctx->audioQueue.abort = false;
  }
  if (!ctx->audioDecodeThread.joinable()) {
    ctx->audioDecodeThread = std::thread(AudioDecodeThreadFunc, ctx);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StartFfmpegAudioDecodeThread: audio decode thread restarted");
}

// ---------------------------------------------------------------------------
// B2：启动/停止解码线程
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// B3：GLSL shader 字符串（直接采样 RGBA 纹理，GPU 侧无需 YUV→RGB 转换）
// ---------------------------------------------------------------------------
// sws_scale 在 CPU 侧已完成 yuv420p → RGBA 转换，shader 只需 passthrough 采样。
// 使用 GL_RGBA/GL_UNSIGNED_BYTE 是所有 GLES 版本中最兼容的格式，
// 彻底规避 GL_R8/GL_LUMINANCE 在部分 HarmonyOS 驱动上的 OOM(0x505) bug。

static const char *kVertexShaderSrc =
    "#version 100\n"
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texCoord;\n"
    "varying vec2 v_texCoord;\n"
    "void main() {\n"
    "    gl_Position = a_position;\n"
    "    v_texCoord = a_texCoord;\n"
    "}\n";

static const char *kFragmentShaderSrc =
    "#version 100\n"
    "precision mediump float;\n"
    "uniform sampler2D u_texture;\n"
    "varying vec2 v_texCoord;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(u_texture, v_texCoord);\n"
    "}\n";

// ---------------------------------------------------------------------------
// B3：通过 eglGetProcAddress 加载 GL 函数指针（适配 HarmonyOS GLES dispatch 机制）
// ---------------------------------------------------------------------------

static bool LoadGLFunctions(GlFunctions &gl) {
#define LOAD(field, name) \
    gl.field = reinterpret_cast<decltype(gl.field)>(eglGetProcAddress(name)); \
    if (!gl.field) { \
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll", \
                     "LoadGLFunctions: eglGetProcAddress(%{public}s) returned null", name); \
        return false; \
    }
    LOAD(CreateShader,            "glCreateShader")
    LOAD(ShaderSource,            "glShaderSource")
    LOAD(CompileShader,           "glCompileShader")
    LOAD(GetShaderiv,             "glGetShaderiv")
    LOAD(GetShaderInfoLog,        "glGetShaderInfoLog")
    LOAD(DeleteShader,            "glDeleteShader")
    LOAD(CreateProgram,           "glCreateProgram")
    LOAD(AttachShader,            "glAttachShader")
    LOAD(BindAttribLocation,      "glBindAttribLocation")
    LOAD(LinkProgram,             "glLinkProgram")
    LOAD(DeleteProgram,           "glDeleteProgram")
    LOAD(GetProgramiv,            "glGetProgramiv")
    LOAD(UseProgram,              "glUseProgram")
    LOAD(GetUniformLocation,      "glGetUniformLocation")
    LOAD(Uniform1i,               "glUniform1i")
    LOAD(GenTextures,             "glGenTextures")
    LOAD(BindTexture,             "glBindTexture")
    LOAD(TexParameteri,           "glTexParameteri")
    LOAD(TexImage2D,              "glTexImage2D")
    LOAD(TexSubImage2D,           "glTexSubImage2D")
    LOAD(ActiveTexture,           "glActiveTexture")
    LOAD(DeleteTextures,          "glDeleteTextures")
    LOAD(GenBuffers,              "glGenBuffers")
    LOAD(BindBuffer,              "glBindBuffer")
    LOAD(BufferData,              "glBufferData")
    LOAD(DeleteBuffers,           "glDeleteBuffers")
    LOAD(VertexAttribPointer,     "glVertexAttribPointer")
    LOAD(EnableVertexAttribArray, "glEnableVertexAttribArray")
    LOAD(DisableVertexAttribArray,"glDisableVertexAttribArray")
    LOAD(DrawArrays,              "glDrawArrays")
    LOAD(Viewport,                "glViewport")
    LOAD(ClearColor,              "glClearColor")
    LOAD(Clear,                   "glClear")
    LOAD(PixelStorei,             "glPixelStorei")
    LOAD(GetError,                "glGetError")
    LOAD(GetString,               "glGetString")
    LOAD(GetIntegerv,             "glGetIntegerv")
#undef LOAD
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "LoadGLFunctions: all %{public}d GL functions loaded", 37);
    return true;
}

// ---------------------------------------------------------------------------
// B3：EGL 初始化（在渲染线程内调用，nativeWindow 提供 EGLNativeWindowType）
// ---------------------------------------------------------------------------

static bool FfmpegInitEGL(FfmpegContext *ctx, OHNativeWindow *nativeWindow) {
  ctx->eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (ctx->eglDisplay == EGL_NO_DISPLAY) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglGetDisplay failed");
    return false;
  }
  EGLint major = 0, minor = 0;
  if (!eglInitialize(ctx->eglDisplay, &major, &minor)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglInitialize failed err=0x%{public}x", eglGetError());
    return false;
  }
  // 修复 #48-B6: HarmonyOS 必须显式绑定 EGL client API，否则 eglMakeCurrent 后
  // GL dispatch table 不挂载，所有 GL 函数（含 glCreateShader）均走 no-op 返回 0
  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglBindAPI failed err=0x%{public}x", eglGetError());
    return false;
  }
  // 修复 #48-B6: config 必须使用 EGL_OPENGL_ES3_BIT，与 GLES 3 context 匹配。
  // 若用 EGL_OPENGL_ES2_BIT 选 config 再创建 GLES 3 context，驱动会限制 GPU 纹理内存池，
  // 导致即使 1920×1080 的 GL_R8 纹理也返回 GL_OUT_OF_MEMORY（0x505）。
  EGLint attribs[] = {
      EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_RED_SIZE,   8,
      EGL_GREEN_SIZE, 8,
      EGL_BLUE_SIZE,  8,
      EGL_ALPHA_SIZE, 8,
      EGL_DEPTH_SIZE, 0,
      EGL_STENCIL_SIZE, 0,
      EGL_SAMPLE_BUFFERS, 0,
      EGL_NONE
  };
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (!eglChooseConfig(ctx->eglDisplay, attribs, &config, 1, &numConfigs) ||
      numConfigs == 0) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglChooseConfig failed err=0x%{public}x", eglGetError());
    return false;
  }
  // 修复4 (#48-B6): HarmonyOS 必须在 eglCreateWindowSurface 前设置 NativeWindow buffer 格式
  //   与 EGL Config 匹配，否则返回 EGL_BAD_MATCH (0x3009)。
  EGLint nativeVisualId = 0;
  eglGetConfigAttrib(ctx->eglDisplay, config, EGL_NATIVE_VISUAL_ID, &nativeVisualId);
  if (nativeVisualId == 0) {
    nativeVisualId = 3;  // fallback: NATIVEBUFFER_PIXEL_FMT_RGBA_8888 = 3 in OpenHarmony
  }
  const int32_t targetBufferW = 1920;
  const int32_t targetBufferH = 1080;
  const uint64_t usage = static_cast<uint64_t>(NATIVEBUFFER_USAGE_HW_RENDER | NATIVEBUFFER_USAGE_HW_TEXTURE);
  const int32_t rcFormat = OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_FORMAT, nativeVisualId);
  const int32_t rcGeometry = OH_NativeWindow_NativeWindowHandleOpt(
      nativeWindow, SET_BUFFER_GEOMETRY, targetBufferW, targetBufferH);
  const int32_t rcUsage = OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_USAGE, usage);
  const int32_t rcSwapInterval = OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_SWAP_INTERVAL, 0);
  int32_t bufferH = 0;
  int32_t bufferW = 0;
  int32_t bufferFormat = 0;
  uint64_t bufferUsage = 0;
  int32_t bufferSwapInterval = -1;
  const int32_t rcGetGeometry = OH_NativeWindow_NativeWindowHandleOpt(
      nativeWindow, GET_BUFFER_GEOMETRY, &bufferH, &bufferW);
  const int32_t rcGetFormat = OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, GET_FORMAT, &bufferFormat);
  const int32_t rcGetUsage = OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, GET_USAGE, &bufferUsage);
  const int32_t rcGetSwapInterval = OH_NativeWindow_NativeWindowHandleOpt(
      nativeWindow, GET_SWAP_INTERVAL, &bufferSwapInterval);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitEGL: window=%{public}p format=%{public}d rcFormat=%{public}d target=%{public}d x %{public}d rcGeometry=%{public}d rcUsage=%{public}d rcSwapInterval=%{public}d",
               nativeWindow, nativeVisualId, rcFormat, targetBufferW, targetBufferH,
               rcGeometry, rcUsage, rcSwapInterval);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitEGL: queried geometry=%{public}d x %{public}d rcGetGeometry=%{public}d format=%{public}d rcGetFormat=%{public}d usage=%{public}llu rcGetUsage=%{public}d swapInterval=%{public}d rcGetSwapInterval=%{public}d",
               bufferW, bufferH, rcGetGeometry, bufferFormat, rcGetFormat,
               static_cast<unsigned long long>(bufferUsage), rcGetUsage,
               bufferSwapInterval, rcGetSwapInterval);

  // 清除历史 EGL 错误，确保后续 eglGetError 干净
  (void)eglGetError();
  // 修复3: eglCreateWindowSurface 失败时重试 3 次（间隔 100ms），
  //        防御 OH_AVPlayer 异步清理尚未完成导致 Window 仍被占用的情况。
  ctx->eglSurface = EGL_NO_SURFACE;
  for (int attempt = 0; attempt < 3 && ctx->eglSurface == EGL_NO_SURFACE; attempt++) {
    if (attempt > 0) {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                   "FfmpegInitEGL: retry eglCreateWindowSurface attempt=%{public}d", attempt + 1);
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      (void)eglGetError(); // 重试前清除错误
    }
    ctx->eglSurface = eglCreateWindowSurface(
        ctx->eglDisplay, config,
        reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
  }
  if (ctx->eglSurface == EGL_NO_SURFACE) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglCreateWindowSurface failed after 3 attempts"
                 " err=0x%{public}x window=%{public}p",
                 eglGetError(), nativeWindow);
    return false;
  }
  // 修复 #48-B6: 设备驱动始终返回 GLES 3.2 context（GL_VERSION=OpenGL ES 3.2），
  // GL_LUMINANCE 在 GLES 3 中已废弃，即使 1920×1080 也触发 OOM（0x505）。
  // 改用 GLES 3 context + GL_R8（GLES 3 标准单通道格式），配合 sws_scale 1920 降采样。
  EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  ctx->eglContext =
      eglCreateContext(ctx->eglDisplay, config, EGL_NO_CONTEXT, ctxAttribs);
  if (ctx->eglContext == EGL_NO_CONTEXT) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglCreateContext failed err=0x%{public}x", eglGetError());
    return false;
  }
  EGLint cfgBufferSize = 0;
  EGLint cfgAlphaSize = 0;
  EGLint cfgDepthSize = 0;
  EGLint cfgStencilSize = 0;
  eglGetConfigAttrib(ctx->eglDisplay, config, EGL_BUFFER_SIZE, &cfgBufferSize);
  eglGetConfigAttrib(ctx->eglDisplay, config, EGL_ALPHA_SIZE, &cfgAlphaSize);
  eglGetConfigAttrib(ctx->eglDisplay, config, EGL_DEPTH_SIZE, &cfgDepthSize);
  eglGetConfigAttrib(ctx->eglDisplay, config, EGL_STENCIL_SIZE, &cfgStencilSize);
  // 修复 #48-B6: %{public}d 让 EGL 版本号在 HarmonyOS hilog 中可见
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                "FfmpegInitEGL: OK EGL %{public}d.%{public}d", major, minor);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitEGL: config nativeVisualId=%{public}d bufferSize=%{public}d alpha=%{public}d depth=%{public}d stencil=%{public}d",
               nativeVisualId, cfgBufferSize, cfgAlphaSize, cfgDepthSize, cfgStencilSize);
  return true;
}

// ---------------------------------------------------------------------------
// B3：shader 编译辅助
// ---------------------------------------------------------------------------

static GLuint CompileShader(const GlFunctions &gl, GLenum type, const char *src) {
  const GLuint shader = gl.CreateShader(type);
  if (shader == 0) {
    // 修复 #48-B6: glCreateShader 返回 0 说明 GL context 尚未生效
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "CompileShader: CreateShader returned 0 type=%{public}u",
                 type);
    return 0;
  }
  gl.ShaderSource(shader, 1, &src, nullptr);
  gl.CompileShader(shader);
  GLint status = 0;
  gl.GetShaderiv(shader, GL_COMPILE_STATUS, &status);
  if (status == GL_FALSE) {
    GLint len = 0;
    gl.GetShaderiv(shader, GL_INFO_LOG_LENGTH, &len);
    if (len > 1) {
      std::string log(static_cast<size_t>(len), '\0');
      gl.GetShaderInfoLog(shader, len, nullptr, &log[0]);
      // 修复 #48-B6: %{public}s 才能在 HarmonyOS hilog 中显示字符串内容（%s 为私有格式）
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                   "CompileShader: type=%{public}u compile error: %{public}s",
                   type, log.c_str());
    } else {
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                   "CompileShader: type=%{public}u compile error (no info log)", type);
    }
    gl.DeleteShader(shader);
    return 0;
  }
  return shader;
}

// ---------------------------------------------------------------------------
// B3：GL 资源初始化（在渲染线程 makeCurrent 后调用）
// ---------------------------------------------------------------------------

static bool FfmpegInitGLResources(FfmpegContext *ctx) {
  // 1. 编译 & 链接 YUV→RGB program
  const GLuint vs = CompileShader(ctx->gl, GL_VERTEX_SHADER, kVertexShaderSrc);
  const GLuint fs = CompileShader(ctx->gl, GL_FRAGMENT_SHADER, kFragmentShaderSrc);
  if (vs == 0 || fs == 0) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitGLResources: shader compile failed");
    if (vs != 0) { ctx->gl.DeleteShader(vs); }
    if (fs != 0) { ctx->gl.DeleteShader(fs); }
    return false;
  }
  ctx->yuvProgram = ctx->gl.CreateProgram();
  ctx->gl.AttachShader(ctx->yuvProgram, vs);
  ctx->gl.AttachShader(ctx->yuvProgram, fs);
  ctx->gl.BindAttribLocation(ctx->yuvProgram, 0, "a_position");
  ctx->gl.BindAttribLocation(ctx->yuvProgram, 1, "a_texCoord");
  ctx->gl.LinkProgram(ctx->yuvProgram);
  ctx->gl.DeleteShader(vs);
  ctx->gl.DeleteShader(fs);
  GLint linked = 0;
  ctx->gl.GetProgramiv(ctx->yuvProgram, GL_LINK_STATUS, &linked);
  if (linked == GL_FALSE) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitGLResources: program link failed");
    ctx->gl.DeleteProgram(ctx->yuvProgram);
    ctx->yuvProgram = 0;
    return false;
  }

  // 2. 绑定 sampler uniform（GL_TEXTURE0 = RGBA 纹理）
  ctx->gl.UseProgram(ctx->yuvProgram);
  ctx->gl.Uniform1i(ctx->gl.GetUniformLocation(ctx->yuvProgram, "u_texture"), 0);

  // 3. 创建单张 GL_RGBA 纹理（sws_scale 已在 CPU 侧完成 YUV→RGBA 转换）
  ctx->gl.GenTextures(1, &ctx->rgbaTexture);
  ctx->gl.BindTexture(GL_TEXTURE_2D, ctx->rgbaTexture);
  ctx->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  ctx->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  ctx->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  ctx->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  ctx->gl.BindTexture(GL_TEXTURE_2D, 0);

  // 4. 全屏四边形 VBO（triangle strip，x/y 为 NDC，s/t 为 UV）
  // 顺序：左下、右下、左上、右上（匹配 UV 坐标 y 从下往上）
  const float quadVertices[] = {
      -1.0f, -1.0f,  0.0f, 1.0f,
       1.0f, -1.0f,  1.0f, 1.0f,
      -1.0f,  1.0f,  0.0f, 0.0f,
       1.0f,  1.0f,  1.0f, 0.0f,
  };
  ctx->gl.GenBuffers(1, &ctx->quadVBO);
  ctx->gl.BindBuffer(GL_ARRAY_BUFFER, ctx->quadVBO);
  ctx->gl.BufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(sizeof(quadVertices)),
               quadVertices, GL_STATIC_DRAW);
  ctx->gl.BindBuffer(GL_ARRAY_BUFFER, 0);

  // 修复 #48-B6: %{public}u 让资源 ID 在 hilog 中可见
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitGLResources: OK prog=%{public}u rgba=%{public}u vbo=%{public}u",
               ctx->yuvProgram, ctx->rgbaTexture, ctx->quadVBO);
  return true;
}

// ---------------------------------------------------------------------------
// B3：GL 资源释放（在渲染线程内、eglMakeCurrent 有效时调用）
// ---------------------------------------------------------------------------

static void FfmpegCleanupGLResources(FfmpegContext *ctx) {
  if (ctx->quadVBO != 0) {
    ctx->gl.DeleteBuffers(1, &ctx->quadVBO);
    ctx->quadVBO = 0;
  }
  if (ctx->rgbaTexture != 0) {
    ctx->gl.DeleteTextures(1, &ctx->rgbaTexture);
    ctx->rgbaTexture = 0;
  }
  if (ctx->yuvProgram != 0) {
    ctx->gl.DeleteProgram(ctx->yuvProgram);
    ctx->yuvProgram = 0;
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegCleanupGLResources: done");
}

// ---------------------------------------------------------------------------
// B3：渲染线程（消费 videoFrameQueue，上传 YUV 纹理，eglSwapBuffers）
// ---------------------------------------------------------------------------

static void RenderThreadFunc(NativePlayerSkeletonState *state) {
  FfmpegContext *ctx = state->ffmpegCtx.get();

  // 0. 在锁内读取 nativeWindow 到局部变量，避免与 OnXCSurfaceDestroyed 的竞态。
  //    注意：不在此处释放 avPlayer —— OH_AVPlayer code=9 从未创建 EGL 资源，
  //    且 Release() 会在播放器销毁时正确清理。
  OHNativeWindow *localWindow = nullptr;
  {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    localWindow = state->nativeWindow;
  }

  if (localWindow == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: nativeWindow is null, abort");
    ctx->renderRunning.store(false);
    return;
  }

  // 1. EGL 初始化（使用局部保存的 localWindow，不受 OH_AVPlayer_Release 回调影响）
  if (!FfmpegInitEGL(ctx, localWindow)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: FfmpegInitEGL failed, exit");
    ctx->renderRunning.store(false);
    return;
  }

  // 2. 将 EGL context 绑定到当前线程
  // 修复 #48-B6: 线程级显式 bind API，确保此线程的 GL dispatch table 正确挂载
  eglBindAPI(EGL_OPENGL_ES_API);
  if (!eglMakeCurrent(ctx->eglDisplay, ctx->eglSurface,
                      ctx->eglSurface, ctx->eglContext)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: eglMakeCurrent failed err=0x%{public}x", eglGetError());
    ctx->renderRunning.store(false);
    return;
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "RenderThreadFunc: eglMakeCurrent OK, GL context current ctx=%{public}p",
               static_cast<void*>(eglGetCurrentContext()));
  {
    const EGLBoolean swapIntervalOk = eglSwapInterval(ctx->eglDisplay, 0);
    const EGLint swapIntervalErr = eglGetError();
    OH_LOG_Print(LOG_APP, swapIntervalOk == EGL_TRUE ? LOG_INFO : LOG_WARN, 0xFF00, "VidAll",
                 "RenderThreadFunc: eglSwapInterval(0) ok=%{public}d err=0x%{public}x",
                 swapIntervalOk == EGL_TRUE ? 1 : 0, swapIntervalErr);
  }

  // B3：加载 GL 函数指针（HarmonyOS 需要通过 eglGetProcAddress 动态加载）
  if (!LoadGLFunctions(ctx->gl)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: LoadGLFunctions failed, exit");
    ctx->renderRunning.store(false);
    return;
  }

  // GL context 验证诊断（使用已加载的函数指针）
  {
    const GLubyte *glVer = ctx->gl.GetString(GL_VERSION);
    const GLubyte *glVendor = ctx->gl.GetString(GL_VENDOR);
    const GLubyte *glRenderer = ctx->gl.GetString(GL_RENDERER);
    const GLubyte *glslVer = ctx->gl.GetString(GL_SHADING_LANGUAGE_VERSION);
    GLint maxTextureSize = 0;
    ctx->gl.GetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
    GLenum glErr = ctx->gl.GetError();
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "RenderThreadFunc: GL_VERSION=%{public}s glGetError=0x%{public}x",
                 glVer ? (const char*)glVer : "null", glErr);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "RenderThreadFunc: GL_VENDOR=%{public}s GL_RENDERER=%{public}s GLSL=%{public}s maxTex=%{public}d",
                 glVendor ? (const char*)glVendor : "null",
                 glRenderer ? (const char*)glRenderer : "null",
                 glslVer ? (const char*)glslVer : "null",
                 maxTextureSize);
  }

  // 3. 初始化 GL 资源（shader/纹理/VBO）
  if (!FfmpegInitGLResources(ctx)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: FfmpegInitGLResources failed, exit");
    ctx->renderRunning.store(false);
    return;
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "RenderThreadFunc: render loop started");

  // Fix #48-B6-1a：设置 Viewport 为 EGL surface 实际尺寸（全屏渲染）
  // GLES 默认 viewport 为 (0,0,0,0)，不调此函数所有绘制结果均被裁剪到空区域导致黑屏。
  {
    EGLint surfW = 0, surfH = 0;
    eglQuerySurface(ctx->eglDisplay, ctx->eglSurface, EGL_WIDTH, &surfW);
    eglQuerySurface(ctx->eglDisplay, ctx->eglSurface, EGL_HEIGHT, &surfH);
    if (surfW > 0 && surfH > 0) {
      ctx->gl.Viewport(0, 0, surfW, surfH);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "RenderThreadFunc: Viewport set to %{public}d x %{public}d", surfW, surfH);
    } else {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                   "RenderThreadFunc: eglQuerySurface failed, surfW=%{public}d surfH=%{public}d",
                   surfW, surfH);
    }
    // 初始清屏，确保第一帧前屏幕不显示随机内容
    ctx->gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    ctx->gl.Clear(GL_COLOR_BUFFER_BIT);
    const EGLBoolean probeSwapOk = eglSwapBuffers(ctx->eglDisplay, ctx->eglSurface);
    const EGLint probeSwapErr = eglGetError();
    OH_LOG_Print(LOG_APP, probeSwapOk == EGL_TRUE ? LOG_INFO : LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: probe eglSwapBuffers ok=%{public}d err=0x%{public}x",
                 probeSwapOk == EGL_TRUE ? 1 : 0, probeSwapErr);
  }

  // B5：时间上报节流（每 200ms 通过 tsfOnTimeUpdate 上报一次播放位置）
  auto lastEmitTime = std::chrono::steady_clock::now() - std::chrono::seconds(1);

  while (ctx->renderRunning.load()) {
    if (ctx->playbackPaused.load(std::memory_order_relaxed)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(16));
      continue;
    }

    // 4. 从 videoFrameQueue 消费一帧（最多等 16ms）
    AVFrame *frame = nullptr;
    {
      std::unique_lock<std::mutex> lock(ctx->videoFrameQueue.mtx);
      ctx->videoFrameQueue.cv.wait_for(lock, std::chrono::milliseconds(16), [&] {
        return !ctx->videoFrameQueue.frames.empty() ||
               ctx->videoFrameQueue.abort;
      });
      if (!ctx->videoFrameQueue.frames.empty()) {
        frame = ctx->videoFrameQueue.frames.front();
        ctx->videoFrameQueue.frames.pop();
      }
    }
    // 通知解码线程队列有空位
    ctx->videoFrameQueue.cv.notify_all();

    if (frame == nullptr) {
      continue;
    }

    // B5：AV 同步：以音频时钟为主时钟，决定等待或丢帧
    if (ctx->videoStreamIdx >= 0 && ctx->audioSampleRate > 0) {
      const int64_t frameTs = (frame->best_effort_timestamp != AV_NOPTS_VALUE)
          ? frame->best_effort_timestamp
          : frame->pts;
      const bool bypassSync = ctx->videoSyncGraceFrames.load(std::memory_order_relaxed) > 0
          || frameTs == AV_NOPTS_VALUE;
      if (!bypassSync) {
        const double videoPts = VideoFramePtsSeconds(ctx, frame);
        double audioClock = AudioClock(ctx);
        double diff = videoPts - audioClock;

        if (diff > 0.09) {
          // 视频略微超前时允许保留小幅领先，避免每帧都进入等待分支造成“画面一顿一顿像在等声音”。
          // videoSyncGraceFrames > 0 时（seek/切音轨刚完成）立即退出等待，防止画面冻结。
          while (diff > 0.08 &&
                 ctx->renderRunning.load(std::memory_order_relaxed) &&
                 !ctx->videoFrameQueue.abort &&
                 !ctx->playbackPaused.load(std::memory_order_relaxed) &&
                 ctx->videoSyncGraceFrames.load(std::memory_order_relaxed) == 0) {
            const double sleepMsDouble = std::max(3.0, std::min((diff - 0.05) * 1000.0, 12.0));
            const int sleepMs = static_cast<int>(sleepMsDouble);
            std::this_thread::sleep_for(std::chrono::milliseconds(sleepMs));
            audioClock = AudioClock(ctx);
            diff = videoPts - audioClock;
          }
        } else if (diff < -2.0) {
          ctx->droppedLateFrames++;
          if (ctx->droppedLateFrames == 1 || (ctx->droppedLateFrames % 30) == 0) {
            OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                         "RenderThread: drop late frame diffMs=%{public}d videoPtsMs=%{public}d audioClockMs=%{public}d count=%{public}d",
                         static_cast<int>(diff * 1000.0),
                         static_cast<int>(videoPts * 1000.0),
                         static_cast<int>(audioClock * 1000.0),
                         ctx->droppedLateFrames);
          }
          av_frame_free(&frame);
          continue;
        } else {
          ctx->droppedLateFrames = 0;
        }
      } else if (ctx->videoSyncGraceFrames.load(std::memory_order_relaxed) > 0) {
        ctx->videoSyncGraceFrames.fetch_sub(1, std::memory_order_relaxed);
      }

      // B5：每 200ms 上报一次播放位置给 ArkTS（以音频时钟为准）
      const auto now = std::chrono::steady_clock::now();
      if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastEmitTime).count() >= 200) {
        lastEmitTime = now;
        const int64_t posMs = static_cast<int64_t>(AudioClock(ctx) * 1000.0);
        {
          std::lock_guard<std::mutex> lk(state->stateMutex);
          state->currentTimeMs = posMs;
        }
        if (state->tsfOnTimeUpdate != nullptr) {
          napi_call_threadsafe_function(state->tsfOnTimeUpdate, nullptr, napi_tsfn_nonblocking);
        }
      }
    }

    // 记录最后渲染帧的视频 PTS，供切音轨时用于对齐 baseMs（避免依赖尚未稳定的 AudioClock）
    {
      const double videoPtsForSwitch = VideoFramePtsSeconds(ctx, frame);
      if (videoPtsForSwitch >= 0.0) {
        ctx->lastRenderedVideoPtsMs.store(static_cast<int64_t>(videoPtsForSwitch * 1000.0),
                                         std::memory_order_relaxed);
      }
    }

    // 5. 上传 RGBA 帧到单张 GL 纹理
    const int w = frame->width;
    const int h = frame->height;

    // B6 诊断日志：第一帧打印格式与 linesize
    {
      if (!ctx->firstFrameLogged) {
        ctx->firstFrameLogged = true;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "RenderThread: first frame w=%{public}d h=%{public}d fmt=%{public}d ls0=%{public}d",
                     frame->width, frame->height, frame->format, frame->linesize[0]);
      }
    }

    int drainedErrors = 0;
    for (;;) {
      const GLenum staleErr = ctx->gl.GetError();
      if (staleErr == GL_NO_ERROR) {
        break;
      }
      drainedErrors++;
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                   "RenderThread: drained stale gl error=0x%{public}x", staleErr);
    }

    ctx->gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);

    // Fix #48-B6-2: 首帧/尺寸变化先用 glTexImage2D(nullptr) 分配，再用 glTexSubImage2D 上传。
    const bool sizeChanged = (w != ctx->textureW || h != ctx->textureH);

    ctx->gl.ActiveTexture(GL_TEXTURE0);
    ctx->gl.BindTexture(GL_TEXTURE_2D, ctx->rgbaTexture);
    bool uploadOk = true;
    if (!ctx->texturesInitialized || sizeChanged) {
      ctx->gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
      const GLenum allocErr = ctx->gl.GetError();
      OH_LOG_Print(LOG_APP, allocErr == GL_NO_ERROR ? LOG_INFO : LOG_ERROR,
                   0xFF00, "VidAll",
                   "RenderThread: glTexImage2D alloc err=0x%{public}x w=%{public}d h=%{public}d drained=%{public}d",
                   allocErr, w, h, drainedErrors);
      if (allocErr != GL_NO_ERROR) {
        uploadOk = false;
      }
    }

    if (uploadOk) {
      ctx->gl.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h,
                            GL_RGBA, GL_UNSIGNED_BYTE, frame->data[0]);
      const GLenum uploadErr = ctx->gl.GetError();
      if (!ctx->texturesInitialized || sizeChanged || uploadErr != GL_NO_ERROR) {
        OH_LOG_Print(LOG_APP, uploadErr == GL_NO_ERROR ? LOG_INFO : LOG_ERROR,
                     0xFF00, "VidAll",
                     "RenderThread: glTexSubImage2D upload err=0x%{public}x w=%{public}d h=%{public}d ls0=%{public}d",
                     uploadErr, w, h, frame->linesize[0]);
      }
      if (uploadErr != GL_NO_ERROR) {
        uploadOk = false;
      }
    }

    if (!uploadOk) {
      av_frame_free(&frame);
      continue;
    }

    if (!ctx->texturesInitialized || sizeChanged) {
      ctx->texturesInitialized = true;
      ctx->textureW = w;
      ctx->textureH = h;
    }

    // 6. 用 RGBA passthrough program 绘制全屏 quad（triangle strip，4 顶点）
    ctx->gl.UseProgram(ctx->yuvProgram);
    ctx->gl.BindBuffer(GL_ARRAY_BUFFER, ctx->quadVBO);
    const GLsizei stride = static_cast<GLsizei>(4 * sizeof(float));
    ctx->gl.EnableVertexAttribArray(0);
    ctx->gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride,
                          reinterpret_cast<const void *>(0));
    ctx->gl.EnableVertexAttribArray(1);
    ctx->gl.VertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride,
                          reinterpret_cast<const void *>(2 * sizeof(float)));
    ctx->gl.DrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    {
      const GLenum drawErr = ctx->gl.GetError();
      if (!ctx->firstDrawLogged || drawErr != GL_NO_ERROR) {
        ctx->firstDrawLogged = true;
        OH_LOG_Print(LOG_APP, drawErr == GL_NO_ERROR ? LOG_INFO : LOG_ERROR,
                     0xFF00, "VidAll",
                     "RenderThread: glDrawArrays err=0x%{public}x", drawErr);
      }
    }
    ctx->gl.DisableVertexAttribArray(0);
    ctx->gl.DisableVertexAttribArray(1);
    ctx->gl.BindBuffer(GL_ARRAY_BUFFER, 0);

    // 7. 提交帧到屏幕
    {
      const EGLBoolean swapOk = eglSwapBuffers(ctx->eglDisplay, ctx->eglSurface);
      const EGLint swapErr = eglGetError();
      if (!ctx->firstSwapLogged || swapOk != EGL_TRUE) {
        ctx->firstSwapLogged = true;
        OH_LOG_Print(LOG_APP, swapOk == EGL_TRUE ? LOG_INFO : LOG_ERROR,
                     0xFF00, "VidAll",
                     "RenderThread: eglSwapBuffers ok=%{public}d err=0x%{public}x",
                     swapOk == EGL_TRUE ? 1 : 0, swapErr);
      }
    }

    // 8. 释放当前帧
    av_frame_free(&frame);
  }

  // 清理 GL 资源（makeCurrent 仍有效）
  FfmpegCleanupGLResources(ctx);

  // 清理 EGL
  eglMakeCurrent(ctx->eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
                 EGL_NO_CONTEXT);
  eglDestroySurface(ctx->eglDisplay, ctx->eglSurface);
  ctx->eglSurface = EGL_NO_SURFACE;
  eglDestroyContext(ctx->eglDisplay, ctx->eglContext);
  ctx->eglContext = EGL_NO_CONTEXT;
  eglTerminate(ctx->eglDisplay);
  ctx->eglDisplay = EGL_NO_DISPLAY;

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "RenderThreadFunc: render thread exited");
}

// ---------------------------------------------------------------------------
// B3：启动 / 停止渲染线程
// ---------------------------------------------------------------------------

static void StartFfmpegRender(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();
  if (ctx->videoCodecCtx == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegRender: no video stream, skip");
    return;
  }
  if (state->nativeWindow == nullptr) {
    // Surface 尚未就绪，延迟到 OnXCSurfaceCreated 触发后再启动
    state->pendingFfmpegRender = true;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegRender: nativeWindow not ready, pendingFfmpegRender=true");
    return;
  }
  state->pendingFfmpegRender = false;
  ctx->renderRunning.store(true);
  ctx->renderThread = std::thread(RenderThreadFunc, state);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StartFfmpegRender: render thread started");
}

static void StopFfmpegRender(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();
  state->pendingFfmpegRender = false;
  if (!ctx->renderRunning.load()) {
    return;
  }
  ctx->renderRunning.store(false);
  // 唤醒可能阻塞在 videoFrameQueue.cv.wait_for 的渲染线程
  {
    std::lock_guard<std::mutex> lk(ctx->videoFrameQueue.mtx);
    ctx->videoFrameQueue.abort = true;
  }
  ctx->videoFrameQueue.cv.notify_all();
  if (ctx->renderThread.joinable()) {
    ctx->renderThread.join();
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegRender: render thread stopped");
}

// ---------------------------------------------------------------------------
// B4：SwrContext 初始化（源格式 → stereo S16LE 48kHz）
// ---------------------------------------------------------------------------

static bool FfmpegInitSwr(FfmpegContext *ctx) {
  AVCodecContext *aCtx = ctx->audioCodecCtx;
  if (aCtx == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);

  // 目标格式：stereo S16LE 48000Hz（匹配 OH_AudioRenderer 配置）
  AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;
  const int ret = swr_alloc_set_opts2(
      &ctx->swrCtx,
      &outLayout,          AV_SAMPLE_FMT_S16, 48000,
      &aCtx->ch_layout,    aCtx->sample_fmt,  aCtx->sample_rate,
      0, nullptr);
  if (ret < 0 || ctx->swrCtx == nullptr) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitSwr: swr_alloc_set_opts2 failed: %s", errbuf);
    return false;
  }

  const int initRet = swr_init(ctx->swrCtx);
  if (initRet < 0) {
    char errbuf[128] = {0};
    av_strerror(initRet, errbuf, sizeof(errbuf));
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitSwr: swr_init failed: %s", errbuf);
    swr_free(&ctx->swrCtx);
    return false;
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitSwr: OK src(fmt=%d rate=%d ch=%d) → stereo S16 48kHz",
               static_cast<int>(aCtx->sample_fmt), aCtx->sample_rate,
               aCtx->ch_layout.nb_channels);
  // B5：记录 swr 输出采样率，供音频时钟计算（48kHz 固定）
  ctx->audioSampleRate = 48000;
  return true;
}

// ---------------------------------------------------------------------------
// B4：OH_AudioRenderer 写数据回调（由音频系统线程驱动，非阻塞消费 audioFrameQueue）
// ---------------------------------------------------------------------------

static OH_AudioData_Callback_Result AudioWriteDataCallback(
    OH_AudioRenderer * /*renderer*/, void *userData,
    void *audioData, int32_t audioDataSize) {
  auto *ctx = static_cast<FfmpegContext *>(userData);
  if (ctx == nullptr || audioData == nullptr || audioDataSize <= 0) {
    if (audioData != nullptr && audioDataSize > 0) {
      memset(audioData, 0, static_cast<size_t>(audioDataSize));
    }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
  }
  ctx->audioCallbackActiveCount.fetch_add(1, std::memory_order_acq_rel);
  struct AudioCallbackScopeGuard {
    FfmpegContext *ctx;
    ~AudioCallbackScopeGuard() {
      if (ctx == nullptr) {
        return;
      }
      const int32_t remaining =
          ctx->audioCallbackActiveCount.fetch_sub(1, std::memory_order_acq_rel) - 1;
      if (remaining <= 0) {
        std::lock_guard<std::mutex> lk(ctx->audioCallbackStateMutex);
        ctx->audioCallbackStateCv.notify_all();
      }
    }
  } callbackScopeGuard { ctx };
  int mediaSamplesFilled = 0;
  {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    if (ctx->audioRendererSwitching.load(std::memory_order_acquire) || ctx->swrCtx == nullptr) {
      memset(audioData, 0, static_cast<size_t>(audioDataSize));
      return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    if (ctx->playbackPaused.load(std::memory_order_relaxed)) {
      memset(audioData, 0, static_cast<size_t>(audioDataSize));
      return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    auto *dst = static_cast<int16_t *>(audioData);
    const int samplesNeeded = audioDataSize / static_cast<int>(2 * sizeof(int16_t));
    int samplesFilled = 0;

    if (!ctx->pcmLeftover.empty()) {
      const int leftoverSamples = static_cast<int>(ctx->pcmLeftover.size()) / 2;
      const int toCopy = std::min(leftoverSamples, samplesNeeded);
      memcpy(dst, ctx->pcmLeftover.data(),
             static_cast<size_t>(toCopy) * 2 * sizeof(int16_t));
      samplesFilled += toCopy;
      mediaSamplesFilled += toCopy;
      if (toCopy < leftoverSamples) {
        ctx->pcmLeftover.erase(ctx->pcmLeftover.begin(),
                               ctx->pcmLeftover.begin() + toCopy * 2);
      } else {
        ctx->pcmLeftover.clear();
      }
    }

    while (samplesFilled < samplesNeeded) {
      AVFrame *frame = nullptr;
      {
        std::unique_lock<std::mutex> lock(ctx->audioFrameQueue.mtx);
        if (!ctx->audioFrameQueue.frames.empty()) {
          frame = ctx->audioFrameQueue.frames.front();
          ctx->audioFrameQueue.frames.pop();
        }
      }
      if (frame != nullptr) {
        ctx->audioFrameQueue.cv.notify_all();
      } else {
        memset(dst + samplesFilled * 2, 0,
               static_cast<size_t>(samplesNeeded - samplesFilled) * 2 * sizeof(int16_t));
        samplesFilled = samplesNeeded;
        break;
      }

      const int maxOut = frame->nb_samples + 256;
      std::vector<int16_t> tempBuf(static_cast<size_t>(maxOut * 2));
      uint8_t *outPtr = reinterpret_cast<uint8_t *>(tempBuf.data());
      const uint8_t *inData[AV_NUM_DATA_POINTERS] = {};
      for (int i = 0; i < AV_NUM_DATA_POINTERS; i++) {
        inData[i] = frame->data[i];
      }
      const int converted = swr_convert(ctx->swrCtx,
          &outPtr, maxOut,
          inData, frame->nb_samples);
      av_frame_free(&frame);

      if (converted <= 0) {
        continue;
      }

      const int canFill = samplesNeeded - samplesFilled;
      const int toCopy = std::min(converted, canFill);
      memcpy(dst + samplesFilled * 2, tempBuf.data(),
             static_cast<size_t>(toCopy) * 2 * sizeof(int16_t));
      samplesFilled += toCopy;
      mediaSamplesFilled += toCopy;

      if (converted > toCopy) {
        ctx->pcmLeftover.insert(ctx->pcmLeftover.end(),
                                tempBuf.begin() + toCopy * 2,
                                tempBuf.begin() + converted * 2);
      }
    }
  }

  // B5：音频时钟只累计真实媒体样本，不把 underrun 填充的静音计入主时钟。
  // 否则启动/seek 后音频时钟会虚假快进，RenderThread 会把视频帧误判为“严重落后”并大量丢帧。
  if (mediaSamplesFilled > 0) {
    // HW video path: startRealtimeMs is gated by HwVideoRenderThread (set when first frame near
    // seek target is rendered). Blocking it here prevents premature clock advance during
    // keyframe pre-roll, which caused permanent seek freeze (all frames dropped as "too late").
    if (ctx->audioClockStartRealtimeMs.load(std::memory_order_relaxed) <= 0 &&
        !ctx->useHwVideoDecoder) {
      ctx->audioClockStartRealtimeMs.store(NowRealtimeMs(), std::memory_order_relaxed);
    }
    ctx->audioPtsSamples.fetch_add(static_cast<int64_t>(mediaSamplesFilled), std::memory_order_relaxed);
  }

  return AUDIO_DATA_CALLBACK_RESULT_VALID;
}
// ---------------------------------------------------------------------------

static bool FfmpegInitAudioRenderer(FfmpegContext *ctx) {
  OH_AudioStream_Result result =
      OH_AudioStreamBuilder_Create(&ctx->audioBuilder, AUDIOSTREAM_TYPE_RENDERER);
  if (result != AUDIOSTREAM_SUCCESS || ctx->audioBuilder == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: Create builder failed: %d", result);
    return false;
  }

  OH_AudioStreamBuilder_SetSamplingRate(ctx->audioBuilder, 48000);
  OH_AudioStreamBuilder_SetChannelCount(ctx->audioBuilder, 2);
  OH_AudioStreamBuilder_SetSampleFormat(ctx->audioBuilder, AUDIOSTREAM_SAMPLE_S16LE);
  OH_AudioStreamBuilder_SetEncodingType(ctx->audioBuilder, AUDIOSTREAM_ENCODING_TYPE_RAW);
  // AUDIOSTREAM_USAGE_MOVIE：视频媒体播放场景，会触发正确的音频焦点策略
  OH_AudioStreamBuilder_SetRendererInfo(ctx->audioBuilder, AUDIOSTREAM_USAGE_MOVIE);
  result = OH_AudioStreamBuilder_SetLatencyMode(ctx->audioBuilder, AUDIOSTREAM_LATENCY_MODE_FAST);
  if (result != AUDIOSTREAM_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: SetLatencyMode FAST failed: %d", result);
  } else {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: SetLatencyMode FAST ok");
  }
  result = OH_AudioStreamBuilder_SetFrameSizeInCallback(ctx->audioBuilder, 480);
  if (result != AUDIOSTREAM_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: SetFrameSizeInCallback(480) failed: %d", result);
  } else {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: SetFrameSizeInCallback(480) ok");
  }

  // 注册写数据回调：音频系统在需要 PCM 数据时调用 AudioWriteDataCallback
  result = OH_AudioStreamBuilder_SetRendererWriteDataCallback(
      ctx->audioBuilder, AudioWriteDataCallback, ctx);
  if (result != AUDIOSTREAM_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: SetRendererWriteDataCallback failed: %d", result);
    OH_AudioStreamBuilder_Destroy(ctx->audioBuilder);
    ctx->audioBuilder = nullptr;
    return false;
  }

  result = OH_AudioStreamBuilder_GenerateRenderer(ctx->audioBuilder, &ctx->audioRenderer);
  if (result != AUDIOSTREAM_SUCCESS || ctx->audioRenderer == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitAudioRenderer: GenerateRenderer failed: %d", result);
    OH_AudioStreamBuilder_Destroy(ctx->audioBuilder);
    ctx->audioBuilder = nullptr;
    return false;
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitAudioRenderer: renderer created (stereo S16LE 48kHz MOVIE)");
  return true;
}

// ---------------------------------------------------------------------------
// B4：启动/停止音频渲染器
// ---------------------------------------------------------------------------

static bool StartFfmpegAudio(NativePlayerSkeletonState *state, int64_t clockBaseMs = 0, bool startRenderer = true) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return false;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();
  if (ctx->audioCodecCtx == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegAudio: no audio stream, skip");
    return false;
  }

  if (!FfmpegInitSwr(ctx)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegAudio: FfmpegInitSwr failed");
    return false;
  }

  if (!FfmpegInitAudioRenderer(ctx)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegAudio: FfmpegInitAudioRenderer failed");
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    swr_free(&ctx->swrCtx);
    return false;
  }

  ctx->playbackPaused.store(!startRenderer, std::memory_order_relaxed);
  ctx->audioClockBaseMs.store(clockBaseMs, std::memory_order_relaxed);
  ctx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
  ctx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
  // 立即启动 wall-clock fallback，防止 render 线程在锚点未建立期间死等
  ctx->audioClockStartRealtimeMs.store(NowRealtimeMs(), std::memory_order_relaxed);
  ctx->audioClockLastReportedMs.store(clockBaseMs, std::memory_order_relaxed);
  ctx->audioPtsSamples.store(0, std::memory_order_relaxed);
  ctx->videoSyncGraceFrames.store(90, std::memory_order_relaxed);
  if (startRenderer) {
    const OH_AudioStream_Result result = OH_AudioRenderer_Start(ctx->audioRenderer);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegAudio: OH_AudioRenderer_Start result=%d", result);
  } else {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegAudio: renderer prepared in paused state baseMs=%{public}lld",
                 static_cast<long long>(clockBaseMs));
  }
  ctx->audioRendererSwitching.store(false, std::memory_order_release);
  return true;
}

static void StopFfmpegAudio(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();
  ctx->audioRendererSwitching.store(true, std::memory_order_release);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegAudio: begin");

  // 1. 停止并释放 renderer（调用后音频系统不再调用 callback，消费者安全关闭）
  OH_AudioRenderer *rendererToRelease = nullptr;
  {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    rendererToRelease = ctx->audioRenderer;
    ctx->audioRenderer = nullptr;
  }
  if (rendererToRelease != nullptr) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StopFfmpegAudio: stopping renderer");
    OH_AudioRenderer_Stop(rendererToRelease);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StopFfmpegAudio: releasing renderer");
    OH_AudioRenderer_Release(rendererToRelease);
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegAudio: waiting callbacks");
  {
    std::unique_lock<std::mutex> lk(ctx->audioCallbackStateMutex);
    ctx->audioCallbackStateCv.wait(lk, [ctx] {
      return ctx->audioCallbackActiveCount.load(std::memory_order_acquire) == 0;
    });
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegAudio: callbacks drained");

  // 2. 销毁 builder
  if (ctx->audioBuilder != nullptr) {
    OH_AudioStreamBuilder_Destroy(ctx->audioBuilder);
    ctx->audioBuilder = nullptr;
  }

  // 3. 释放 SwrContext
  if (ctx->swrCtx != nullptr) {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    swr_free(&ctx->swrCtx);
  }

  // 4. 清空溢出缓冲
  {
    std::lock_guard<std::mutex> audioRenderLk(ctx->audioRenderStateMutex);
    ctx->pcmLeftover.clear();
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegAudio: renderer stopped and released");
}

// B4 函数已在上方完整定义，此处无需重复前向声明

static void StartFfmpegDecode(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();

  // HW-B：若为 HARDWARE_PREFERRED 且 HEVC 片源，先尝试初始化 OH_VideoDecoder
  if (state->preferredDecodePath == NativePreferredDecodePath::HARDWARE_PREFERRED
      && state->nativeWindow != nullptr
      && ctx->videoStreamIdx >= 0 && ctx->fmtCtx != nullptr) {
    const AVCodecID codecId = ctx->fmtCtx->streams[ctx->videoStreamIdx]->codecpar->codec_id;
    if (codecId == AV_CODEC_ID_HEVC || codecId == AV_CODEC_ID_H264) {
      const char *mime = (codecId == AV_CODEC_ID_HEVC) ? "video/hevc" : "video/avc";
      ctx->useHwVideoDecoder = InitHwVideoDecoder(ctx, mime, state->nativeWindow);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "StartFfmpegDecode: HW video decoder init %{public}s mime=%{public}s",
                   ctx->useHwVideoDecoder ? "OK" : "FAILED", mime);

      // 初始化 Annex-B BSF（MKV 存储 HEVC/H264 为 MPEG-4 格式，HW 解码器需要 Annex-B）
      if (ctx->useHwVideoDecoder) {
        const char *bsfName = (codecId == AV_CODEC_ID_HEVC) ? "hevc_mp4toannexb" : "h264_mp4toannexb";
        const AVBitStreamFilter *bsf = av_bsf_get_by_name(bsfName);
        if (bsf != nullptr) {
          int bsfRet = av_bsf_alloc(bsf, &ctx->hwBsfCtx);
          if (bsfRet == 0) {
            AVCodecParameters *par = ctx->fmtCtx->streams[ctx->videoStreamIdx]->codecpar;
            avcodec_parameters_copy(ctx->hwBsfCtx->par_in, par);
            ctx->hwBsfCtx->time_base_in = ctx->fmtCtx->streams[ctx->videoStreamIdx]->time_base;
            bsfRet = av_bsf_init(ctx->hwBsfCtx);
          }
          if (bsfRet == 0) {
            OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                         "StartFfmpegDecode: BSF %{public}s initialized OK", bsfName);
          } else {
            OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                         "StartFfmpegDecode: BSF %{public}s init failed ret=%{public}d", bsfName, bsfRet);
            if (ctx->hwBsfCtx) { av_bsf_free(&ctx->hwBsfCtx); ctx->hwBsfCtx = nullptr; }
          }
        } else {
          OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                       "StartFfmpegDecode: BSF %{public}s not found", bsfName);
        }
      }
    }
  }

  // 初始化解码器（HW path 下跳过视频软解器）
  const int ret = FfmpegInitCodecs(ctx);
  if (ret < 0) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegDecode: FfmpegInitCodecs failed: %s", errbuf);
    return;
  }

  // 记录媒体信息（供 ArkTS onPrepared 读取）
  if (ctx->videoStreamIdx >= 0 && ctx->fmtCtx != nullptr) {
    if (ctx->videoCodecCtx != nullptr) {
      state->ffmpegWidth = ctx->videoCodecCtx->width;
      state->ffmpegHeight = ctx->videoCodecCtx->height;
    } else if (ctx->useHwVideoDecoder) {
      // HW path：从 codecpar 获取分辨率
      AVCodecParameters *par = ctx->fmtCtx->streams[ctx->videoStreamIdx]->codecpar;
      state->ffmpegWidth = par->width;
      state->ffmpegHeight = par->height;
    }
    AVStream *vs = ctx->fmtCtx->streams[ctx->videoStreamIdx];
    const AVRational fr = vs->avg_frame_rate;
    state->ffmpegFps = (fr.den > 0) ? static_cast<double>(fr.num) / fr.den : 0.0;
  }
  if (ctx->fmtCtx->duration != AV_NOPTS_VALUE) {
    state->ffmpegDurationMs = ctx->fmtCtx->duration / (AV_TIME_BASE / 1000);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StartFfmpegDecode: %dx%d fps=%.2f durationMs=%lld",
               state->ffmpegWidth, state->ffmpegHeight,
               state->ffmpegFps, static_cast<long long>(state->ffmpegDurationMs));

  // B5：设置 durationMs 并标记 prepared，确保 ArkTS getDuration() 返回正确值
  {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    state->durationMs = state->ffmpegDurationMs;
    state->prepared = true;
  }

  // 启动解码线程
  ctx->decodeRunning.store(true);
  if (ctx->useHwVideoDecoder) {
    // HW path：视频由 OH_VideoDecoder 处理，启动 Feed + Render 线程。
    // 注意：不预设 audioClockStartRealtimeMs。HW RenderThread 的时钟门控会在第一帧到达 seekFloor
    // 附近时开门并设置锚点，确保时钟从首帧开始精准同步，避免预设导致初始帧 clockMs 虚高、
    // 所有初始帧 diff<0 无等待、以解码速度连续输出造成画面撕裂和声音滞后。
    ctx->hwVideoRunning.store(true);
    ctx->hwVideoFeedThread   = std::thread(HwVideoFeedThreadFunc, ctx);
    ctx->hwVideoRenderThread = std::thread(HwVideoRenderThreadFunc, ctx);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegDecode: HW video threads launched");
  } else if (ctx->videoCodecCtx != nullptr) {
    ctx->videoDecodeThread = std::thread(VideoDecodeThreadFunc, ctx);
  }
  if (ctx->audioCodecCtx != nullptr) {
    ctx->audioDecodeThread = std::thread(AudioDecodeThreadFunc, ctx);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "StartFfmpegDecode: decode threads launched");

  // B4：解码器就绪后启动 OH_AudioRenderer（消费 audioFrameQueue）
  (void)StartFfmpegAudio(state);

  // B3：启动 OpenGL ES YUV 渲染线程（SW path 时消费 videoFrameQueue；HW path 时跳过）
  if (!ctx->useHwVideoDecoder) {
    StartFfmpegRender(state);
  }

  // B5：触发 onPrepared 回调（通知 ArkTS 播放器已就绪，duration 已设置）
  if (state->tsfOnPrepared != nullptr) {
    napi_call_threadsafe_function(state->tsfOnPrepared, nullptr, napi_tsfn_nonblocking);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegDecode: tsfOnPrepared triggered, durationMs=%lld",
                 static_cast<long long>(state->durationMs));
  }
}

static void StopFfmpegDecode(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();

  // 1. 通知解码线程退出
  ctx->decodeRunning.store(false);

  // 2. Abort 帧队列（唤醒可能阻塞在背压等待的解码线程）
  {
    std::lock_guard<std::mutex> lk(ctx->videoFrameQueue.mtx);
    ctx->videoFrameQueue.abort = true;
  }
  ctx->videoFrameQueue.cv.notify_all();
  {
    std::lock_guard<std::mutex> lk(ctx->audioFrameQueue.mtx);
    ctx->audioFrameQueue.abort = true;
  }
  ctx->audioFrameQueue.cv.notify_all();

  // 3. Abort packet 队列（唤醒可能阻塞在取 packet 的解码线程）
  {
    std::lock_guard<std::mutex> lk(ctx->videoQueue.mtx);
    ctx->videoQueue.abort = true;
  }
  ctx->videoQueue.cv.notify_all();
  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    ctx->audioQueue.abort = true;
  }
  ctx->audioQueue.cv.notify_all();

  // 4. Join 解码线程（HW path 下不启动 videoDecodeThread，也无需 join）
  if (ctx->videoDecodeThread.joinable()) {
    ctx->videoDecodeThread.join();
  }
  if (ctx->audioDecodeThread.joinable()) {
    ctx->audioDecodeThread.join();
  }

  // 4b. HW path：停止并销毁 OH_VideoDecoder 及其工作线程
  if (ctx->useHwVideoDecoder) {
    DestroyHwVideoDecoder(ctx);
    ctx->useHwVideoDecoder = false;
  }

  // 5. 释放帧队列中残留帧
  {
    std::lock_guard<std::mutex> lk(ctx->videoFrameQueue.mtx);
    while (!ctx->videoFrameQueue.frames.empty()) {
      AVFrame *f = ctx->videoFrameQueue.frames.front();
      ctx->videoFrameQueue.frames.pop();
      av_frame_free(&f);
    }
  }
  {
    std::lock_guard<std::mutex> lk(ctx->audioFrameQueue.mtx);
    while (!ctx->audioFrameQueue.frames.empty()) {
      AVFrame *f = ctx->audioFrameQueue.frames.front();
      ctx->audioFrameQueue.frames.pop();
      av_frame_free(&f);
    }
  }

  // 6. 释放解码器上下文（持 codecMutex 防止与任何残留的 flush/send/receive 操作并发，
  //    虽然正常路径下 DemuxThread 和 DecodeThread 已 join，此处作为 defense-in-depth）
  {
    std::lock_guard<std::mutex> codecLk(ctx->codecMutex);
    if (ctx->videoCodecCtx != nullptr) {
      avcodec_free_context(&ctx->videoCodecCtx);
    }
    if (ctx->audioCodecCtx != nullptr) {
      avcodec_free_context(&ctx->audioCodecCtx);
    }
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "StopFfmpegDecode: decode stopped and cleaned");
  // 释放 SwsContext（视频格式转换，B6 HDR/DV 修复）；decode 线程已 join，访问安全
  if (ctx->swsCtx != nullptr) {
    sws_freeContext(ctx->swsCtx);
    ctx->swsCtx = nullptr;
    ctx->lastSwsSrcFmt = -1;
    ctx->lastSwsSrcW   = -1;
  }
}

// ---------------------------------------------------------------------------
// B1：demux 线程启动/停止（B2 在其中调用解码线程）
// ---------------------------------------------------------------------------

static void StartFfmpegDemux(NativePlayerSkeletonState *state, const std::string &url) {
  if (state == nullptr || url.empty()) {
    return;
  }
  // 已经在运行则跳过
  if (state->ffmpegCtx != nullptr && state->ffmpegCtx->demuxRunning.load()) {
    return;
  }

  auto ctx = std::make_unique<FfmpegContext>();
  const int64_t inheritedAudioHardwareOffsetMs =
      state->audioHardwareSafetyOffsetMs.load(std::memory_order_relaxed);
  ctx->audioHardwareSafetyOffsetMs.store(inheritedAudioHardwareOffsetMs, std::memory_order_relaxed);
  ctx->httpHeaders = BuildFfmpegHeadersFromJson(state->headersJson);

  const int ret = FfmpegOpenInput(ctx.get(), url);
  if (ret < 0) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegDemux: FfmpegOpenInput failed: %s", errbuf);
    // B6修复：FFmpeg 也失败时，这才是真正的播放失败，上报 tsfOnError 给 ArkTS
    if (state->tsfOnError != nullptr) {
      auto *errData = new ErrorData{
        ret,
        new std::string(std::string("FFmpeg open failed: ") + errbuf)
      };
      napi_call_threadsafe_function(state->tsfOnError, errData, napi_tsfn_nonblocking);
    }
    if (state->tsfOnBufferingFalse != nullptr) {
      napi_call_threadsafe_function(state->tsfOnBufferingFalse, nullptr, napi_tsfn_nonblocking);
    }
    return;
  }

  // B5：设置反向指针，供 DemuxThreadFunc 发出 seekDone TSF
  ctx->ownerState = state;

  ctx->demuxRunning.store(true);
  ctx->demuxThread = std::thread(DemuxThreadFunc, ctx.get());
  state->ffmpegCtx = std::move(ctx);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StartFfmpegDemux: demux thread launched for url=%s audioOffsetMs=%{public}lld",
               url.c_str(), static_cast<long long>(inheritedAudioHardwareOffsetMs));

  // B2：demux 就绪后立即初始化解码器并启动解码线程
  StartFfmpegDecode(state);
}

// 停止 demux 线程并释放所有 FFmpeg 资源
static void StopFfmpegDemux(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();

  // B3：先停止渲染线程（消费 videoFrameQueue），避免访问已释放帧数据
  StopFfmpegRender(state);

  // B4：先停止音频渲染器（消费者），再停止解码线程（生产者），避免 callback 访问已释放队列
  StopFfmpegAudio(state);

  // 1. 通知 DemuxThread 中断退出（必须在 StopFfmpegDecode 之前完成，否则：
  //    DemuxThread 在 seek 时持有 codecMutex 调用 avcodec_flush_buffers，
  //    StopFfmpegDecode 释放 videoCodecCtx 后 DemuxThread 继续访问已释放内存 → SIGSEGV）
  ctx->interruptFlag.store(true);
  ctx->demuxRunning.store(false);
  ctx->ownerState.store(nullptr, std::memory_order_release);

  // 2. 唤醒可能阻塞在 cv.wait 的 demux 线程（队列满等待、seek cv 等待）
  {
    std::lock_guard<std::mutex> lk(ctx->videoQueue.mtx);
    ctx->videoQueue.abort = true;
  }
  ctx->videoQueue.cv.notify_all();
  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    ctx->audioQueue.abort = true;
  }
  ctx->audioQueue.cv.notify_all();

  // 3. 必须先 join DemuxThread，确保 avcodec_flush_buffers 已退出，
  //    才能安全调用 StopFfmpegDecode 释放 videoCodecCtx / audioCodecCtx。
  if (ctx->demuxThread.joinable()) {
    ctx->demuxThread.join();
  }

  // B2：在 DemuxThread 已退出后再停止解码线程，此时 videoCodecCtx 无其他访问者
  StopFfmpegDecode(state);

  // 4. 释放队列中残留 packet
  {
    std::lock_guard<std::mutex> lk(ctx->videoQueue.mtx);
    while (!ctx->videoQueue.packets.empty()) {
      AVPacket *p = ctx->videoQueue.packets.front();
      ctx->videoQueue.packets.pop();
      av_packet_free(&p);
    }
  }
  {
    std::lock_guard<std::mutex> lk(ctx->audioQueue.mtx);
    while (!ctx->audioQueue.packets.empty()) {
      AVPacket *p = ctx->audioQueue.packets.front();
      ctx->audioQueue.packets.pop();
      av_packet_free(&p);
    }
  }

  // 5. 关闭格式上下文
  if (ctx->fmtCtx != nullptr) {
    avformat_close_input(&ctx->fmtCtx);
  }

  state->ffmpegCtx.reset();
  state->useFfmpegPath = false;
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "StopFfmpegDemux: demux stopped and cleaned");
}


// 使用新式带 userData 的回调 API：OH_AVPlayer_SetOnInfoCallback / SetOnErrorCallback
// 注意：不在此处持有 g_playersMutex，避免与 Release() → OH_AVPlayer_Release 产生死锁；
//      生命周期安全由 Release() 中"先 OH_AVPlayer_Release 再 ReleaseTsfIfPresent"序列保证。
// ---------------------------------------------------------------------------

static void OnAVPlayerInfoCB(OH_AVPlayer *player, AVPlayerOnInfoType type,
                              OH_AVFormat *infoBody, void *userData) {
  (void)player; // 通过 state->avPlayer 访问，此处不直接使用
  NativePlayerSkeletonState *state = static_cast<NativePlayerSkeletonState *>(userData);
  if (state == nullptr || infoBody == nullptr) {
    return;
  }
  switch (type) {
    case AV_INFO_TYPE_STATE_CHANGE: {
      int32_t avStateVal = 0;
      if (!OH_AVFormat_GetIntValue(infoBody, OH_PLAYER_STATE, &avStateVal)) {
        break;
      }
      AVPlayerState avState = static_cast<AVPlayerState>(avStateVal);
      if (avState == AV_PREPARED) {
        // 获取时长（GetDuration 返回 int32_t 毫秒）
        int32_t durationMs = 0;
        OH_AVPlayer_GetDuration(state->avPlayer, &durationMs);
        {
          // PR#49（问题6）：锁保护 state 字段写；TSF 调用在锁外，避免死锁
          std::lock_guard<std::mutex> lock(state->stateMutex);
          state->durationMs = static_cast<int64_t>(durationMs);
          state->prepared = true;
        }
        if (state->tsfOnPrepared != nullptr) {
          napi_call_threadsafe_function(state->tsfOnPrepared, nullptr, napi_tsfn_nonblocking);
        }
        // PR#49（问题4）：buffering=false 随 tsfOnPrepared 的 call_js_cb 一并发出（见 SetCallbacks）
      } else if (avState == AV_COMPLETED) {
        {
          std::lock_guard<std::mutex> lock(state->stateMutex);
          state->playing = false;
        }
        if (state->tsfOnCompleted != nullptr) {
          napi_call_threadsafe_function(state->tsfOnCompleted, nullptr, napi_tsfn_nonblocking);
        }
        // PR#49（问题4）：buffering=false 随 tsfOnCompleted 的 call_js_cb 一并发出（见 SetCallbacks）
      } else if (avState == AV_PLAYING) {
        {
          std::lock_guard<std::mutex> lock(state->stateMutex);
          state->playing = true;
        }
        // PR#49（问题4）：播放开始时发出 buffering=false
        if (state->tsfOnBufferingFalse != nullptr) {
          napi_call_threadsafe_function(state->tsfOnBufferingFalse, nullptr, napi_tsfn_nonblocking);
        }
      } else if (avState == AV_PAUSED) {
        {
          std::lock_guard<std::mutex> lock(state->stateMutex);
          state->playing = false;
        }
        // PR#49（问题4）：暂停时 buffering 应结束
        if (state->tsfOnBufferingFalse != nullptr) {
          napi_call_threadsafe_function(state->tsfOnBufferingFalse, nullptr, napi_tsfn_nonblocking);
        }
      }
      break;
    }
    case AV_INFO_TYPE_POSITION_UPDATE: {
      int32_t posMs = 0;
      if (OH_AVFormat_GetIntValue(infoBody, OH_PLAYER_CURRENT_POSITION, &posMs)) {
        std::lock_guard<std::mutex> lock(state->stateMutex); // PR#49（问题6）
        state->currentTimeMs = static_cast<int64_t>(posMs);
      }
      if (state->tsfOnTimeUpdate != nullptr) {
        napi_call_threadsafe_function(state->tsfOnTimeUpdate, nullptr, napi_tsfn_nonblocking);
      }
      break;
    }
    case AV_INFO_TYPE_SEEKDONE: {
      // PR#49（问题7）：OH_AVPlayer_Seek 是异步的，seekDone 应在此回调触发，而非 Seek() 返回时
      if (state->tsfOnTimeUpdate != nullptr) {
        napi_call_threadsafe_function(state->tsfOnTimeUpdate, nullptr, napi_tsfn_nonblocking);
      }
      if (state->tsfOnSeekDone != nullptr) {
        napi_call_threadsafe_function(state->tsfOnSeekDone, nullptr, napi_tsfn_nonblocking);
      }
      break;
    }
    case AV_INFO_TYPE_SUBTITLE_UPDATE: {
      if (state->tsfOnSubtitleUpdate == nullptr) {
        break;
      }
      auto *subtitleData = new SubtitleData();
      const char *text = nullptr;
      int64_t startTimeMs = 0;
      int64_t durationMs = 0;
      int32_t startTimeInt = 0;
      int32_t durationInt = 0;
      if ((OH_AVFormat_GetStringValue(infoBody, "subtitle_text", &text) ||
           OH_AVFormat_GetStringValue(infoBody, "text", &text)) && text != nullptr) {
        subtitleData->text = new std::string(text);
      }
      if (OH_AVFormat_GetLongValue(infoBody, "subtitle_pts", &startTimeMs) ||
          OH_AVFormat_GetLongValue(infoBody, "startTime", &startTimeMs)) {
        subtitleData->startTimeMs = startTimeMs;
      } else if (OH_AVFormat_GetIntValue(infoBody, "subtitle_pts", &startTimeInt) ||
                 OH_AVFormat_GetIntValue(infoBody, "startTime", &startTimeInt)) {
        subtitleData->startTimeMs = static_cast<int64_t>(startTimeInt);
      }
      if (OH_AVFormat_GetLongValue(infoBody, "subtitle_duration", &durationMs) ||
          OH_AVFormat_GetLongValue(infoBody, "duration", &durationMs)) {
        subtitleData->durationMs = durationMs;
      } else if (OH_AVFormat_GetIntValue(infoBody, "subtitle_duration", &durationInt) ||
                 OH_AVFormat_GetIntValue(infoBody, "duration", &durationInt)) {
        subtitleData->durationMs = static_cast<int64_t>(durationInt);
      }
      if (kEnableNativeSubtitleDiagLog) {
        const char *dumpInfo = OH_AVFormat_DumpInfo(infoBody);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "SubtitleUpdate: text=%{public}s start=%{public}lld duration=%{public}lld dump=%{public}s",
                     subtitleData->text != nullptr ? subtitleData->text->c_str() : "(null)",
                     static_cast<long long>(subtitleData->startTimeMs),
                     static_cast<long long>(subtitleData->durationMs),
                     dumpInfo != nullptr ? dumpInfo : "(null)");
      }
      napi_call_threadsafe_function(state->tsfOnSubtitleUpdate, subtitleData, napi_tsfn_nonblocking);
      break;
    }
    default:
      break;
  }
}

static void OnAVPlayerErrorCB(OH_AVPlayer *player, int32_t errorCode,
                               const char *errorMsg, void *userData) {
  (void)player;
  NativePlayerSkeletonState *state = static_cast<NativePlayerSkeletonState *>(userData);
  if (state == nullptr) {
    return;
  }

  OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
               "OnAVPlayerErrorCB: errorCode=%d msg=%s useFfmpegPath=%d",
               errorCode, errorMsg ? errorMsg : "(null)", state->useFfmpegPath ? 1 : 0);

  // B1：OH_AVPlayer 报错时（IO 失败 / 编解码不支持）切换到 FFmpeg 自研路径。
  // AV_ERR_UNSUPPORT (= 4) 表示格式/编解码器不支持；通用错误也尝试 FFmpeg 路径。
  // 条件：尚未启动 FFmpeg 路径 && URL 不为空
  if (!state->useFfmpegPath && !state->url.empty()) {
    const std::string urlCopy = state->url;
    {
      std::lock_guard<std::mutex> lk(state->stateMutex);
      if (state->useFfmpegPath || state->ffmpegFallbackInProgress) {
        return;
      }
      state->useFfmpegPath = true;
      state->cancelPendingFfmpegFallback = false;
      state->ffmpegFallbackInProgress = true;
    }
    JoinFfmpegFallbackThread(*state);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "OnAVPlayerErrorCB: scheduling AVPlayer->FFmpeg handoff for url=%s", urlCopy.c_str());
    state->ffmpegFallbackThread = std::thread([state, urlCopy]() {
      OH_AVPlayer *avToRelease = nullptr;
      {
        std::lock_guard<std::mutex> lk(state->stateMutex);
        avToRelease = state->avPlayer;
        state->avPlayer = nullptr;
      }
      if (avToRelease != nullptr) {
        const OH_AVErrCode stopRc = OH_AVPlayer_Stop(avToRelease);
        const OH_AVErrCode detachRc = OH_AVPlayer_SetVideoSurface(avToRelease, nullptr);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "FFmpegFallbackThread: stopRc=%{public}d detachRc=%{public}d, releasing AVPlayer before EGL handoff",
                     static_cast<int32_t>(stopRc), static_cast<int32_t>(detachRc));
        const OH_AVErrCode releaseRc = OH_AVPlayer_Release(avToRelease);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "FFmpegFallbackThread: releaseRc=%{public}d", static_cast<int32_t>(releaseRc));
      } else {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "FFmpegFallbackThread: avPlayer already null, skip release");
      }

      bool cancelled = false;
      {
        std::lock_guard<std::mutex> lk(state->stateMutex);
        cancelled = state->cancelPendingFfmpegFallback;
        state->ffmpegFallbackInProgress = false;
      }
      if (cancelled) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                     "FFmpegFallbackThread: cancelled before StartFfmpegDemux");
        return;
      }

      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "FFmpegFallbackThread: AVPlayer released, start FFmpeg demux for url=%s", urlCopy.c_str());
      StartFfmpegDemux(state, urlCopy);
    });
    // B6修复：FFmpeg 路径已接管，抑制 tsfOnError，防止 ArkTS fallbackNativeToIjk()
    // 抢占 XComponent surface，导致 FFmpeg EGL 初始化失败。
    // FFmpeg 准备好后会通过 tsfOnPrepared 通知 ArkTS；
    // FFmpeg 自身失败时，StartFfmpegDemux 内部负责触发 tsfOnError。
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "OnAVPlayerErrorCB: FFmpeg path taken over, suppressing tsfOnError/tsfOnBufferingFalse");
    // B6修复：通知 ArkTS FFmpeg 已接管，让上层重置守卫计时器至 15s，
    // 避免 3.5s 超时误触 fallbackNativeToIjk 导致 surface 被 IJK 抢占。
    if (state->tsfOnFfmpegSwitching != nullptr) {
      napi_call_threadsafe_function(state->tsfOnFfmpegSwitching, nullptr, napi_tsfn_nonblocking);
    }
    return;
  }

  if (state->tsfOnError != nullptr) {
    // PR#49（问题5）：携带 code+msg，由 tsfOnError call_js_cb 负责 delete
    auto *errData = new ErrorData{
      errorCode,
      new std::string(errorMsg ? errorMsg : "AVPlayer error")
    };
    napi_call_threadsafe_function(state->tsfOnError, errData, napi_tsfn_nonblocking);
  }
  // PR#49（问题4）：error 路径同样需要结束 buffering 状态
  if (state->tsfOnBufferingFalse != nullptr) {
    napi_call_threadsafe_function(state->tsfOnBufferingFalse, nullptr, napi_tsfn_nonblocking);
  }
}

static void OnXCSurfaceCreated(OH_NativeXComponent *component, void *window) {
  char idBuf[OH_XCOMPONENT_ID_LEN_MAX + 1] = {0};
  uint64_t idSize = sizeof(idBuf);
  if (OH_NativeXComponent_GetXComponentId(component, idBuf, &idSize) !=
      OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
    return;
  }
  const std::string xcId(idBuf);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "OnXCSurfaceCreated: xcId=%s window=%p", xcId.c_str(), window);

  std::lock_guard<std::mutex> lock(g_playersMutex); // A4: 保护 g_players 跨线程遍历
  g_liveWindows[xcId] = { component, static_cast<OHNativeWindow *>(window) };
  bool found = false;
  for (auto &pair : g_players) {
    if (pair.second.xComponentId == xcId) {
      pair.second.nativeWindow = static_cast<OHNativeWindow *>(window);
      pair.second.surfaceReady = true;
      found = true;
      // B3：若 FFmpeg 渲染线程在等待 nativeWindow，现在 Surface 就绪，补发启动
      if (pair.second.useFfmpegPath && pair.second.pendingFfmpegRender) {
        StartFfmpegRender(&pair.second);
      }
      // A5修复: 若 avPlayer 已创建，立即绑定 surface
      if (pair.second.avPlayer != nullptr) {
        OH_AVPlayer_SetVideoSurface(pair.second.avPlayer, pair.second.nativeWindow);
        // 若 Prepare() 因 surface 未就绪而延迟，现在补发 Prepare
        if (pair.second.pendingPrepare) {
          pair.second.pendingPrepare = false;
          OH_AVPlayer_Prepare(pair.second.avPlayer);
        }
      }
      break;
    }
  }

  if (!found) {
    // SetXComponent 还未被调用（Init 注册回调时序早于 ArkTS onLoad），
    // 缓存 window，等 SetXComponent 来关联。
    g_pendingWindows[xcId] = { component, static_cast<OHNativeWindow *>(window) };
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "OnXCSurfaceCreated: player 未就绪，缓存 window 待 SetXComponent 关联 xcId=%s",
                 xcId.c_str());
  }
}

static void OnXCSurfaceChanged(OH_NativeXComponent *component, void *window) {
  (void)component;
  (void)window;
  // A3 阶段暂不处理 surface 尺寸变化
}

static void OnXCSurfaceDestroyed(OH_NativeXComponent *component, void *window) {
  (void)window;
  char idBuf[OH_XCOMPONENT_ID_LEN_MAX + 1] = {0};
  uint64_t idSize = sizeof(idBuf);
  if (OH_NativeXComponent_GetXComponentId(component, idBuf, &idSize) !=
      OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
    return;
  }
  const std::string xcId(idBuf);
  std::lock_guard<std::mutex> lock(g_playersMutex); // A4: 保护 g_players 跨线程遍历
  for (auto &pair : g_players) {
    if (pair.second.xComponentId == xcId) {
      pair.second.nativeWindow = nullptr;
      pair.second.surfaceReady = false;
      break;
    }
  }
  // PR#49（问题9）：清除悬空的 pending window 缓存，避免 surface 销毁后 use-after-free
  g_pendingWindows.erase(xcId);
  g_liveWindows.erase(xcId);
}

static void OnXCDispatchTouchEvent(OH_NativeXComponent *component, void *window) {
  (void)component;
  (void)window;
  // 播放器不处理触摸事件
}

// 所有 OH_NativeXComponent 实例共用一套函数指针，回调内部通过 xComponentId 区分
static OH_NativeXComponent_Callback s_xcCallback = {
  .OnSurfaceCreated = OnXCSurfaceCreated,
  .OnSurfaceChanged = OnXCSurfaceChanged,
  .OnSurfaceDestroyed = OnXCSurfaceDestroyed,
  .DispatchTouchEvent = OnXCDispatchTouchEvent,
};

static napi_value SetXComponent(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = { nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setXComponent failed to read args");
    return nullptr;
  }
  if (argc < 3) {
    ThrowTypeError(env, "setXComponent requires (handle, context, xComponentId)");
    return nullptr;
  }
  int32_t handle = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "setXComponent handle must be int32");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  if (!EnsureObjectArg(env, args[1], "setXComponent context must be object")) {
    return nullptr;
  }
  std::string xComponentId;
  if (!ReadUtf8String(env, args[2], xComponentId)) {
    ThrowTypeError(env, "setXComponent xComponentId must be string");
    return nullptr;
  }
  state->xComponentId = xComponentId;

  // 从 context 中提取 OH_NativeXComponent*。
  // nativeWindow 由 OnSurfaceCreated 回调写入；此处仅注册回调，不直接获取 window。
  OH_NativeXComponent *nativeXC = nullptr;
  napi_unwrap(env, args[1], reinterpret_cast<void **>(&nativeXC));

  // 切换渲染目标：先停止现有 avPlayer（surface 将失效），重置骨架态，再注册新回调。
  // 用 stateMutex 保护，防止与 RenderThreadFunc 并发双释放。
  OH_AVPlayer *avToRelease = nullptr;
  {
    std::lock_guard<std::mutex> lk(state->stateMutex);
    state->cancelPendingFfmpegFallback = true;
    avToRelease = state->avPlayer;
    state->avPlayer = nullptr;
  }
  JoinFfmpegFallbackThread(*state);
  if (avToRelease != nullptr) {
    OH_AVPlayer_Stop(avToRelease);
    OH_AVPlayer_Release(avToRelease);
  }
  state->nativeWindow = nullptr;
  state->surfaceReady = false;

  // 切换渲染目标后重置骨架态，避免旧 prepared/时间轴状态延续到新 surface。
  ResetRuntimeState(*state);

  // 注册 XComponent 回调，OnSurfaceCreated 触发后写入 nativeWindow。
  // 修复 #48-A5: 若 Init() 已对同一 nativeXC 注册过（g_pendingXC），跳过重复注册；
  // 不同 nativeXC（多 XComponent 场景或切换）则重新注册。
  if (nativeXC != nullptr && nativeXC != g_pendingXC) {
    OH_NativeXComponent_RegisterCallback(nativeXC, &s_xcCallback);
  }

  // 修复 #48-A5: 检查 OnSurfaceCreated 是否已先行触发并缓存了 window
  // （Init 中注册回调时序早于 ArkTS onLoad/SetXComponent）
  {
    std::lock_guard<std::mutex> pendingLock(g_playersMutex);
    auto pendingIt = g_pendingWindows.find(xComponentId);
    if (pendingIt != g_pendingWindows.end()) {
      state->nativeWindow = pendingIt->second.nativeWindow;
      state->surfaceReady = true;
      g_pendingWindows.erase(pendingIt);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "SetXComponent: 从 pending 恢复 nativeWindow=%p xcId=%s",
                   state->nativeWindow, xComponentId.c_str());
    } else {
      auto liveIt = g_liveWindows.find(xComponentId);
      if (liveIt != g_liveWindows.end()) {
        state->nativeWindow = liveIt->second.nativeWindow;
        state->surfaceReady = state->nativeWindow != nullptr;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "SetXComponent: 从 live cache 恢复 nativeWindow=%p xcId=%s",
                     state->nativeWindow, xComponentId.c_str());
      }
    }
  }

  EmitTimeUpdate(*state);
  return ReturnUndefinedOrThrow(env, "setXComponent failed to create return value");
}

static napi_value Prepare(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "prepare requires (handle)");
    return nullptr;
  }
  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  NativePlayerSkeletonState &state = *statePtr;
  if (state.prepared) {
    // 幂等处理：重复 prepare 不再重复触发 onPrepared，仅补发时间轴。
    EmitTimeUpdate(state);
    return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
  }
  if (state.url.empty()) {
    EmitError(state, ERR_PREPARE_EMPTY_URL, "prepare failed: source url is empty");
    return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
  }
  if (state.xComponentId.empty()) {
    EmitError(state, ERR_PREPARE_EMPTY_XCOMPONENT, "prepare failed: xComponentId is empty");
    return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
  }

  NativePreferredDecodePath preferredDecodePath = NativePreferredDecodePath::HARDWARE_PREFERRED;
  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    preferredDecodePath = state.preferredDecodePath;
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "Prepare: preferredDecodePath=%s url=%s xComponentId=%s",
               PreferredDecodePathToString(preferredDecodePath),
               state.url.c_str(),
               state.xComponentId.c_str());

  if (preferredDecodePath == NativePreferredDecodePath::FFMPEG_ONLY) {
    {
      std::lock_guard<std::mutex> lk(state.stateMutex);
      state.useFfmpegPath = true;
      state.pendingPrepare = false;
    }
    EmitBufferingChange(state, true);
    StartFfmpegDemux(&state, state.url);
    return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
  }

  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    state.useFfmpegPath = false;
  }

  // A3：创建 OH_AVPlayer 实例（每次 prepare 前确保实例存在）
  if (state.avPlayer == nullptr) {
    state.avPlayer = OH_AVPlayer_Create();
    if (state.avPlayer == nullptr) {
      EmitError(state, ERR_PREPARE_EMPTY_URL, "prepare failed: OH_AVPlayer_Create returned nullptr");
      return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
    }
  }

  // 设置播放源 URL
  OH_AVErrCode avRet = OH_AVPlayer_SetURLSource(state.avPlayer, state.url.c_str());
  if (avRet != AV_ERR_OK) {
    EmitError(state, ERR_PREPARE_EMPTY_URL, "prepare failed: OH_AVPlayer_SetURLSource failed");
    return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
  }

  // 绑定渲染 Surface：必须在 OH_AVPlayer_Prepare 之前调用
  // A5修复: 若 surface 未就绪，设置 pendingPrepare 标志，等 OnSurfaceCreated 回调后再 Prepare
  if (state.nativeWindow != nullptr) {
    OH_AVPlayer_SetVideoSurface(state.avPlayer, state.nativeWindow);
  } else {
    state.pendingPrepare = true;
  }

  // A4：注册媒体状态回调（在 Prepare 调用前注册）
  // 使用新式带 userData 的 API（SDK API 12+），不持有 g_playersMutex 以避免与 Release 死锁
  OH_AVPlayer_SetOnInfoCallback(state.avPlayer, OnAVPlayerInfoCB, &state);
  OH_AVPlayer_SetOnErrorCallback(state.avPlayer, OnAVPlayerErrorCB, &state);

  // 若 surface 已就绪，直接 Prepare；否则由 OnSurfaceCreated 补发
  if (!state.pendingPrepare) {
    // 异步 prepare：SDK 中无 PrepareAsync，OH_AVPlayer_Prepare 本身为非阻塞；
    // prepared 标志与 onPrepared 回调均由 OnAVPlayerInfoCB 在 AV_PREPARED 状态时通过 TSF 触发
    OH_AVPlayer_Prepare(state.avPlayer);
  }

  // 在 JS 线程发出"开始缓冲"通知；prepared / onPrepared / EmitTimeUpdate 改由异步回调完成
  EmitBufferingChange(state, true);
  return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
}

static napi_value SetCallbacks(napi_env env, napi_callback_info info) {
  size_t argc = 9;
  napi_value args[9] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setCallbacks failed to read args");
    return nullptr;
  }
  if (argc < 5) {
    ThrowTypeError(env,
      "setCallbacks requires (handle, onPrepared, onError, onTimeUpdate, onCompleted[, onBufferingChange[, onSeekDone[, onFfmpegSwitching[, onSubtitleUpdate]]]])");
    return nullptr;
  }
  int32_t handle = 0;
  const bool hasBufferingArg = (argc >= 6);
  const bool hasSeekDoneArg = (argc >= 7);
  const bool hasFfmpegSwitchingArg = (argc >= 8);
  const bool hasSubtitleUpdateArg = (argc >= 9);
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "setCallbacks handle must be int32");
    return nullptr;
  }
  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  NativePlayerSkeletonState &state = *statePtr;
  if (!EnsureFunctionArg(env, args[1], "setCallbacks onPrepared must be function")) {
    return nullptr;
  }
  if (!EnsureFunctionArg(env, args[2], "setCallbacks onError must be function")) {
    return nullptr;
  }
  if (!EnsureFunctionArg(env, args[3], "setCallbacks onTimeUpdate must be function")) {
    return nullptr;
  }
  if (!EnsureFunctionArg(env, args[4], "setCallbacks onCompleted must be function")) {
    return nullptr;
  }
  if (hasBufferingArg) {
    if (!EnsureFunctionArg(env, args[5], "setCallbacks onBufferingChange must be function")) {
      return nullptr;
    }
  }
  if (hasSeekDoneArg) {
    if (!EnsureFunctionArg(env, args[6], "setCallbacks onSeekDone must be function")) {
      return nullptr;
    }
  }
  if (hasFfmpegSwitchingArg) {
    if (!EnsureFunctionArg(env, args[7], "setCallbacks onFfmpegSwitching must be function")) {
      return nullptr;
    }
  }
  if (hasSubtitleUpdateArg) {
    if (!EnsureFunctionArg(env, args[8], "setCallbacks onSubtitleUpdate must be function")) {
      return nullptr;
    }
  }

  // Release old refs before overwriting
  ClearCallbackRefs(state, env);
  if (napi_create_reference(env, args[1], 1, &state.onPreparedRef) != napi_ok) {
    ClearCallbackRefs(state, env);
    ThrowTypeError(env, "setCallbacks failed to create onPrepared callback reference");
    return nullptr;
  }
  if (napi_create_reference(env, args[2], 1, &state.onErrorRef) != napi_ok) {
    ClearCallbackRefs(state, env);
    ThrowTypeError(env, "setCallbacks failed to create onError callback reference");
    return nullptr;
  }
  if (napi_create_reference(env, args[3], 1, &state.onTimeUpdateRef) != napi_ok) {
    ClearCallbackRefs(state, env);
    ThrowTypeError(env, "setCallbacks failed to create onTimeUpdate callback reference");
    return nullptr;
  }
  if (napi_create_reference(env, args[4], 1, &state.onCompletedRef) != napi_ok) {
    ClearCallbackRefs(state, env);
    ThrowTypeError(env, "setCallbacks failed to create onCompleted callback reference");
    return nullptr;
  }
  if (hasBufferingArg) {
    if (napi_create_reference(env, args[5], 1, &state.onBufferingChangeRef) != napi_ok) {
      ClearCallbackRefs(state, env);
      ThrowTypeError(env, "setCallbacks failed to create onBufferingChange callback reference");
      return nullptr;
    }
  }
  if (hasSeekDoneArg) {
    if (napi_create_reference(env, args[6], 1, &state.onSeekDoneRef) != napi_ok) {
      ClearCallbackRefs(state, env);
      ThrowTypeError(env, "setCallbacks failed to create onSeekDone callback reference");
      return nullptr;
    }
  }
  if (hasSubtitleUpdateArg) {
    if (napi_create_reference(env, args[8], 1, &state.onSubtitleUpdateRef) != napi_ok) {
      ClearCallbackRefs(state, env);
      ThrowTypeError(env, "setCallbacks failed to create onSubtitleUpdate callback reference");
      return nullptr;
    }
  }
  state.callbackEnv = env;

  // A4：为每个回调额外创建 threadsafe function，供媒体线程异步回调 ArkTS
  // call_js_cb 均为无捕获 lambda（可隐式转换为函数指针），在 JS 线程上执行
  {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnPrepared", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[1], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        // PR#49（问题4）：prepared 时同步发出 buffering=false，确保 UI 退出加载态
        auto *st = static_cast<NativePlayerSkeletonState *>(ctx);
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 0, nullptr, nullptr);
        EmitBufferingChange(*st, false);
      },
      &state.tsfOnPrepared);
  }
  {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnCompleted", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[4], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        // PR#49（问题4）：completed 时同步发出 buffering=false
        auto *st = static_cast<NativePlayerSkeletonState *>(ctx);
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 0, nullptr, nullptr);
        EmitBufferingChange(*st, false);
      },
      &state.tsfOnCompleted);
  }
  {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnTimeUpdate", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[3], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        // ctx = NativePlayerSkeletonState*，读取当前播放位置
        auto *st = static_cast<NativePlayerSkeletonState *>(ctx);
        napi_value timeValue;
        napi_create_int64(tsfEnv, st->currentTimeMs, &timeValue);
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 1, &timeValue, nullptr);
      },
      &state.tsfOnTimeUpdate);
  }
  {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnError", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[2], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        // PR#49（问题5）：data = heap ErrorData*，携带 code+msg，此处负责 delete
        auto *errData = static_cast<ErrorData *>(data);
        napi_value codeVal = nullptr;
        napi_create_int32(tsfEnv, errData ? errData->code : -1, &codeVal);
        napi_value msgVal = nullptr;
        napi_create_string_utf8(tsfEnv,
          (errData && errData->msg) ? errData->msg->c_str() : "AVPlayer error",
          NAPI_AUTO_LENGTH, &msgVal);
        napi_value argv[2] = { codeVal, msgVal };
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 2, argv, nullptr);
        if (errData) {
          delete errData->msg;
          delete errData;
        }
      },
      &state.tsfOnError);
  }
  // PR#49（问题4/7）：为 AV_PLAYING/AV_PAUSED/error 创建 buffering=false TSF；
  //                    为 AV_INFO_TYPE_SEEKDONE 创建 seekDone TSF
  if (hasBufferingArg) {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnBufferingFalse", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[5], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        // 直接调用 onBufferingChange(false)；不使用 ctx，由 jsCb（args[5]）接收
        napi_value boolFalse = nullptr;
        napi_get_boolean(tsfEnv, false, &boolFalse);
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 1, &boolFalse, nullptr);
      },
      &state.tsfOnBufferingFalse);
  }
  if (hasSeekDoneArg) {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnSeekDone", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[6], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 0, nullptr, nullptr);
      },
      &state.tsfOnSeekDone);
  }
  if (hasSubtitleUpdateArg) {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnSubtitleUpdate", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[8], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        auto *subtitleData = static_cast<SubtitleData *>(data);
        napi_value infoObj = nullptr;
        napi_create_object(tsfEnv, &infoObj);
        if (subtitleData != nullptr) {
          napi_value durationVal = nullptr;
          napi_create_int64(tsfEnv, subtitleData->durationMs, &durationVal);
          napi_set_named_property(tsfEnv, infoObj, "duration", durationVal);
          napi_value startTimeVal = nullptr;
          napi_create_int64(tsfEnv, subtitleData->startTimeMs, &startTimeVal);
          napi_set_named_property(tsfEnv, infoObj, "startTime", startTimeVal);
          napi_value textVal = nullptr;
          napi_create_string_utf8(tsfEnv,
            (subtitleData->text != nullptr) ? subtitleData->text->c_str() : "",
            NAPI_AUTO_LENGTH, &textVal);
          napi_set_named_property(tsfEnv, infoObj, "text", textVal);
        }
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 1, &infoObj, nullptr);
        if (subtitleData != nullptr) {
          delete subtitleData->text;
          delete subtitleData;
        }
      },
      &state.tsfOnSubtitleUpdate);
  }
  // B6修复：注册 tsfOnFfmpegSwitching（可选，args[7]）
  // FFmpeg 接管后通知 ArkTS 重置守卫计时器至 15s，防止 3.5s 超时误触 fallback。
  if (hasFfmpegSwitchingArg) {
    napi_value resName;
    napi_create_string_utf8(env, "tsfOnFfmpegSwitching", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(
      env, args[7], nullptr, resName, 0, 1, nullptr, nullptr, statePtr,
      [](napi_env tsfEnv, napi_value jsCb, void *ctx, void *data) {
        napi_value undef;
        napi_get_undefined(tsfEnv, &undef);
        napi_call_function(tsfEnv, undef, jsCb, 0, nullptr, nullptr);
      },
      &state.tsfOnFfmpegSwitching);
  }

  // 若回调在 prepared 之后才注册，主动补发一次状态，避免上层错过时序。
  if (state.prepared) {
    if (state.onPreparedRef != nullptr && state.callbackEnv != nullptr) {
      CallJsFunction(state.callbackEnv, state.onPreparedRef, 0, nullptr);
    }
    EmitTimeUpdate(state);
  }
  return ReturnUndefinedOrThrow(env, "setCallbacks failed to create return value");
}

static napi_value Play(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "play requires (handle)");
    return nullptr;
  }
  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  NativePlayerSkeletonState &state = *statePtr;
  if (!EnsurePreparedOrEmitError(
    state,
    ERR_PLAY_NOT_PREPARED,
    "play failed: player is not prepared"
  )) {
    return ReturnUndefinedOrThrow(env, "play failed to create return value");
  }
  {
    // PR#49（问题6）：保护 playing/lastRealtimeMs 写操作；OH_AVPlayer_Play 在锁外调用
    std::lock_guard<std::mutex> lock(state.stateMutex);
    if (state.playing) {
      // 幂等处理：已在播放态时忽略重复 play。
      return ReturnUndefinedOrThrow(env, "play failed to create return value");
    }
    state.playing = true;
    state.lastRealtimeMs = NowRealtimeMs();
  }
  if (state.useFfmpegPath && state.ffmpegCtx != nullptr) {
    state.ffmpegCtx->playbackPaused.store(false, std::memory_order_relaxed);
    // [Fix-Resume-Clock] Resume 后对齐时钟锚点：以 lastReportedMs（pause 时最后报告的 clockMs）
    // 为基准重建 base，确保 gate 重开后 diff ≈ hwOffset（≤ 1 帧），而非虚高的 2-3 秒。
    // Pause() 已将 baseMs = pausedClockMs；此处用 lastReportedMs + hwOffset 覆盖，
    // 使 candidateMs = (lastRep + hwOffset) + 0 - hwOffset = lastRep，clock 从 pause 位置续跑。
    {
      const int64_t lastRep = state.ffmpegCtx->audioClockLastReportedMs.load(std::memory_order_relaxed);
      const int64_t hwOff   = state.ffmpegCtx->audioHardwareSafetyOffsetMs.load(std::memory_order_relaxed);
      if (lastRep > 0) {
        state.ffmpegCtx->audioClockBaseMs.store(lastRep + hwOff, std::memory_order_relaxed);
        state.ffmpegCtx->audioClockFloorMs.store(lastRep, std::memory_order_relaxed);
        state.ffmpegCtx->audioClockLastReportedMs.store(lastRep, std::memory_order_relaxed);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                     "Play: FFmpeg resume clock aligned lastRep=%{public}lld hwOff=%{public}lld newBase=%{public}lld",
                     static_cast<long long>(lastRep), static_cast<long long>(hwOff),
                     static_cast<long long>(lastRep + hwOff));
      }
    }
    state.ffmpegCtx->audioClockStartRealtimeMs.store(0, std::memory_order_relaxed);
    state.ffmpegCtx->audioPtsSamples.store(0, std::memory_order_relaxed);
    state.ffmpegCtx->videoSyncGraceFrames.store(5, std::memory_order_relaxed);  // 小 grace：resume 后几帧保护
    if (state.ffmpegCtx->audioRenderer != nullptr) {
      {
        std::lock_guard<std::mutex> audioRenderLk(state.ffmpegCtx->audioRenderStateMutex);
        // 不调 ResetAudioClockAnchorLocked：暂停状态下 GetTimestamp 返回旧 T_paused，
        // Resume 后 renderedSinceTs = (now - T_paused) * sampleRate 会包含整个暂停时长，
        // 导致 candidateMs 跳跃到错误位置（video 超前 audio 数十秒）。
        // 直接设 -1，让 Resume 后首次有效 GetTimestamp 建立新锚点（<20ms 内）。
        state.ffmpegCtx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
        state.ffmpegCtx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
      }
      const OH_AudioStream_Result result = OH_AudioRenderer_Start(state.ffmpegCtx->audioRenderer);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "Play: FFmpeg path OH_AudioRenderer_Start result=%{public}d",
                   static_cast<int32_t>(result));
    }
    {
      std::lock_guard<std::mutex> lock(state.stateMutex);
      state.currentTimeMs = static_cast<int64_t>(AudioClock(state.ffmpegCtx.get()) * 1000.0);
    }
    EmitTimeUpdate(state);
    return ReturnUndefinedOrThrow(env, "play failed to create return value");
  }
  // A3：驱动 OH_AVPlayer 真实播放
  if (state.avPlayer != nullptr) {
    OH_AVPlayer_Play(state.avPlayer);
  }
  EmitTimeUpdate(state);
  return ReturnUndefinedOrThrow(env, "play failed to create return value");
}

static napi_value Pause(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "pause requires (handle)");
    return nullptr;
  }
  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  NativePlayerSkeletonState &state = *statePtr;
  if (!EnsurePreparedOrEmitError(
    state,
    ERR_PAUSE_NOT_PREPARED,
    "pause failed: player is not prepared"
  )) {
    return ReturnUndefinedOrThrow(env, "pause failed to create return value");
  }
  {
    // PR#49（问题6）：保护 playing/lastRealtimeMs/currentTimeMs 写操作；OH_AVPlayer_Pause 在锁外
    std::lock_guard<std::mutex> lock(state.stateMutex);
    if (!state.playing) {
      // 幂等处理：已暂停时忽略重复 pause。
      return ReturnUndefinedOrThrow(env, "pause failed to create return value");
    }
    if (state.useFfmpegPath && state.ffmpegCtx != nullptr) {
      state.currentTimeMs = static_cast<int64_t>(AudioClock(state.ffmpegCtx.get()) * 1000.0);
    } else {
      AdvancePlaybackClockIfNeeded(state);
    }
    state.playing = false;
    state.lastRealtimeMs = 0;
  }
  if (state.useFfmpegPath && state.ffmpegCtx != nullptr) {
    const int64_t pausedClockMs = static_cast<int64_t>(AudioClock(state.ffmpegCtx.get()) * 1000.0);
    state.ffmpegCtx->audioClockBaseMs.store(pausedClockMs, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockStartRealtimeMs.store(0, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockLastReportedMs.store(pausedClockMs, std::memory_order_relaxed);
    state.ffmpegCtx->audioPtsSamples.store(0, std::memory_order_relaxed);
    state.ffmpegCtx->playbackPaused.store(true, std::memory_order_relaxed);
    if (state.ffmpegCtx->audioRenderer != nullptr) {
      const OH_AudioStream_Result result = OH_AudioRenderer_Pause(state.ffmpegCtx->audioRenderer);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "Pause: FFmpeg path OH_AudioRenderer_Pause result=%{public}d",
                   static_cast<int32_t>(result));
    }
    EmitTimeUpdate(state);
    return ReturnUndefinedOrThrow(env, "pause failed to create return value");
  }
  // A3：驱动 OH_AVPlayer 真实暂停
  if (state.avPlayer != nullptr) {
    OH_AVPlayer_Pause(state.avPlayer);
  }
  EmitTimeUpdate(state);
  return ReturnUndefinedOrThrow(env, "pause failed to create return value");
}

static napi_value Seek(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "seek failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "seek requires (handle, positionMs)");
    return nullptr;
  }
  int32_t handle = 0;
  int64_t positionMs = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "seek handle must be int32");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[1], &positionMs) != napi_ok) {
    ThrowTypeError(env, "seek positionMs must be int64");
    return nullptr;
  }
  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  NativePlayerSkeletonState &state = *statePtr;
  if (!EnsurePreparedOrEmitError(
    state,
    ERR_SEEK_NOT_PREPARED,
    "seek failed: player is not prepared"
  )) {
    return ReturnUndefinedOrThrow(env, "seek failed to create return value");
  }
  if (positionMs < 0) {
    positionMs = 0;
  }

  // B5：FFmpeg 路径：通过原子标志异步触发 demux 线程执行 av_seek_frame
  if (state.useFfmpegPath && state.ffmpegCtx != nullptr) {
    {
      std::lock_guard<std::mutex> lock(state.stateMutex);
      if (state.durationMs > 0 && positionMs > state.durationMs) {
        positionMs = state.durationMs;
      }
      state.currentTimeMs = positionMs;
    }
    state.ffmpegCtx->audioClockBaseMs.store(positionMs, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockFloorMs.store(positionMs, std::memory_order_relaxed);  // seek：floor = 目标位置
    state.ffmpegCtx->audioClockAnchorFramePosition.store(-1, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockAnchorFramesWritten.store(-1, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockStartRealtimeMs.store(0, std::memory_order_relaxed);
    state.ffmpegCtx->audioClockLastReportedMs.store(positionMs, std::memory_order_relaxed);
    state.ffmpegCtx->audioPtsSamples.store(0, std::memory_order_relaxed);
    state.ffmpegCtx->seekTargetMs.store(positionMs);
    state.ffmpegCtx->seekRequested.store(true);
    EmitTimeUpdate(state);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "Seek: FFmpeg path seek requested to %lld ms",
                 static_cast<long long>(positionMs));
    return ReturnUndefinedOrThrow(env, "seek failed to create return value");
  }

  {
    // PR#49（问题6）：保护 currentTimeMs/durationMs/lastRealtimeMs 读写；OH_AVPlayer_Seek 在锁外
    std::lock_guard<std::mutex> lock(state.stateMutex);
    if (state.durationMs > 0 && positionMs > state.durationMs) {
      positionMs = state.durationMs;
    }
    state.currentTimeMs = positionMs;
    if (state.playing) {
      state.lastRealtimeMs = NowRealtimeMs();
    }
  }
  // A3：驱动 OH_AVPlayer 真实 seek（PREVIOUS_SYNC 模式，适合直播与点播）
  if (state.avPlayer != nullptr) {
    OH_AVPlayer_Seek(state.avPlayer, static_cast<int32_t>(positionMs), AV_SEEK_PREVIOUS_SYNC);
  }
  EmitTimeUpdate(state);
  // PR#49（问题7）：EmitSeekDone 移至 AV_INFO_TYPE_SEEKDONE 回调（异步完成后触发），此处不再调用
  return ReturnUndefinedOrThrow(env, "seek failed to create return value");
}

static napi_value SelectTrack(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "selectTrack failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "selectTrack requires (handle, trackIndex)");
    return nullptr;
  }
  int32_t handle = 0;
  int32_t trackIndex = -1;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "selectTrack handle must be int32");
    return nullptr;
  }
  if (napi_get_value_int32(env, args[1], &trackIndex) != napi_ok) {
    ThrowTypeError(env, "selectTrack trackIndex must be int32");
    return nullptr;
  }
  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  NativePlayerSkeletonState &state = *statePtr;
  if (!EnsurePreparedOrEmitError(
    state,
    ERR_SELECT_TRACK_NOT_PREPARED,
    "selectTrack failed: player is not prepared"
  )) {
    return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
  }
  if (trackIndex < -1) {
    EmitError(state, ERR_SELECT_TRACK_INVALID_INDEX, "selectTrack failed: trackIndex must be >= -1");
    return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
  }

  if (state.useFfmpegPath && state.ffmpegCtx != nullptr) {
    FfmpegContext *ctx = state.ffmpegCtx.get();
    if (ctx == nullptr || ctx->fmtCtx == nullptr) {
      EmitError(state, ERR_SELECT_TRACK_UNSUPPORTED,
                "selectTrack failed: FFmpeg path is unavailable");
      return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
    }
    if (trackIndex < 0 || trackIndex >= static_cast<int32_t>(ctx->fmtCtx->nb_streams)) {
      EmitError(state, ERR_SELECT_TRACK_INVALID_INDEX,
                "selectTrack failed: FFmpeg audio stream index is out of range");
      return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
    }
    AVStream *targetStream = ctx->fmtCtx->streams[trackIndex];
    if (targetStream == nullptr || targetStream->codecpar == nullptr ||
        targetStream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
      EmitError(state, ERR_SELECT_TRACK_INVALID_INDEX,
                "selectTrack failed: target stream is not audio");
      return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
    }

    int32_t previousTrackIndex = -1;
    {
      std::lock_guard<std::mutex> lk(state.stateMutex);
      previousTrackIndex = state.selectedTrackIndex;
    }
    const int previousAudioStreamIdx = ctx->audioStreamIdx.load(std::memory_order_relaxed);
    if (previousAudioStreamIdx == trackIndex) {
      std::lock_guard<std::mutex> lk(state.stateMutex);
      state.selectedTrackIndex = trackIndex;
      return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "SelectTrack: FFmpeg audio switch requested previous=%{public}d target=%{public}d",
                 previousTrackIndex, trackIndex);
    ctx->selectTrackTargetIndex.store(trackIndex, std::memory_order_relaxed);
    ctx->selectTrackRequested.store(true, std::memory_order_release);
    return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
  }

  OH_AVPlayer *avPlayer = nullptr;
  bool wasPlaying = false;
  int32_t previousTrackIndex = -1;
  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    avPlayer = state.avPlayer;
    wasPlaying = state.playing;
    previousTrackIndex = state.selectedTrackIndex;
  }
  if (avPlayer == nullptr) {
    EmitError(state, ERR_SELECT_TRACK_UNSUPPORTED, "selectTrack failed: avPlayer is unavailable");
    return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
  }

  if (wasPlaying) {
    OH_AVPlayer_Pause(avPlayer);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "SelectTrack: previous=%{public}d target=%{public}d wasPlaying=%{public}d",
               previousTrackIndex, trackIndex, wasPlaying ? 1 : 0);

  OH_AVErrCode rc = AV_ERR_OK;
  if (trackIndex >= 0) {
    rc = OH_AVPlayer_SelectTrack(avPlayer, trackIndex);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "SelectTrack: select target=%{public}d rc=%{public}d",
                 trackIndex, static_cast<int32_t>(rc));
  }

  if (rc != AV_ERR_OK) {
    if (wasPlaying) {
      OH_AVPlayer_Play(avPlayer);
    }
    EmitError(state, ERR_SELECT_TRACK_FAILED, "selectTrack failed: OH_AVPlayer_SelectTrack returned error");
    return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
  }

  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    state.selectedTrackIndex = trackIndex;
  }
  if (wasPlaying) {
    OH_AVPlayer_Play(avPlayer);
  }
  return ReturnUndefinedOrThrow(env, "selectTrack failed to create return value");
}

static napi_value Release(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "release requires (handle)");
    return nullptr;
  }
  // PR#49（问题3）：分两段持锁：
  //   ① 持锁找到 state 指针后立即释放，避免 OH_AVPlayer_Release（阻塞）期间持有 g_playersMutex
  //   ② OH_AVPlayer 操作全部在无锁下完成
  //   ③ 最后再持锁 erase（JS 线程单线程，两段锁之间不会有其他 JS 代码修改 map 结构）
  NativePlayerSkeletonState *statePtr = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_playersMutex);
    auto iter = g_players.find(handle);
    if (iter == g_players.end()) {
      // 幂等处理：重复 release 直接视为成功。
      return ReturnUndefinedOrThrow(env, "release failed to create return value");
    }
    statePtr = &iter->second;
  }
  NativePlayerSkeletonState &state = *statePtr;
  // A4 顺序说明：
  //   1. OH_AVPlayer_Release：等待所有媒体线程回调执行完毕（含 OnAVPlayerInfoCB / OnAVPlayerErrorCB）
  //   2. ClearCallbackRefs（含 ReleaseTsfIfPresent napi_tsfn_abort）：此时媒体线程已无回调，
  //      abort 可安全丢弃 OH_AVPlayer_Release 前已入队但尚未在 JS 线程执行的 TSF 调用
  //   3. 再 erase state：上两步完成后状态指针不再被任何线程访问
  // 取出 avPlayer（stateMutex 保护，防止与 RenderThreadFunc 并发双释放）。
  // OH_AVPlayer_Release 必须在锁外调用，避免媒体线程回调尝试加锁时死锁。
  OH_AVPlayer *avToRelease = nullptr;
  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    state.cancelPendingFfmpegFallback = true;
    avToRelease = state.avPlayer;
    state.avPlayer = nullptr;
  }
  JoinFfmpegFallbackThread(state);
  if (avToRelease != nullptr) {
    OH_AVPlayer_Stop(avToRelease);
    OH_AVPlayer_Release(avToRelease); // 阻塞直到媒体线程所有回调执行完毕
  }
  // B1：OH_AVPlayer_Release 完成后（媒体线程回调已全部结束），安全停止 demux 线程
  StopFfmpegDemux(&state);
  ResetRuntimeState(state);
  state.url.clear();
  state.headersJson.clear();
  state.xComponentId.clear();
  state.nativeWindow = nullptr;  // 只清引用，生命周期归 XComponent，不调用 release
  state.surfaceReady = false;
  ClearCallbackRefs(state, env); // 内部含 ReleaseTsfIfPresent(napi_tsfn_abort)
  state.callbackEnv = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_playersMutex); // PR#49（问题3）：持锁 erase
    g_players.erase(handle);
  }
  return ReturnUndefinedOrThrow(env, "release failed to create return value");
}

static napi_value GetCurrentTime(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "getCurrentTime requires (handle)");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  AdvancePlaybackClockIfNeeded(*state);
  return ReturnInt64OrThrow(env, state->currentTimeMs, "getCurrentTime failed to create return value");
}

static napi_value GetDuration(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "getDuration requires (handle)");
    return nullptr;
  }
  NativePlayerSkeletonState *state = FindPlayerOrThrow(env, handle);
  if (state == nullptr) {
    return nullptr;
  }
  return ReturnInt64OrThrow(env, state->durationMs, "getDuration failed to create return value");
}

static napi_value FfmpegSelfCheck(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to create result object");
    return nullptr;
  }

  const char *versionInfo = av_version_info();
  const uint32_t avformatVersion = avformat_version();
  const uint32_t avutilVersion = avutil_version();

  napi_value versionValue = nullptr;
  if (napi_create_string_utf8(env, versionInfo, NAPI_AUTO_LENGTH, &versionValue) != napi_ok) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to create avVersionInfo");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "avVersionInfo", versionValue) != napi_ok) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to set avVersionInfo");
    return nullptr;
  }

  napi_value avformatVersionValue = CreateUint32(env, avformatVersion);
  if (avformatVersionValue == nullptr) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to create avformatVersion");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "avformatVersion", avformatVersionValue) != napi_ok) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to set avformatVersion");
    return nullptr;
  }

  napi_value avutilVersionValue = CreateUint32(env, avutilVersion);
  if (avutilVersionValue == nullptr) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to create avutilVersion");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "avutilVersion", avutilVersionValue) != napi_ok) {
    ThrowTypeError(env, "ffmpegSelfCheck failed to set avutilVersion");
    return nullptr;
  }

  return result;
}

// ── WebdavRequest async implementation ──────────────────────────────────────
// WebdavRequest 必须异步：libcurl 的 TLS 握手 + 网络 IO 耗时较长（可能 >5s），
// 若在 JS 主线程同步执行会直接触发 ANR。参照 Ffprobe 的异步模式实现。

struct WebdavRequestAsyncContext {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string method;
  std::string url;
  std::string headerLines;
  std::string body;
  int64_t timeoutMs = 0;
  bool allowSelfSigned = false;
  CurlRequestResult requestResult;
};

static void ExecuteWebdavRequestAsync(napi_env env, void *data) {
  (void)env;
  WebdavRequestAsyncContext *context = static_cast<WebdavRequestAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }
  context->requestResult = RunCurlRequest(
    context->method, context->url, context->headerLines,
    context->body, context->timeoutMs, context->allowSelfSigned
  );
}

static void CompleteWebdavRequestAsync(napi_env env, napi_status status, void *data) {
  WebdavRequestAsyncContext *context = static_cast<WebdavRequestAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }

  if (status != napi_ok) {
    napi_value msg = nullptr;
    napi_value err = nullptr;
    napi_create_string_utf8(env, "webdavRequest async work cancelled", NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, context->deferred, err);
    if (context->work != nullptr) {
      napi_delete_async_work(env, context->work);
    }
    delete context;
    return;
  }

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    napi_value msg = nullptr;
    napi_value err = nullptr;
    napi_create_string_utf8(env, "webdavRequest failed to create result object", NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, context->deferred, err);
    if (context->work != nullptr) {
      napi_delete_async_work(env, context->work);
    }
    delete context;
    return;
  }

  napi_value statusCodeValue = nullptr;
  napi_create_int64(env, context->requestResult.statusCode, &statusCodeValue);
  napi_set_named_property(env, result, "statusCode", statusCodeValue);

  napi_value bodyValue = nullptr;
  napi_create_string_utf8(env, context->requestResult.body.c_str(), NAPI_AUTO_LENGTH, &bodyValue);
  napi_set_named_property(env, result, "body", bodyValue);

  napi_value errorValue = nullptr;
  napi_create_string_utf8(env, context->requestResult.error.c_str(), NAPI_AUTO_LENGTH, &errorValue);
  napi_set_named_property(env, result, "error", errorValue);

  napi_resolve_deferred(env, context->deferred, result);

  if (context->work != nullptr) {
    napi_delete_async_work(env, context->work);
  }
  delete context;
}

static napi_value WebdavRequest(napi_env env, napi_callback_info info) {
  size_t argc = 6;
  napi_value args[6] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "webdavRequest failed to read args");
    return nullptr;
  }
  if (argc < 5) {
    ThrowTypeError(env, "webdavRequest requires (method, url, headerLines, body, timeoutMs[, tlsPolicy])");
    return nullptr;
  }

  WebdavRequestAsyncContext *context = new WebdavRequestAsyncContext();

  if (!ReadUtf8String(env, args[0], context->method)) {
    delete context;
    ThrowTypeError(env, "webdavRequest method must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[1], context->url)) {
    delete context;
    ThrowTypeError(env, "webdavRequest url must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[2], context->headerLines)) {
    delete context;
    ThrowTypeError(env, "webdavRequest headerLines must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[3], context->body)) {
    delete context;
    ThrowTypeError(env, "webdavRequest body must be string");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[4], &context->timeoutMs) != napi_ok) {
    delete context;
    ThrowTypeError(env, "webdavRequest timeoutMs must be int64");
    return nullptr;
  }

  // 可选第 6 个参数：tlsPolicy（字符串，默认 "strict"）。
  // "allow_self_signed" 启用自签名证书受控模式（仅供调试/内网场景，禁止作为生产默认）。
  if (argc >= 6 && args[5] != nullptr) {
    std::string tlsPolicy;
    if (ReadUtf8String(env, args[5], tlsPolicy)) {
      context->allowSelfSigned = (tlsPolicy == "allow_self_signed");
    }
  }

  napi_value promise = nullptr;
  if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
    delete context;
    ThrowTypeError(env, "webdavRequest failed to create promise");
    return nullptr;
  }

  napi_value resourceName = nullptr;
  if (napi_create_string_utf8(env, "webdavRequestAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
    delete context;
    ThrowTypeError(env, "webdavRequest failed to create resource name");
    return nullptr;
  }

  if (napi_create_async_work(env, nullptr, resourceName,
      ExecuteWebdavRequestAsync, CompleteWebdavRequestAsync, context, &context->work) != napi_ok) {
    delete context;
    ThrowTypeError(env, "webdavRequest failed to create async work");
    return nullptr;
  }

  if (napi_queue_async_work(env, context->work) != napi_ok) {
    napi_delete_async_work(env, context->work);
    delete context;
    ThrowTypeError(env, "webdavRequest failed to queue async work");
    return nullptr;
  }

  return promise;
}

// ── DownloadToFile async implementation ─────────────────────────────────────
// 同 webdavRequest，libcurl 下载也需要异步，避免阻塞 JS 主线程。

struct DownloadToFileAsyncContext {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string method;
  std::string url;
  std::string headerLines;
  std::string body;
  int64_t timeoutMs = 0;
  std::string outputPath;
  bool allowSelfSigned = false;
  CurlDownloadResult downloadResult;
};

static void ExecuteDownloadToFileAsync(napi_env env, void *data) {
  (void)env;
  DownloadToFileAsyncContext *context = static_cast<DownloadToFileAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }
  context->downloadResult = RunCurlDownloadToFile(
    context->method, context->url, context->headerLines,
    context->body, context->timeoutMs, context->outputPath, context->allowSelfSigned
  );
}

static void CompleteDownloadToFileAsync(napi_env env, napi_status status, void *data) {
  DownloadToFileAsyncContext *context = static_cast<DownloadToFileAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }

  if (status != napi_ok) {
    napi_value msg = nullptr;
    napi_value err = nullptr;
    napi_create_string_utf8(env, "downloadToFile async work cancelled", NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, context->deferred, err);
    if (context->work != nullptr) {
      napi_delete_async_work(env, context->work);
    }
    delete context;
    return;
  }

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    napi_value msg = nullptr;
    napi_value err = nullptr;
    napi_create_string_utf8(env, "downloadToFile failed to create result object", NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, context->deferred, err);
    if (context->work != nullptr) {
      napi_delete_async_work(env, context->work);
    }
    delete context;
    return;
  }

  napi_value statusCodeValue = nullptr;
  napi_create_int64(env, context->downloadResult.statusCode, &statusCodeValue);
  napi_set_named_property(env, result, "statusCode", statusCodeValue);

  napi_value downloadedBytesValue = nullptr;
  napi_create_int64(env, context->downloadResult.downloadedBytes, &downloadedBytesValue);
  napi_set_named_property(env, result, "downloadedBytes", downloadedBytesValue);

  napi_value errorValue = nullptr;
  napi_create_string_utf8(env, context->downloadResult.error.c_str(), NAPI_AUTO_LENGTH, &errorValue);
  napi_set_named_property(env, result, "error", errorValue);

  napi_resolve_deferred(env, context->deferred, result);

  if (context->work != nullptr) {
    napi_delete_async_work(env, context->work);
  }
  delete context;
}

static napi_value DownloadToFile(napi_env env, napi_callback_info info) {
  size_t argc = 7;
  napi_value args[7] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "downloadToFile failed to read args");
    return nullptr;
  }
  if (argc < 6) {
    ThrowTypeError(env, "downloadToFile requires (method, url, headerLines, body, timeoutMs, outputPath[, tlsPolicy])");
    return nullptr;
  }

  DownloadToFileAsyncContext *context = new DownloadToFileAsyncContext();

  if (!ReadUtf8String(env, args[0], context->method)) {
    delete context;
    ThrowTypeError(env, "downloadToFile method must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[1], context->url)) {
    delete context;
    ThrowTypeError(env, "downloadToFile url must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[2], context->headerLines)) {
    delete context;
    ThrowTypeError(env, "downloadToFile headerLines must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[3], context->body)) {
    delete context;
    ThrowTypeError(env, "downloadToFile body must be string");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[4], &context->timeoutMs) != napi_ok) {
    delete context;
    ThrowTypeError(env, "downloadToFile timeoutMs must be int64");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[5], context->outputPath)) {
    delete context;
    ThrowTypeError(env, "downloadToFile outputPath must be string");
    return nullptr;
  }

  // 可选第 7 个参数：tlsPolicy（字符串，默认 "strict"）。
  // "allow_self_signed" 为受控启用，禁止作为生产默认行为。
  if (argc >= 7 && args[6] != nullptr) {
    std::string tlsPolicy;
    if (ReadUtf8String(env, args[6], tlsPolicy)) {
      context->allowSelfSigned = (tlsPolicy == "allow_self_signed");
    }
  }

  napi_value promise = nullptr;
  if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
    delete context;
    ThrowTypeError(env, "downloadToFile failed to create promise");
    return nullptr;
  }

  napi_value resourceName = nullptr;
  if (napi_create_string_utf8(env, "downloadToFileAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
    delete context;
    ThrowTypeError(env, "downloadToFile failed to create resource name");
    return nullptr;
  }

  if (napi_create_async_work(env, nullptr, resourceName,
      ExecuteDownloadToFileAsync, CompleteDownloadToFileAsync, context, &context->work) != napi_ok) {
    delete context;
    ThrowTypeError(env, "downloadToFile failed to create async work");
    return nullptr;
  }

  if (napi_queue_async_work(env, context->work) != napi_ok) {
    napi_delete_async_work(env, context->work);
    delete context;
    ThrowTypeError(env, "downloadToFile failed to queue async work");
    return nullptr;
  }

  return promise;
}

static napi_value GetNativeCapabilities(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    ThrowTypeError(env, "getNativeCapabilities failed to create result object");
    return nullptr;
  }

  napi_value ffmpegEnabled = CreateBoolean(env, true);
  if (ffmpegEnabled == nullptr) {
    ThrowTypeError(env, "getNativeCapabilities failed to create ffmpegEnabled");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "ffmpegEnabled", ffmpegEnabled) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to set ffmpegEnabled");
    return nullptr;
  }

  const bool libcurlEnabledValue = (VIDALL_HAS_LIBCURL == 1);
  napi_value libcurlEnabled = CreateBoolean(env, libcurlEnabledValue);
  if (libcurlEnabled == nullptr) {
    ThrowTypeError(env, "getNativeCapabilities failed to create libcurlEnabled");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "libcurlEnabled", libcurlEnabled) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to set libcurlEnabled");
    return nullptr;
  }

#if VIDALL_HAS_LIBCURL
  const char *libcurlVersion = curl_version();
#else
  const char *libcurlVersion = "disabled";
#endif
  napi_value libcurlVersionValue = nullptr;
  if (napi_create_string_utf8(env, libcurlVersion, NAPI_AUTO_LENGTH, &libcurlVersionValue) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to create libcurlVersion");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "libcurlVersion", libcurlVersionValue) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to set libcurlVersion");
    return nullptr;
  }

  return result;
}

struct AudioDecoderCapabilityResult {
  bool capabilityKnown = false;
  bool supported = false;
  bool isHardware = false;
  int32_t maxChannels = 0;
  std::string decoderName;
  std::string mimeType;
  std::string errorMessage;
};

struct VideoDecoderCapabilityResult {
  bool capabilityKnown = false;
  bool supported = false;
  bool isHardware = false;
  int32_t minWidth = 0;
  int32_t maxWidth = 0;
  int32_t minHeight = 0;
  int32_t maxHeight = 0;
  int32_t minFrameRate = 0;
  int32_t maxFrameRate = 0;
  int32_t widthAlignment = 0;
  int32_t heightAlignment = 0;
  int32_t maxInstances = 0;
  std::string decoderName;
  std::string mimeType;
  std::string errorMessage;
};

struct VideoDecoderSurfaceProbeResult {
  bool success = false;
  std::string stage;
  bool capabilityKnown = false;
  bool isHardware = false;
  std::string decoderName;
  std::string mimeType;
  std::string stateSummary;
  std::string errorMessage;
};

static std::string ToLowerString(const std::string &value) {
  std::string result = value;
  std::transform(result.begin(), result.end(), result.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return result;
}

static std::vector<std::string> BuildAudioMimeCandidates(const std::string &codecOrMime) {
  const std::string normalized = ToLowerString(codecOrMime);
  if (normalized.empty()) {
    return {};
  }

  std::vector<std::string> candidates;
  auto pushUnique = [&candidates](const std::string &candidate) {
    if (candidate.empty()) {
      return;
    }
    if (std::find(candidates.begin(), candidates.end(), candidate) == candidates.end()) {
      candidates.push_back(candidate);
    }
  };

  if (normalized.rfind("audio/", 0) == 0) {
    pushUnique(normalized);
  }

  if (normalized == "aac" || normalized == "mp4a" || normalized == "mp4a-latm") {
    pushUnique("audio/mp4a-latm");
  } else if (normalized == "mp3" || normalized == "mpeg" || normalized == "mpga") {
    pushUnique("audio/mpeg");
  } else if (normalized == "flac") {
    pushUnique("audio/flac");
  } else if (normalized == "vorbis") {
    pushUnique("audio/vorbis");
  } else if (normalized == "opus") {
    pushUnique("audio/opus");
  } else if (normalized == "pcm" || normalized == "pcm_s16le" || normalized == "pcm_s24le" ||
             normalized == "pcm_s32le" || normalized == "audio/raw") {
    pushUnique("audio/raw");
  } else if (normalized == "ac3" || normalized == "ac-3") {
    pushUnique("audio/ac3");
  } else if (normalized == "eac3" || normalized == "e-ac-3") {
    pushUnique("audio/eac3");
  } else if (normalized == "dts") {
    pushUnique("audio/vnd.dts");
  } else if (normalized == "dtshd" || normalized == "dts-hd" || normalized == "dts_hd") {
    pushUnique("audio/vnd.dts.hd");
  } else if (normalized == "truehd" || normalized == "true-hd") {
    pushUnique("audio/truehd");
  } else if (normalized == "ape") {
    pushUnique("audio/ape");
  } else if (normalized == "alac") {
    pushUnique("audio/alac");
  } else if (normalized == "vivid" || normalized == "audio vivid") {
    pushUnique("audio/audio-vivid");
  }

  return candidates;
}

static std::vector<std::string> BuildVideoMimeCandidates(const std::string &codecOrMime) {
  const std::string normalized = ToLowerString(codecOrMime);
  if (normalized.empty()) {
    return {};
  }

  std::vector<std::string> candidates;
  auto pushUnique = [&candidates](const std::string &candidate) {
    if (candidate.empty()) {
      return;
    }
    if (std::find(candidates.begin(), candidates.end(), candidate) == candidates.end()) {
      candidates.push_back(candidate);
    }
  };

  if (normalized.rfind("video/", 0) == 0) {
    pushUnique(normalized);
  }

  if (normalized == "h264" || normalized == "h.264" || normalized == "avc" || normalized == "x264") {
    pushUnique("video/avc");
  } else if (normalized == "h265" || normalized == "h.265" || normalized == "hevc" || normalized == "x265") {
    pushUnique("video/hevc");
  } else if (normalized == "av1" || normalized == "av01") {
    pushUnique("video/av1");
    pushUnique("video/av01");
  } else if (normalized == "vp9") {
    pushUnique("video/x-vnd.on2.vp9");
  } else if (normalized == "vp8") {
    pushUnique("video/x-vnd.on2.vp8");
  } else if (normalized == "mpeg4" || normalized == "mp4v" || normalized == "mp4v-es" ||
             normalized == "divx" || normalized == "xvid") {
    pushUnique("video/mp4v-es");
    pushUnique("video/divx");
  } else if (normalized == "mpeg2") {
    pushUnique("video/mpeg2");
  } else if (normalized == "vc1" || normalized == "wvc1") {
    pushUnique("video/vc1");
    pushUnique("video/wvc1");
  }

  return candidates;
}

static AudioDecoderCapabilityResult QueryAudioDecoderCapabilityInternal(const std::string &codecOrMime) {
  AudioDecoderCapabilityResult result;
  const std::vector<std::string> mimeCandidates = BuildAudioMimeCandidates(codecOrMime);
  if (mimeCandidates.empty()) {
    result.errorMessage = "unsupported codec mapping";
    return result;
  }

  result.capabilityKnown = true;
  result.mimeType = mimeCandidates.front();

  for (const std::string &mime : mimeCandidates) {
    OH_AVCapability *capability = OH_AVCodec_GetCapabilityByCategory(mime.c_str(), false, HARDWARE);
    bool isHardware = true;
    if (capability == nullptr) {
      capability = OH_AVCodec_GetCapabilityByCategory(mime.c_str(), false, SOFTWARE);
      isHardware = false;
    }
    if (capability == nullptr) {
      capability = OH_AVCodec_GetCapability(mime.c_str(), false);
      if (capability != nullptr) {
        isHardware = OH_AVCapability_IsHardware(capability);
      }
    }
    if (capability == nullptr) {
      continue;
    }

    result.supported = true;
    result.isHardware = isHardware;
    result.mimeType = mime;

    const char *decoderName = OH_AVCapability_GetName(capability);
    if (decoderName != nullptr) {
      result.decoderName = decoderName;
    }

    OH_AVRange channelRange;
    channelRange.minVal = 0;
    channelRange.maxVal = 0;
    if (OH_AVCapability_GetAudioChannelCountRange(capability, &channelRange) == AV_ERR_OK) {
      result.maxChannels = channelRange.maxVal;
    }
    return result;
  }

  result.errorMessage = "decoder not found";
  return result;
}

static VideoDecoderCapabilityResult QueryVideoDecoderCapabilityInternal(const std::string &codecOrMime) {
  VideoDecoderCapabilityResult result;
  const std::vector<std::string> mimeCandidates = BuildVideoMimeCandidates(codecOrMime);
  if (mimeCandidates.empty()) {
    result.errorMessage = "unsupported codec mapping";
    return result;
  }

  result.capabilityKnown = true;
  result.mimeType = mimeCandidates.front();

  for (const std::string &mime : mimeCandidates) {
    OH_AVCapability *capability = OH_AVCodec_GetCapabilityByCategory(mime.c_str(), false, HARDWARE);
    bool isHardware = true;
    if (capability == nullptr) {
      capability = OH_AVCodec_GetCapabilityByCategory(mime.c_str(), false, SOFTWARE);
      isHardware = false;
    }
    if (capability == nullptr) {
      capability = OH_AVCodec_GetCapability(mime.c_str(), false);
      if (capability != nullptr) {
        isHardware = OH_AVCapability_IsHardware(capability);
      }
    }
    if (capability == nullptr) {
      continue;
    }

    result.supported = true;
    result.isHardware = isHardware;
    result.mimeType = mime;

    const char *decoderName = OH_AVCapability_GetName(capability);
    if (decoderName != nullptr) {
      result.decoderName = decoderName;
    }

    result.maxInstances = OH_AVCapability_GetMaxSupportedInstances(capability);

    OH_AVRange widthRange;
    widthRange.minVal = 0;
    widthRange.maxVal = 0;
    if (OH_AVCapability_GetVideoWidthRange(capability, &widthRange) == AV_ERR_OK) {
      result.minWidth = widthRange.minVal;
      result.maxWidth = widthRange.maxVal;
    }

    OH_AVRange heightRange;
    heightRange.minVal = 0;
    heightRange.maxVal = 0;
    if (OH_AVCapability_GetVideoHeightRange(capability, &heightRange) == AV_ERR_OK) {
      result.minHeight = heightRange.minVal;
      result.maxHeight = heightRange.maxVal;
    }

    OH_AVRange frameRateRange;
    frameRateRange.minVal = 0;
    frameRateRange.maxVal = 0;
    if (OH_AVCapability_GetVideoFrameRateRange(capability, &frameRateRange) == AV_ERR_OK) {
      result.minFrameRate = frameRateRange.minVal;
      result.maxFrameRate = frameRateRange.maxVal;
    }

    int32_t widthAlignment = 0;
    if (OH_AVCapability_GetVideoWidthAlignment(capability, &widthAlignment) == AV_ERR_OK) {
      result.widthAlignment = widthAlignment;
    }

    int32_t heightAlignment = 0;
    if (OH_AVCapability_GetVideoHeightAlignment(capability, &heightAlignment) == AV_ERR_OK) {
      result.heightAlignment = heightAlignment;
    }
    return result;
  }

  // Fallback: capability API gave no result, try direct decoder creation.
  // On some HarmonyOS devices, OH_AVCodec_GetCapabilityByCategory returns null for HEVC
  // even though the decoder is actually available via OH_VideoDecoder_CreateByMime.
  for (const std::string &mime : mimeCandidates) {
    OH_AVCodec *testDecoder = OH_VideoDecoder_CreateByMime(mime.c_str());
    if (testDecoder != nullptr) {
      OH_VideoDecoder_Destroy(testDecoder);
      result.supported = true;
      result.mimeType = mime;
      result.decoderName = "";  // name unknown via creation probe
      // isHardware cannot be determined; caller should treat as "unknown"
      result.isHardware = false;
      result.errorMessage = "";
      OH_LOG_INFO(LOG_APP, "QueryVideoDecoderCapabilityInternal: capability API failed but creation probe succeeded for mime=%{public}s, marking supported=true isHardware=false", mime.c_str());
      return result;
    }
  }

  result.errorMessage = "decoder not found";
  return result;
}

static VideoDecoderSurfaceProbeResult ProbeVideoDecoderSurfaceInternal(
  NativePlayerSkeletonState &state,
  const std::string &codecOrMime
) {
  VideoDecoderSurfaceProbeResult result;
  result.stage = "lookup";

  OHNativeWindow *localWindow = nullptr;
  bool hasAvPlayer = false;
  bool hasFfmpegCtx = false;
  bool prepared = false;
  bool playing = false;
  bool useFfmpegPath = false;
  {
    std::lock_guard<std::mutex> lk(state.stateMutex);
    localWindow = state.nativeWindow;
    hasAvPlayer = state.avPlayer != nullptr;
    hasFfmpegCtx = state.ffmpegCtx != nullptr;
    prepared = state.prepared;
    playing = state.playing;
    useFfmpegPath = state.useFfmpegPath;
  }
  result.stateSummary =
    std::string("window=") + (localWindow != nullptr ? "ready" : "null") +
    ", prepared=" + (prepared ? "true" : "false") +
    ", playing=" + (playing ? "true" : "false") +
    ", avPlayer=" + (hasAvPlayer ? "true" : "false") +
    ", ffmpegCtx=" + (hasFfmpegCtx ? "true" : "false") +
    ", useFfmpegPath=" + (useFfmpegPath ? "true" : "false");
  if (localWindow == nullptr) {
    result.errorMessage = "nativeWindow unavailable";
    result.stage = "surface";
    return result;
  }

  const VideoDecoderCapabilityResult capability = QueryVideoDecoderCapabilityInternal(codecOrMime);
  result.capabilityKnown = capability.capabilityKnown;
  result.isHardware = capability.isHardware;
  result.decoderName = capability.decoderName;
  result.mimeType = capability.mimeType;
  if (!capability.capabilityKnown) {
    result.errorMessage = capability.errorMessage.empty() ? "capability unknown" : capability.errorMessage;
    return result;
  }
  if (!capability.supported) {
    result.errorMessage = "decoder not supported";
    return result;
  }
  if (!capability.isHardware) {
    result.errorMessage = "hardware decoder unavailable";
    return result;
  }
  if (capability.mimeType.empty()) {
    result.errorMessage = "empty mime type";
    return result;
  }

  OH_AVCodec *decoder = nullptr;
  OH_AVFormat *format = nullptr;
  OH_AVErrCode rc = AV_ERR_OK;
  if (!capability.decoderName.empty()) {
    decoder = OH_VideoDecoder_CreateByName(capability.decoderName.c_str());
  }
  if (decoder == nullptr) {
    decoder = OH_VideoDecoder_CreateByMime(capability.mimeType.c_str());
  }
  if (decoder == nullptr) {
    result.stage = "create";
    result.errorMessage = "create decoder failed";
    return result;
  }

  result.stage = "configure";
  format = OH_AVFormat_CreateVideoFormat(capability.mimeType.c_str(), 1920, 1080);
  if (format == nullptr) {
    result.errorMessage = "create video format failed";
    OH_VideoDecoder_Destroy(decoder);
    return result;
  }
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, 1920);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, 1080);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);

  rc = OH_VideoDecoder_Configure(decoder, format);
  if (rc != AV_ERR_OK) {
    result.errorMessage = "configure failed: " + std::to_string(static_cast<int32_t>(rc));
    OH_AVFormat_Destroy(format);
    OH_VideoDecoder_Destroy(decoder);
    return result;
  }

  result.stage = "setSurface";
  rc = OH_VideoDecoder_SetSurface(decoder, localWindow);
  if (rc != AV_ERR_OK) {
    result.errorMessage = "set surface failed: " + std::to_string(static_cast<int32_t>(rc));
    if (rc == AV_ERR_INVALID_STATE && (hasAvPlayer || hasFfmpegCtx || prepared || playing)) {
      result.errorMessage += " (surface may be occupied by current playback pipeline)";
    }
    OH_AVFormat_Destroy(format);
    OH_VideoDecoder_Destroy(decoder);
    return result;
  }

  result.stage = "prepare";
  rc = OH_VideoDecoder_Prepare(decoder);
  if (rc != AV_ERR_OK) {
    result.errorMessage = "prepare failed: " + std::to_string(static_cast<int32_t>(rc));
    OH_AVFormat_Destroy(format);
    OH_VideoDecoder_Destroy(decoder);
    return result;
  }

  result.success = true;
  result.stage = "done";
  OH_AVFormat_Destroy(format);
  OH_VideoDecoder_Destroy(decoder);
  return result;
}

static napi_value QueryAudioDecoderCapability(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "queryAudioDecoderCapability failed to read args");
    return nullptr;
  }
  if (argc < 1) {
    ThrowTypeError(env, "queryAudioDecoderCapability requires (codecOrMime)");
    return nullptr;
  }

  std::string codecOrMime;
  if (!ReadUtf8String(env, args[0], codecOrMime)) {
    ThrowTypeError(env, "queryAudioDecoderCapability codecOrMime must be string");
    return nullptr;
  }

  const AudioDecoderCapabilityResult capability = QueryAudioDecoderCapabilityInternal(codecOrMime);
  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    ThrowTypeError(env, "queryAudioDecoderCapability failed to create result object");
    return nullptr;
  }

  napi_value capabilityKnown = CreateBoolean(env, capability.capabilityKnown);
  napi_value supported = CreateBoolean(env, capability.supported);
  napi_value isHardware = CreateBoolean(env, capability.isHardware);
  napi_value maxChannels = CreateInt32(env, capability.maxChannels);
  napi_value decoderName = CreateString(env, capability.decoderName.c_str());
  napi_value mimeType = CreateString(env, capability.mimeType.c_str());
  napi_value errorMessage = CreateString(env, capability.errorMessage.c_str());
  if (capabilityKnown == nullptr || supported == nullptr || isHardware == nullptr ||
      maxChannels == nullptr || decoderName == nullptr || mimeType == nullptr || errorMessage == nullptr) {
    ThrowTypeError(env, "queryAudioDecoderCapability failed to create result fields");
    return nullptr;
  }

  if (napi_set_named_property(env, result, "capabilityKnown", capabilityKnown) != napi_ok ||
      napi_set_named_property(env, result, "supported", supported) != napi_ok ||
      napi_set_named_property(env, result, "isHardware", isHardware) != napi_ok ||
      napi_set_named_property(env, result, "maxChannels", maxChannels) != napi_ok ||
      napi_set_named_property(env, result, "decoderName", decoderName) != napi_ok ||
      napi_set_named_property(env, result, "mimeType", mimeType) != napi_ok ||
      napi_set_named_property(env, result, "errorMessage", errorMessage) != napi_ok) {
    ThrowTypeError(env, "queryAudioDecoderCapability failed to set result fields");
    return nullptr;
  }
  return result;
}

static napi_value QueryVideoDecoderCapability(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "queryVideoDecoderCapability failed to read args");
    return nullptr;
  }
  if (argc < 1) {
    ThrowTypeError(env, "queryVideoDecoderCapability requires (codecOrMime)");
    return nullptr;
  }

  std::string codecOrMime;
  if (!ReadUtf8String(env, args[0], codecOrMime)) {
    ThrowTypeError(env, "queryVideoDecoderCapability codecOrMime must be string");
    return nullptr;
  }

  const VideoDecoderCapabilityResult capability = QueryVideoDecoderCapabilityInternal(codecOrMime);
  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    ThrowTypeError(env, "queryVideoDecoderCapability failed to create result object");
    return nullptr;
  }

  napi_value capabilityKnown = CreateBoolean(env, capability.capabilityKnown);
  napi_value supported = CreateBoolean(env, capability.supported);
  napi_value isHardware = CreateBoolean(env, capability.isHardware);
  napi_value minWidth = CreateInt32(env, capability.minWidth);
  napi_value maxWidth = CreateInt32(env, capability.maxWidth);
  napi_value minHeight = CreateInt32(env, capability.minHeight);
  napi_value maxHeight = CreateInt32(env, capability.maxHeight);
  napi_value minFrameRate = CreateInt32(env, capability.minFrameRate);
  napi_value maxFrameRate = CreateInt32(env, capability.maxFrameRate);
  napi_value widthAlignment = CreateInt32(env, capability.widthAlignment);
  napi_value heightAlignment = CreateInt32(env, capability.heightAlignment);
  napi_value maxInstances = CreateInt32(env, capability.maxInstances);
  napi_value decoderName = CreateString(env, capability.decoderName.c_str());
  napi_value mimeType = CreateString(env, capability.mimeType.c_str());
  napi_value errorMessage = CreateString(env, capability.errorMessage.c_str());
  if (capabilityKnown == nullptr || supported == nullptr || isHardware == nullptr ||
      minWidth == nullptr || maxWidth == nullptr || minHeight == nullptr || maxHeight == nullptr ||
      minFrameRate == nullptr || maxFrameRate == nullptr || widthAlignment == nullptr ||
      heightAlignment == nullptr || maxInstances == nullptr || decoderName == nullptr ||
      mimeType == nullptr || errorMessage == nullptr) {
    ThrowTypeError(env, "queryVideoDecoderCapability failed to create result fields");
    return nullptr;
  }

  if (napi_set_named_property(env, result, "capabilityKnown", capabilityKnown) != napi_ok ||
      napi_set_named_property(env, result, "supported", supported) != napi_ok ||
      napi_set_named_property(env, result, "isHardware", isHardware) != napi_ok ||
      napi_set_named_property(env, result, "minWidth", minWidth) != napi_ok ||
      napi_set_named_property(env, result, "maxWidth", maxWidth) != napi_ok ||
      napi_set_named_property(env, result, "minHeight", minHeight) != napi_ok ||
      napi_set_named_property(env, result, "maxHeight", maxHeight) != napi_ok ||
      napi_set_named_property(env, result, "minFrameRate", minFrameRate) != napi_ok ||
      napi_set_named_property(env, result, "maxFrameRate", maxFrameRate) != napi_ok ||
      napi_set_named_property(env, result, "widthAlignment", widthAlignment) != napi_ok ||
      napi_set_named_property(env, result, "heightAlignment", heightAlignment) != napi_ok ||
      napi_set_named_property(env, result, "maxInstances", maxInstances) != napi_ok ||
      napi_set_named_property(env, result, "decoderName", decoderName) != napi_ok ||
      napi_set_named_property(env, result, "mimeType", mimeType) != napi_ok ||
      napi_set_named_property(env, result, "errorMessage", errorMessage) != napi_ok) {
    ThrowTypeError(env, "queryVideoDecoderCapability failed to set result fields");
    return nullptr;
  }
  return result;
}

static napi_value ProbeVideoDecoderSurface(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "probeVideoDecoderSurface failed to read args");
    return nullptr;
  }
  if (argc < 2) {
    ThrowTypeError(env, "probeVideoDecoderSurface requires (handle, codecOrMime)");
    return nullptr;
  }

  int32_t handle = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "probeVideoDecoderSurface handle must be int32");
    return nullptr;
  }
  std::string codecOrMime;
  if (!ReadUtf8String(env, args[1], codecOrMime)) {
    ThrowTypeError(env, "probeVideoDecoderSurface codecOrMime must be string");
    return nullptr;
  }

  NativePlayerSkeletonState *statePtr = FindPlayerOrThrow(env, handle);
  if (statePtr == nullptr) {
    return nullptr;
  }
  const VideoDecoderSurfaceProbeResult probe = ProbeVideoDecoderSurfaceInternal(*statePtr, codecOrMime);

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    ThrowTypeError(env, "probeVideoDecoderSurface failed to create result object");
    return nullptr;
  }
  napi_value success = CreateBoolean(env, probe.success);
  napi_value stage = CreateString(env, probe.stage.c_str());
  napi_value capabilityKnown = CreateBoolean(env, probe.capabilityKnown);
  napi_value isHardware = CreateBoolean(env, probe.isHardware);
  napi_value decoderName = CreateString(env, probe.decoderName.c_str());
  napi_value mimeType = CreateString(env, probe.mimeType.c_str());
  napi_value stateSummary = CreateString(env, probe.stateSummary.c_str());
  napi_value errorMessage = CreateString(env, probe.errorMessage.c_str());
  if (success == nullptr || stage == nullptr || capabilityKnown == nullptr || isHardware == nullptr ||
      decoderName == nullptr || mimeType == nullptr || stateSummary == nullptr || errorMessage == nullptr) {
    ThrowTypeError(env, "probeVideoDecoderSurface failed to create result fields");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "success", success) != napi_ok ||
      napi_set_named_property(env, result, "stage", stage) != napi_ok ||
      napi_set_named_property(env, result, "capabilityKnown", capabilityKnown) != napi_ok ||
      napi_set_named_property(env, result, "isHardware", isHardware) != napi_ok ||
      napi_set_named_property(env, result, "decoderName", decoderName) != napi_ok ||
      napi_set_named_property(env, result, "mimeType", mimeType) != napi_ok ||
      napi_set_named_property(env, result, "stateSummary", stateSummary) != napi_ok ||
      napi_set_named_property(env, result, "errorMessage", errorMessage) != napi_ok) {
    ThrowTypeError(env, "probeVideoDecoderSurface failed to set result fields");
    return nullptr;
  }
  return result;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
    { "createPlayer", nullptr, CreatePlayer, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setPreferredDecodePath", nullptr, SetPreferredDecodePath, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setAudioHardwareSafetyOffset", nullptr, SetAudioHardwareSafetyOffset, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setSource", nullptr, SetSource, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setDurationHint", nullptr, SetDurationHint, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setHeaders", nullptr, SetHeaders, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setXComponent", nullptr, SetXComponent, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "prepare", nullptr, Prepare, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "play", nullptr, Play, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "seek", nullptr, Seek, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "selectTrack", nullptr, SelectTrack, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "getCurrentTime", nullptr, GetCurrentTime, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "getDuration", nullptr, GetDuration, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setCallbacks", nullptr, SetCallbacks, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "ffprobe", nullptr, Ffprobe, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "ffmpegSelfCheck", nullptr, FfmpegSelfCheck, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "webdavRequest", nullptr, WebdavRequest, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "downloadToFile", nullptr, DownloadToFile, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "getNativeCapabilities", nullptr, GetNativeCapabilities, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "queryAudioDecoderCapability", nullptr, QueryAudioDecoderCapability, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "queryVideoDecoderCapability", nullptr, QueryVideoDecoderCapability, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "probeVideoDecoderSurface", nullptr, ProbeVideoDecoderSurface, nullptr, nullptr, nullptr, napi_default, nullptr }
  };
  if (napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors) != napi_ok) {
    ThrowTypeError(env, "failed to define native module properties");
    return nullptr;
  }

  // 修复 #48-A5: 在模块挂载期注册 XComponent 回调
  // 当 XComponent 使用 libraryname: 'vidall_core_player_napi' 时，HarmonyOS 在
  // surface 创建前调用 Init() 并将 OH_NATIVE_XCOMPONENT_OBJ 注入 exports。
  // 在此处注册回调，OnSurfaceCreated 就会在 surface 创建时正确触发，
  // 而不是等到 ArkTS onLoad 回调中的 SetXComponent() 时才注册（彼时 surface 已创建，
  // 不会补发 OnSurfaceCreated，导致 nativeWindow 永远是 nullptr）。
  napi_value xcExport = nullptr;
  napi_status xcStatus = napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcExport);
  if (xcStatus == napi_ok && xcExport != nullptr) {
    OH_NativeXComponent *nativeXC = nullptr;
    napi_unwrap(env, xcExport, reinterpret_cast<void **>(&nativeXC));
    if (nativeXC != nullptr) {
      OH_NativeXComponent_RegisterCallback(nativeXC, &s_xcCallback);
      g_pendingXC = nativeXC;
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "Init: 已在 XComponent 挂载期注册回调，等待 OnSurfaceCreated (nativeXC=%p)",
                   nativeXC);
    } else {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
                   "Init: OH_NATIVE_XCOMPONENT_OBJ 存在但 napi_unwrap 返回 nullptr");
    }
  } else {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "Init: 未检测到 OH_NATIVE_XCOMPONENT_OBJ（非 XComponent 绑定加载，属正常）");
  }

  return exports;
}

} // namespace

static napi_module vidallCorePlayerModule = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = Init,
  .nm_modname = "vidall_core_player_napi",
  .nm_priv = nullptr,
  .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterVidallCorePlayerModule(void) {
  napi_module_register(&vidallCorePlayerModule);
}
