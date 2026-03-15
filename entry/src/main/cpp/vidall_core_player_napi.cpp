#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/time.h>
}

#if !defined(VIDALL_HAS_LIBCURL)
#define VIDALL_HAS_LIBCURL 0
#endif

#if VIDALL_HAS_LIBCURL
#include <curl/curl.h>
#endif

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

struct NativePlayerSkeletonState {
  std::string url;
  std::string headersJson;
  std::string xComponentId;
  OHNativeWindow *nativeWindow = nullptr;  // 渲染目标 Surface，生命周期归 XComponent，不 retain/release
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
};

static std::unordered_map<int32_t, NativePlayerSkeletonState> g_players;
static int32_t g_nextHandle = 1;

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
  state.selectedTrackIndex = -1;
  state.currentTimeMs = 0;
  state.durationMs = 0;
  state.lastRealtimeMs = 0;
}

static napi_value CreatePlayer(napi_env env, napi_callback_info info) {
  (void)info;
  if (g_players.size() >= MAX_PLAYER_COUNT) {
    ThrowRangeError(env, "player count limit reached");
    return nullptr;
  }
  if (g_nextHandle <= 0) {
    ThrowRangeError(env, "player handle overflow");
    return nullptr;
  }
  const int32_t handle = g_nextHandle++;
  g_players[handle] = NativePlayerSkeletonState();
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
  // 注：SDK 无同步 GetNativeWindow API（旧路径 window 仅在 OnSurfaceCreated 回调中可得；
  //     新路径 OH_ArkUI_XComponent_GetNativeWindow 接受 SurfaceHolder*，非此处 unwrap 所得类型）。
  // nativeWindow 将由 A3 阶段的 surface-created 回调写入；此处只做合法性检查，不 crash。
  OH_NativeXComponent *nativeXC = nullptr;
  napi_unwrap(env, args[1], reinterpret_cast<void **>(&nativeXC));
  // nativeXC 有效则 state->nativeWindow 由后续回调赋值，否则降级为 nullptr（骨架兼容）
  state->nativeWindow = nullptr;

  // 切换渲染目标后重置骨架态，避免旧 prepared/时间轴状态延续到新 surface。
  ResetRuntimeState(*state);
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
    EmitBufferingChange(state, true);
  state.prepared = true;
  // Fire onPrepared synchronously on the current JS thread (skeleton behaviour)
  if (state.onPreparedRef != nullptr && state.callbackEnv != nullptr) {
    if (!CallJsFunction(state.callbackEnv, state.onPreparedRef, 0, nullptr)) {
      return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
    }
  }
  // Push initial timeline tick after prepared so controller/subtitle bridge can sync immediately.
  EmitTimeUpdate(state);
    EmitBufferingChange(state, false);
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
  if (state.playing) {
    // 幂等处理：已在播放态时忽略重复 play。
    return ReturnUndefinedOrThrow(env, "play failed to create return value");
  }
  state.playing = true;
  state.lastRealtimeMs = NowRealtimeMs();
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
  if (!state.playing) {
    // 幂等处理：已暂停时忽略重复 pause。
    return ReturnUndefinedOrThrow(env, "pause failed to create return value");
  }
  AdvancePlaybackClockIfNeeded(state);
  state.playing = false;
  state.lastRealtimeMs = 0;
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
  if (state.durationMs > 0 && positionMs > state.durationMs) {
    positionMs = state.durationMs;
  }
  state.currentTimeMs = positionMs;
  if (state.playing) {
    state.lastRealtimeMs = NowRealtimeMs();
  }
  EmitTimeUpdate(state);
  // Emit seekDone after confirming position; adapter uses this to fire onSeekDone
  // instead of relying on the synchronous call return.
  EmitSeekDone(state);
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
  auto iter = g_players.find(handle);
  if (iter == g_players.end()) {
    // 幂等处理：重复 release 直接视为成功。
    return ReturnUndefinedOrThrow(env, "release failed to create return value");
  }
  NativePlayerSkeletonState &state = iter->second;
  ResetRuntimeState(state);
  state.url.clear();
  state.headersJson.clear();
  state.xComponentId.clear();
  state.nativeWindow = nullptr;  // 只清引用，生命周期归 XComponent，不调用 release
  ClearCallbackRefs(state, env);
  state.callbackEnv = nullptr;
  g_players.erase(iter);
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

} // namespace

EXTERN_C_START
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
  return exports;
}
EXTERN_C_END

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