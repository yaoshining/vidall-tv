#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <thread>
#include <queue>
#include <condition_variable>
#include <atomic>

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/avplayer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <hilog/log.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>  // B4：PCM 格式转换（fltp/s16/etc → s16 for OH_AudioRenderer）
}

#if !defined(VIDALL_HAS_LIBCURL)
#define VIDALL_HAS_LIBCURL 0
#endif

#if VIDALL_HAS_LIBCURL
#include <curl/curl.h>
#endif

// B3：EGL + OpenGL ES 2.0（YUV 渲染管线）
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

// B4：OH_AudioRenderer（PCM 送显）
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

namespace {

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
      AppendJsonIntField(json, "width", codecpar->width, firstField);
      AppendJsonIntField(json, "height", codecpar->height, firstField);
      AppendJsonStringField(json, "r_frame_rate", RationalToString(stream->r_frame_rate), firstField);
      AppendJsonStringField(json, "avg_frame_rate", RationalToString(stream->avg_frame_rate), firstField);
      if (codecpar->bit_rate > 0) {
        AppendJsonStringField(json, "bit_rate", std::to_string(codecpar->bit_rate), firstField);
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

// FFmpeg 上下文：格式探测 + demux 线程 + 双队列
struct FfmpegContext {
  AVFormatContext *fmtCtx = nullptr;
  int videoStreamIdx = -1;
  int audioStreamIdx = -1;
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

  // B2：解码帧输出队列
  AVFrameQueue videoFrameQueue;
  AVFrameQueue audioFrameQueue;

  // B3：EGL 上下文（只在渲染线程内操作）
  EGLDisplay eglDisplay = EGL_NO_DISPLAY;
  EGLSurface eglSurface = EGL_NO_SURFACE;
  EGLContext eglContext = EGL_NO_CONTEXT;

  // B3：OpenGL ES 资源（在渲染线程 makeCurrent 后初始化）
  GLuint yuvProgram = 0;   // YUV→RGB GLSL program
  GLuint textureY = 0;     // Y 分量纹理（GL_LUMINANCE，width×height）
  GLuint textureU = 0;     // U 分量纹理（GL_LUMINANCE，width/2×height/2）
  GLuint textureV = 0;     // V 分量纹理（GL_LUMINANCE，width/2×height/2）
  GLuint quadVBO = 0;      // 全屏四边形顶点缓冲

  // B3：渲染线程
  std::thread renderThread;
  std::atomic<bool> renderRunning{false};

  // B4：音频渲染（OH_AudioRenderer，回调模型，由音频系统线程驱动）
  OH_AudioRenderer *audioRenderer = nullptr;
  OH_AudioStreamBuilder *audioBuilder = nullptr;
  SwrContext *swrCtx = nullptr;          // libswresample 重采样上下文（源格式 → stereo S16 48kHz）
  std::vector<int16_t> pcmLeftover;      // swr_convert 溢出缓冲：跨 callback 的剩余 PCM 数据

  // B5：音频时钟（主时钟）
  std::atomic<int64_t> audioPtsSamples{0};  // 已渲染的音频样本数（stereo stereo 计数，swr 输出 48kHz）
  int audioSampleRate{0};                    // swr 输出采样率（48000），FfmpegInitSwr 后固定

  // B5：seek 请求（Seek() NAPI 写入，DemuxThreadFunc 消费）
  std::atomic<bool> seekRequested{false};
  std::atomic<int64_t> seekTargetMs{-1};

  // B5：反向指针，供 DemuxThreadFunc 发出 seekDone TSF；生命周期安全（state 独占拥有 ffmpegCtx）
  NativePlayerSkeletonState *ownerState{nullptr};
};

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
  // A4：threadsafe function handles（媒体线程 → JS 线程回调）
  napi_threadsafe_function tsfOnPrepared = nullptr;
  napi_threadsafe_function tsfOnCompleted = nullptr;
  napi_threadsafe_function tsfOnTimeUpdate = nullptr;
  napi_threadsafe_function tsfOnError = nullptr;
  // PR#49 修复：新增 buffering=false 和 seekDone TSF，供媒体线程异步触发
  napi_threadsafe_function tsfOnBufferingFalse = nullptr;
  napi_threadsafe_function tsfOnSeekDone = nullptr;
  // PR#49 修复（问题6）：per-player mutex，保护 state 字段的跨线程读写
  // 注意：std::mutex 不可拷贝/移动；unordered_map 通过节点指针操作，不需要拷贝值
  std::mutex stateMutex;
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
  // A4：释放 threadsafe functions（abort 确保已入队的回调不再执行，防止 Release 后悬挂访问）
  ReleaseTsfIfPresent(state.tsfOnPrepared);
  ReleaseTsfIfPresent(state.tsfOnCompleted);
  ReleaseTsfIfPresent(state.tsfOnTimeUpdate);
  ReleaseTsfIfPresent(state.tsfOnError);
  // PR#49：新增两个 TSF
  ReleaseTsfIfPresent(state.tsfOnBufferingFalse);
  ReleaseTsfIfPresent(state.tsfOnSeekDone);
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

// ---------------------------------------------------------------------------
// B1：FFmpeg demux 路径辅助函数
// ---------------------------------------------------------------------------

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
  ctx->audioStreamIdx = av_find_best_stream(ctx->fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegOpenInput: url=%s videoIdx=%d audioIdx=%d",
               url.c_str(), ctx->videoStreamIdx, ctx->audioStreamIdx);
  return 0;
}

// ---------------------------------------------------------------------------
// B5：音频时钟辅助（主时钟，单位：秒）
// ---------------------------------------------------------------------------

static double AudioClock(const FfmpegContext *ctx) {
  if (ctx->audioSampleRate <= 0) return 0.0;
  return static_cast<double>(ctx->audioPtsSamples.load(std::memory_order_relaxed))
         / static_cast<double>(ctx->audioSampleRate);
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

  // 清空 swr 溢出缓冲（避免 seek 后播放旧数据）
  ctx->pcmLeftover.clear();
}

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
    // B5：检查 seek 请求（由 Seek() NAPI 设置，在 demux 线程消费以保证 avformat 线程安全）
    if (ctx->seekRequested.exchange(false)) {
      const int64_t targetMs = ctx->seekTargetMs.load();
      const int64_t targetUs = targetMs * 1000LL;  // AV_TIME_BASE = 1e6
      av_seek_frame(ctx->fmtCtx, -1, targetUs, AVSEEK_FLAG_BACKWARD);
      // 清空所有 packet/frame 队列（旧数据）
      FlushFfmpegQueues(ctx);
      // 刷新解码器内部缓冲区
      if (ctx->videoCodecCtx != nullptr) avcodec_flush_buffers(ctx->videoCodecCtx);
      if (ctx->audioCodecCtx != nullptr) avcodec_flush_buffers(ctx->audioCodecCtx);
      // 重置音频时钟（seek 后从新位置重新计时）
      ctx->audioPtsSamples.store(0, std::memory_order_relaxed);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                   "DemuxThread: seeked to %lld ms", static_cast<long long>(targetMs));
      // 发出 seekDone TSF 通知 ArkTS
      if (ctx->ownerState != nullptr) {
        NativePlayerSkeletonState *st = ctx->ownerState;
        std::lock_guard<std::mutex> lk(st->stateMutex);
        st->currentTimeMs = targetMs;
      }
      if (ctx->ownerState != nullptr && ctx->ownerState->tsfOnSeekDone != nullptr) {
        napi_call_threadsafe_function(ctx->ownerState->tsfOnSeekDone, nullptr, napi_tsfn_nonblocking);
      }
    }

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
    } else if (pkt->stream_index == ctx->audioStreamIdx && ctx->audioStreamIdx >= 0) {
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
  // 视频解码器
  if (ctx->videoStreamIdx >= 0) {
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
    // 多线程解码（frame-level），TV 端多核可充分利用
    ctx->videoCodecCtx->thread_count = 2;
    ctx->videoCodecCtx->thread_type = FF_THREAD_FRAME;
    ret = avcodec_open2(ctx->videoCodecCtx, codec, nullptr);
    if (ret < 0) {
      avcodec_free_context(&ctx->videoCodecCtx);
      return ret;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "FfmpegInitCodecs: video decoder opened: %s %dx%d",
                 codec->name, ctx->videoCodecCtx->width, ctx->videoCodecCtx->height);
  }

  // 音频解码器
  if (ctx->audioStreamIdx >= 0) {
    AVStream *as = ctx->fmtCtx->streams[ctx->audioStreamIdx];
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
    int ret = avcodec_send_packet(ctx->videoCodecCtx, pkt);
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
      ret = avcodec_receive_frame(ctx->videoCodecCtx, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        break;
      }
      if (ret < 0) {
        break;
      }

      // 将帧移入 videoFrameQueue（背压等待，防止解码过快撑爆内存）
      AVFrame *frameCopy = av_frame_alloc();
      if (frameCopy) {
        av_frame_move_ref(frameCopy, frame);
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
    }
  }

  av_frame_free(&frame);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VideoDecodeThread: exited");
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
    int ret = avcodec_send_packet(ctx->audioCodecCtx, pkt);
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
      ret = avcodec_receive_frame(ctx->audioCodecCtx, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        break;
      }
      if (ret < 0) {
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

// ---------------------------------------------------------------------------
// B2：启动/停止解码线程
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// B3：GLSL shader 字符串（YUV420P → RGB，mediump float）
// ---------------------------------------------------------------------------

static const char *kVertexShaderSrc = R"(
attribute vec4 a_position;
attribute vec2 a_texCoord;
varying vec2 v_texCoord;
void main() {
    gl_Position = a_position;
    v_texCoord = a_texCoord;
}
)";

static const char *kFragmentShaderSrc = R"(
precision mediump float;
uniform sampler2D u_textureY;
uniform sampler2D u_textureU;
uniform sampler2D u_textureV;
varying vec2 v_texCoord;
void main() {
    float y = texture2D(u_textureY, v_texCoord).r;
    float u = texture2D(u_textureU, v_texCoord).r - 0.5;
    float v = texture2D(u_textureV, v_texCoord).r - 0.5;
    float r = y + 1.402 * v;
    float g = y - 0.344136 * u - 0.714136 * v;
    float b = y + 1.772 * u;
    gl_FragColor = vec4(r, g, b, 1.0);
}
)";

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
                 "FfmpegInitEGL: eglInitialize failed err=0x%x", eglGetError());
    return false;
  }
  EGLint attribs[] = {
      EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
      EGL_RED_SIZE,   8,
      EGL_GREEN_SIZE, 8,
      EGL_BLUE_SIZE,  8,
      EGL_NONE
  };
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (!eglChooseConfig(ctx->eglDisplay, attribs, &config, 1, &numConfigs) ||
      numConfigs == 0) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglChooseConfig failed err=0x%x", eglGetError());
    return false;
  }
  ctx->eglSurface = eglCreateWindowSurface(
      ctx->eglDisplay, config,
      reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
  if (ctx->eglSurface == EGL_NO_SURFACE) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglCreateWindowSurface failed err=0x%x", eglGetError());
    return false;
  }
  EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  ctx->eglContext =
      eglCreateContext(ctx->eglDisplay, config, EGL_NO_CONTEXT, ctxAttribs);
  if (ctx->eglContext == EGL_NO_CONTEXT) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitEGL: eglCreateContext failed err=0x%x", eglGetError());
    return false;
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitEGL: OK EGL %d.%d", major, minor);
  return true;
}

// ---------------------------------------------------------------------------
// B3：shader 编译辅助
// ---------------------------------------------------------------------------

static GLuint CompileShader(GLenum type, const char *src) {
  const GLuint shader = glCreateShader(type);
  if (shader == 0) {
    return 0;
  }
  glShaderSource(shader, 1, &src, nullptr);
  glCompileShader(shader);
  GLint status = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
  if (status == GL_FALSE) {
    GLint len = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &len);
    if (len > 1) {
      std::string log(static_cast<size_t>(len), '\0');
      glGetShaderInfoLog(shader, len, nullptr, &log[0]);
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                   "CompileShader: type=%u err: %s", type, log.c_str());
    }
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

// ---------------------------------------------------------------------------
// B3：GL 资源初始化（在渲染线程 makeCurrent 后调用）
// ---------------------------------------------------------------------------

static bool FfmpegInitGLResources(FfmpegContext *ctx) {
  // 1. 编译 & 链接 YUV→RGB program
  const GLuint vs = CompileShader(GL_VERTEX_SHADER, kVertexShaderSrc);
  const GLuint fs = CompileShader(GL_FRAGMENT_SHADER, kFragmentShaderSrc);
  if (vs == 0 || fs == 0) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitGLResources: shader compile failed");
    if (vs != 0) { glDeleteShader(vs); }
    if (fs != 0) { glDeleteShader(fs); }
    return false;
  }
  ctx->yuvProgram = glCreateProgram();
  glAttachShader(ctx->yuvProgram, vs);
  glAttachShader(ctx->yuvProgram, fs);
  glBindAttribLocation(ctx->yuvProgram, 0, "a_position");
  glBindAttribLocation(ctx->yuvProgram, 1, "a_texCoord");
  glLinkProgram(ctx->yuvProgram);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint linked = 0;
  glGetProgramiv(ctx->yuvProgram, GL_LINK_STATUS, &linked);
  if (linked == GL_FALSE) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "FfmpegInitGLResources: program link failed");
    glDeleteProgram(ctx->yuvProgram);
    ctx->yuvProgram = 0;
    return false;
  }

  // 2. 绑定 sampler uniform（GL_TEXTURE0=Y, GL_TEXTURE1=U, GL_TEXTURE2=V）
  glUseProgram(ctx->yuvProgram);
  glUniform1i(glGetUniformLocation(ctx->yuvProgram, "u_textureY"), 0);
  glUniform1i(glGetUniformLocation(ctx->yuvProgram, "u_textureU"), 1);
  glUniform1i(glGetUniformLocation(ctx->yuvProgram, "u_textureV"), 2);

  // 3. 创建 Y/U/V 三张 GL_LUMINANCE 纹理（实际尺寸由第一帧决定）
  glGenTextures(1, &ctx->textureY);
  glGenTextures(1, &ctx->textureU);
  glGenTextures(1, &ctx->textureV);
  const GLuint textures[3] = {ctx->textureY, ctx->textureU, ctx->textureV};
  for (const GLuint tex : textures) {
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  glBindTexture(GL_TEXTURE_2D, 0);

  // 4. 全屏四边形 VBO（triangle strip，x/y 为 NDC，s/t 为 UV）
  // 顺序：左下、右下、左上、右上（匹配 UV 坐标 y 从下往上）
  const float quadVertices[] = {
      -1.0f, -1.0f,  0.0f, 1.0f,
       1.0f, -1.0f,  1.0f, 1.0f,
      -1.0f,  1.0f,  0.0f, 0.0f,
       1.0f,  1.0f,  1.0f, 0.0f,
  };
  glGenBuffers(1, &ctx->quadVBO);
  glBindBuffer(GL_ARRAY_BUFFER, ctx->quadVBO);
  glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(sizeof(quadVertices)),
               quadVertices, GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "FfmpegInitGLResources: OK prog=%u Y=%u U=%u V=%u vbo=%u",
               ctx->yuvProgram, ctx->textureY, ctx->textureU, ctx->textureV,
               ctx->quadVBO);
  return true;
}

// ---------------------------------------------------------------------------
// B3：GL 资源释放（在渲染线程内、eglMakeCurrent 有效时调用）
// ---------------------------------------------------------------------------

static void FfmpegCleanupGLResources(FfmpegContext *ctx) {
  if (ctx->quadVBO != 0) {
    glDeleteBuffers(1, &ctx->quadVBO);
    ctx->quadVBO = 0;
  }
  if (ctx->textureY != 0) {
    glDeleteTextures(1, &ctx->textureY);
    ctx->textureY = 0;
  }
  if (ctx->textureU != 0) {
    glDeleteTextures(1, &ctx->textureU);
    ctx->textureU = 0;
  }
  if (ctx->textureV != 0) {
    glDeleteTextures(1, &ctx->textureV);
    ctx->textureV = 0;
  }
  if (ctx->yuvProgram != 0) {
    glDeleteProgram(ctx->yuvProgram);
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

  // 1. EGL 初始化（创建 display/surface/context）
  if (!FfmpegInitEGL(ctx, state->nativeWindow)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: FfmpegInitEGL failed, exit");
    ctx->renderRunning.store(false);
    return;
  }

  // 2. 将 EGL context 绑定到当前线程
  if (!eglMakeCurrent(ctx->eglDisplay, ctx->eglSurface,
                      ctx->eglSurface, ctx->eglContext)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "RenderThreadFunc: eglMakeCurrent failed err=0x%x", eglGetError());
    ctx->renderRunning.store(false);
    return;
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

  // B5：时间上报节流（每 200ms 通过 tsfOnTimeUpdate 上报一次播放位置）
  auto lastEmitTime = std::chrono::steady_clock::now() - std::chrono::seconds(1);

  while (ctx->renderRunning.load()) {
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
      const double videoPts = (frame->pts != AV_NOPTS_VALUE)
          ? frame->pts * av_q2d(ctx->fmtCtx->streams[ctx->videoStreamIdx]->time_base)
          : 0.0;
      const double audioClock = AudioClock(ctx);
      const double diff = videoPts - audioClock;

      if (diff > 0.1) {
        // 视频超前音频 100ms 以上：等待音频跟上，最多等 500ms
        const int sleepMs = static_cast<int>(std::min(diff * 1000.0, 500.0));
        std::this_thread::sleep_for(std::chrono::milliseconds(sleepMs));
      } else if (diff < -0.5) {
        // 视频落后音频 500ms 以上：丢弃此帧（追帧）
        av_frame_free(&frame);
        continue;
      }

      // B5：每 200ms 上报一次播放位置给 ArkTS（以音频时钟为准）
      const auto now = std::chrono::steady_clock::now();
      if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastEmitTime).count() >= 200) {
        lastEmitTime = now;
        const int64_t posMs = static_cast<int64_t>(audioClock * 1000.0);
        {
          std::lock_guard<std::mutex> lk(state->stateMutex);
          state->currentTimeMs = posMs;
        }
        if (state->tsfOnTimeUpdate != nullptr) {
          napi_call_threadsafe_function(state->tsfOnTimeUpdate, nullptr, napi_tsfn_nonblocking);
        }
      }
    }

    // 5. 上传 YUV420P → 3 张 GL_LUMINANCE 纹理
    const int w = frame->width;
    const int h = frame->height;
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, ctx->textureY);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, w, h, 0,
                 GL_LUMINANCE, GL_UNSIGNED_BYTE, frame->data[0]);

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, ctx->textureU);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, w / 2, h / 2, 0,
                 GL_LUMINANCE, GL_UNSIGNED_BYTE, frame->data[1]);

    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, ctx->textureV);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, w / 2, h / 2, 0,
                 GL_LUMINANCE, GL_UNSIGNED_BYTE, frame->data[2]);

    // 6. 用 YUV program 绘制全屏 quad（triangle strip，4 顶点）
    glUseProgram(ctx->yuvProgram);
    glBindBuffer(GL_ARRAY_BUFFER, ctx->quadVBO);
    const GLsizei stride = static_cast<GLsizei>(4 * sizeof(float));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride,
                          reinterpret_cast<const void *>(0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride,
                          reinterpret_cast<const void *>(2 * sizeof(float)));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    // 7. 提交帧到屏幕
    eglSwapBuffers(ctx->eglDisplay, ctx->eglSurface);

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
  if (ctx == nullptr || ctx->swrCtx == nullptr || audioData == nullptr || audioDataSize <= 0) {
    if (audioData != nullptr && audioDataSize > 0) {
      memset(audioData, 0, static_cast<size_t>(audioDataSize));
    }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
  }

  auto *dst = static_cast<int16_t *>(audioData);
  // stereo S16：每帧 = 2 声道 × 2 字节 = 4 字节
  const int samplesNeeded = audioDataSize / static_cast<int>(2 * sizeof(int16_t));
  int samplesFilled = 0;

  // ── 步骤 1：先消费上一次 swr_convert 的溢出缓冲 ──────────────────────────
  if (!ctx->pcmLeftover.empty()) {
    // pcmLeftover 存储 interleaved stereo s16：每个 "样本" 占 2 个 int16_t（L+R）
    const int leftoverSamples = static_cast<int>(ctx->pcmLeftover.size()) / 2;
    const int toCopy = std::min(leftoverSamples, samplesNeeded);
    memcpy(dst, ctx->pcmLeftover.data(),
           static_cast<size_t>(toCopy) * 2 * sizeof(int16_t));
    samplesFilled += toCopy;
    if (toCopy < leftoverSamples) {
      ctx->pcmLeftover.erase(ctx->pcmLeftover.begin(),
                             ctx->pcmLeftover.begin() + toCopy * 2);
    } else {
      ctx->pcmLeftover.clear();
    }
  }

  // ── 步骤 2：从 audioFrameQueue 拉帧，swr_convert → 填充 dst ──────────────
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
      // 通知解码线程队列有空位
      ctx->audioFrameQueue.cv.notify_all();
    } else {
      // 无可用帧：填充静音，避免 underrun 杂音
      memset(dst + samplesFilled * 2, 0,
             static_cast<size_t>(samplesNeeded - samplesFilled) * 2 * sizeof(int16_t));
      samplesFilled = samplesNeeded;
      break;
    }

    // swr_convert 输出缓冲：预留 frame->nb_samples + resampler 延迟余量
    const int maxOut = frame->nb_samples + 256;
    std::vector<int16_t> tempBuf(static_cast<size_t>(maxOut * 2));
    uint8_t *outPtr = reinterpret_cast<uint8_t *>(tempBuf.data());
    // frame->data 是 uint8_t*[AV_NUM_DATA_POINTERS]，swr_convert 要求 const uint8_t** 输入
    // 通过临时数组规避 C++ 对 T** → const T** 的类型安全限制
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

    if (converted > toCopy) {
      // 多余样本存入溢出缓冲，下次 callback 优先消费
      ctx->pcmLeftover.insert(ctx->pcmLeftover.end(),
                              tempBuf.begin() + toCopy * 2,
                              tempBuf.begin() + converted * 2);
    }
  }

  // B5：更新音频时钟（本次 callback 共输出 samplesNeeded 个样本）
  ctx->audioPtsSamples.fetch_add(static_cast<int64_t>(samplesNeeded), std::memory_order_relaxed);

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

static void StartFfmpegAudio(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();
  if (ctx->audioCodecCtx == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "StartFfmpegAudio: no audio stream, skip");
    return;
  }

  if (!FfmpegInitSwr(ctx)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegAudio: FfmpegInitSwr failed");
    return;
  }

  if (!FfmpegInitAudioRenderer(ctx)) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegAudio: FfmpegInitAudioRenderer failed");
    swr_free(&ctx->swrCtx);
    return;
  }

  const OH_AudioStream_Result result = OH_AudioRenderer_Start(ctx->audioRenderer);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StartFfmpegAudio: OH_AudioRenderer_Start result=%d", result);
}

static void StopFfmpegAudio(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();

  // 1. 停止并释放 renderer（调用后音频系统不再调用 callback，消费者安全关闭）
  if (ctx->audioRenderer != nullptr) {
    OH_AudioRenderer_Stop(ctx->audioRenderer);
    OH_AudioRenderer_Release(ctx->audioRenderer);
    ctx->audioRenderer = nullptr;
  }

  // 2. 销毁 builder
  if (ctx->audioBuilder != nullptr) {
    OH_AudioStreamBuilder_Destroy(ctx->audioBuilder);
    ctx->audioBuilder = nullptr;
  }

  // 3. 释放 SwrContext
  if (ctx->swrCtx != nullptr) {
    swr_free(&ctx->swrCtx);
  }

  // 4. 清空溢出缓冲
  ctx->pcmLeftover.clear();

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StopFfmpegAudio: renderer stopped and released");
}

// B4 函数已在上方完整定义，此处无需重复前向声明

static void StartFfmpegDecode(NativePlayerSkeletonState *state) {
  if (state == nullptr || state->ffmpegCtx == nullptr) {
    return;
  }
  FfmpegContext *ctx = state->ffmpegCtx.get();

  // 初始化解码器
  const int ret = FfmpegInitCodecs(ctx);
  if (ret < 0) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegDecode: FfmpegInitCodecs failed: %s", errbuf);
    return;
  }

  // 记录媒体信息（供 ArkTS onPrepared 读取）
  if (ctx->videoStreamIdx >= 0 && ctx->videoCodecCtx != nullptr) {
    state->ffmpegWidth = ctx->videoCodecCtx->width;
    state->ffmpegHeight = ctx->videoCodecCtx->height;
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
  if (ctx->videoCodecCtx != nullptr) {
    ctx->videoDecodeThread = std::thread(VideoDecodeThreadFunc, ctx);
  }
  if (ctx->audioCodecCtx != nullptr) {
    ctx->audioDecodeThread = std::thread(AudioDecodeThreadFunc, ctx);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "StartFfmpegDecode: decode threads launched");

  // B4：解码器就绪后启动 OH_AudioRenderer（消费 audioFrameQueue）
  StartFfmpegAudio(state);

  // B3：启动 OpenGL ES YUV 渲染线程（消费 videoFrameQueue）
  StartFfmpegRender(state);

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

  // 4. Join 解码线程
  if (ctx->videoDecodeThread.joinable()) {
    ctx->videoDecodeThread.join();
  }
  if (ctx->audioDecodeThread.joinable()) {
    ctx->audioDecodeThread.join();
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

  // 6. 释放解码器上下文
  if (ctx->videoCodecCtx != nullptr) {
    avcodec_free_context(&ctx->videoCodecCtx);
  }
  if (ctx->audioCodecCtx != nullptr) {
    avcodec_free_context(&ctx->audioCodecCtx);
  }

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "StopFfmpegDecode: decode stopped and cleaned");
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
  ctx->httpHeaders = BuildFfmpegHeadersFromJson(state->headersJson);

  const int ret = FfmpegOpenInput(ctx.get(), url);
  if (ret < 0) {
    char errbuf[128] = {0};
    av_strerror(ret, errbuf, sizeof(errbuf));
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll",
                 "StartFfmpegDemux: FfmpegOpenInput failed: %s", errbuf);
    return;
  }

  // B5：设置反向指针，供 DemuxThreadFunc 发出 seekDone TSF
  ctx->ownerState = state;

  ctx->demuxRunning.store(true);
  ctx->demuxThread = std::thread(DemuxThreadFunc, ctx.get());
  state->ffmpegCtx = std::move(ctx);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
               "StartFfmpegDemux: demux thread launched for url=%s", url.c_str());

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

  // B2：先停止解码线程（依赖 packet 队列），再停止 demux
  StopFfmpegDecode(state);

  // 1. 通知中断：让阻塞的 av_read_frame / avformat_open_input 尽快返回
  ctx->interruptFlag.store(true);
  ctx->demuxRunning.store(false);
  // B5：清除 ownerState 反向指针，防止 join 后悬挂访问（demux 线程循环已由 demuxRunning=false 终止）
  ctx->ownerState = nullptr;

  // 2. 唤醒可能阻塞在 cv.wait 的 demux 线程（队列满等待）
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

  // 3. 等待 demux 线程退出
  if (ctx->demuxThread.joinable()) {
    ctx->demuxThread.join();
  }

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
    state->useFfmpegPath = true;
    const std::string urlCopy = state->url; // OnAVPlayerErrorCB 来自媒体线程，避免持有 state 太久
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
                 "OnAVPlayerErrorCB: switching to FFmpeg demux path for url=%s", urlCopy.c_str());
    // StartFfmpegDemux 内部会 avformat_open_input（可能阻塞），
    // 在媒体线程直接调用会影响 OH_AVPlayer 回调链路。
    // B1 阶段直接在此线程启动（open 有 10s 超时保障），B2 阶段可改为独立 dispatch 线程。
    StartFfmpegDemux(state, urlCopy);
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
  if (state->avPlayer != nullptr) {
    OH_AVPlayer_Stop(state->avPlayer);
    OH_AVPlayer_Release(state->avPlayer);
    state->avPlayer = nullptr;
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
  size_t argc = 7;
  napi_value args[7] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "setCallbacks failed to read args");
    return nullptr;
  }
  if (argc < 5) {
    ThrowTypeError(env,
      "setCallbacks requires (handle, onPrepared, onError, onTimeUpdate, onCompleted[, onBufferingChange[, onSeekDone]])");
    return nullptr;
  }
  int32_t handle = 0;
  const bool hasBufferingArg = (argc >= 6);
  const bool hasSeekDoneArg = (argc >= 7);
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
    AdvancePlaybackClockIfNeeded(state);
    state.playing = false;
    state.lastRealtimeMs = 0;
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
    state.ffmpegCtx->seekTargetMs.store(positionMs);
    state.ffmpegCtx->seekRequested.store(true);
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
  // Skeleton stage: cache selected track index only.
  state.selectedTrackIndex = trackIndex;
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
  if (state.avPlayer != nullptr) {
    OH_AVPlayer_Stop(state.avPlayer);
    OH_AVPlayer_Release(state.avPlayer); // 阻塞直到媒体线程所有回调执行完毕
    state.avPlayer = nullptr;
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

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
    { "createPlayer", nullptr, CreatePlayer, nullptr, nullptr, nullptr, napi_default, nullptr },
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
    { "getNativeCapabilities", nullptr, GetNativeCapabilities, nullptr, nullptr, nullptr, napi_default, nullptr }
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