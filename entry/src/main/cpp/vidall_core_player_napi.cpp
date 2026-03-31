#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <algorithm>
#include <cctype>
#include <climits>
#include <thread>
#include <atomic>

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/avplayer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#ifdef VIDALL_HAS_VPE
#include <multimedia/video_processing_engine/video_processing.h>
#include <multimedia/video_processing_engine/video_processing_types.h>
#endif // VIDALL_HAS_VPE
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
#include <libswscale/swscale.h>
}

#if !defined(VIDALL_HAS_LIBCURL)
#define VIDALL_HAS_LIBCURL 0
#endif

#if VIDALL_HAS_LIBCURL
#include <curl/curl.h>
#endif

#if !defined(VIDALL_HAS_LIBSMB2)
#define VIDALL_HAS_LIBSMB2 0
#endif

// POSIX socket/poll 头文件：smbDiscoverHosts 不依赖 libsmb2，始终需要
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>

#if VIDALL_HAS_LIBSMB2
#include <smb2/smb2.h>       // 必须先于 libsmb2.h：定义 SMB2_GUID_SIZE / smb2_lease_key
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include <smb2/libsmb2-dcerpc-srvsvc.h>
#include <cstring>
#endif

namespace {

// ============================================================================
// SMB URL components – filled by ParseSmbUrl()
// ============================================================================
struct SmbUrlComponents {
    std::string host;
    int         port     = 445;
    std::string user;
    std::string password;
    std::string share;
    std::string subPath;  // file path within share, no leading /
    bool        valid    = false;
};

// ============================================================================
// SmbAVIOContext – opaque passed to the custom AVIOContext read/seek callbacks
// ============================================================================
struct SmbAVIOContext {
    struct smb2_context *smb2     = nullptr;
    struct smb2fh       *fh       = nullptr;
    int64_t              fileSize = 0;
};

// ============================================================================
// SMB URL helpers – ParseSmbUrl() used by HTTP proxy and future AVIO path
// ============================================================================

// URL percent-decode: "%XX" → byte
static std::string PercentDecode(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ) {
        if (s[i] == '%' && i + 2 < s.size() &&
            std::isxdigit((unsigned char)s[i+1]) &&
            std::isxdigit((unsigned char)s[i+2])) {
            char hex[3] = { s[i+1], s[i+2], '\0' };
            out += static_cast<char>(std::strtol(hex, nullptr, 16));
            i += 3;
        } else {
            out += s[i++];
        }
    }
    return out;
}

// URL percent-encode a single path segment (must NOT contain '/').
// Encodes all bytes except RFC 3986 unreserved characters (A-Z a-z 0-9 - _ . ~).
// Used to build the HTTP proxy URL so that OH_AVPlayer/FFmpeg can see the file
// extension and determine the media format correctly.
static std::string PercentEncodePathSegment(const std::string &s) {
    static const char kHex[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(s.size() * 3);
    for (unsigned char c : s) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += kHex[(c >> 4) & 0x0F];
            out += kHex[c & 0x0F];
        }
    }
    return out;
}

// URL percent-encode a path that may contain '/' separators.
// Each slash-separated segment is encoded individually; '/' is preserved as-is.
// Example: "中文/file name.mp4" → "%E4%B8%AD%E6%96%87/file%20name.mp4"
static std::string PercentEncodePath(const std::string &path) {
    std::string out;
    out.reserve(path.size() * 3);
    std::string seg;
    for (char c : path) {
        if (c == '/') {
            out += PercentEncodePathSegment(seg);
            out += '/';
            seg.clear();
        } else {
            seg += c;
        }
    }
    out += PercentEncodePathSegment(seg);
    return out;
}

// Parse smb://[user[:pass]@]host[:port]/share[/subPath]
static SmbUrlComponents ParseSmbUrl(const std::string &url) {
    SmbUrlComponents c;
    const std::string prefix = "smb://";
    if (url.size() <= prefix.size() || url.compare(0, prefix.size(), prefix) != 0) return c;
    std::string rest = url.substr(prefix.size());

    // Extract user[:pass]@
    // RFC 3986: userinfo 结束于第一个 '@'，用 find 而非 rfind，
    // 防止密码中含 '@'（如 smb://user:p@ss@host/share）时解析错误。
    auto atPos = rest.find('@');
    if (atPos != std::string::npos) {
        std::string userInfo = rest.substr(0, atPos);
        rest = rest.substr(atPos + 1);
        auto colonPos = userInfo.find(':');
        if (colonPos != std::string::npos) {
            c.user     = PercentDecode(userInfo.substr(0, colonPos));
            c.password = PercentDecode(userInfo.substr(colonPos + 1));
        } else {
            c.user = PercentDecode(userInfo);
        }
    }

    // Extract host[:port]
    auto slashPos = rest.find('/');
    std::string hostPort = (slashPos != std::string::npos) ? rest.substr(0, slashPos) : rest;
    std::string pathPart = (slashPos != std::string::npos) ? rest.substr(slashPos + 1) : std::string();

    auto colonPos = hostPort.find(':');
    if (colonPos != std::string::npos) {
        c.host = hostPort.substr(0, colonPos);
        try { c.port = std::stoi(hostPort.substr(colonPos + 1)); } catch (...) { c.port = 445; }
    } else {
        c.host = hostPort;
        c.port = 445;
    }

    // Extract share[/subPath]
    auto slash2 = pathPart.find('/');
    if (slash2 != std::string::npos) {
        c.share   = PercentDecode(pathPart.substr(0, slash2));
        c.subPath = PercentDecode(pathPart.substr(slash2 + 1));
    } else {
        c.share   = PercentDecode(pathPart);
        c.subPath = std::string();
    }

    c.valid = !c.host.empty() && !c.share.empty() && !c.subPath.empty();
    return c;
}

static void ThrowTypeError(napi_env env, const char *message);
static void ThrowRangeError(napi_env env, const char *message);
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

// ─────────────────────────────────────────────────────────────
// ExtractSubtitleEntries: 从 MKV 等容器提取指定字幕流的全部条目
// 返回 JSON 数组：[{"startMs":N,"endMs":N,"text":"..."},...]
// 对于 subrip(SRT) 类型，pkt->data 即为原始文本，无需解码器
// ─────────────────────────────────────────────────────────────

struct ExtractSubAsyncContext {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string url;
  std::string headerLines;
  int streamIndex = -1;
  int64_t timeoutMs = 30000;
  std::string jsonResult;
  std::string errorMessage;
};

static std::string StripAssOverrideTags(const std::string &text) {
  std::string out;
  out.reserve(text.size());
  bool inTag = false;
  for (char c : text) {
    if (c == '{') { inTag = true; continue; }
    if (c == '}') { inTag = false; continue; }
    if (!inTag) out += c;
  }
  // 替换 \N（ASS 强制换行）为 \n
  size_t pos = 0;
  while ((pos = out.find("\\N", pos)) != std::string::npos) {
    out.replace(pos, 2, "\n");
  }
  return out;
}

// 从 ASS Dialogue 行提取纯文本（格式：Dialogue: layer,start,end,style,...,text）
static std::string ParseAssDialogue(const char *ass) {
  if (ass == nullptr) return "";
  // 跳过 9 个逗号分隔的字段到文本部分
  int commas = 0;
  const char *p = ass;
  while (*p && commas < 9) {
    if (*p == ',') commas++;
    p++;
  }
  if (commas < 9) return ""; // 格式不符，返回空串（不暴露原始乱码内容）
  return StripAssOverrideTags(std::string(p));
}

static void ExecuteExtractSubAsync(napi_env env, void *data) {
  (void)env;
  ExtractSubAsyncContext *ctx = static_cast<ExtractSubAsyncContext *>(data);
  if (ctx == nullptr) return;

  avformat_network_init();

  // find_stream_info 阶段给 10s 超时（足够探测流信息），读包阶段单独计时
  ProbeInterruptContext interruptCtx;
  interruptCtx.startTimeUs = av_gettime_relative();
  interruptCtx.timeoutUs = 10LL * 1000000LL; // 10s for open+find_stream_info

  AVFormatContext *formatCtx = avformat_alloc_context();
  if (formatCtx == nullptr) {
    ctx->errorMessage = "extractSub: cannot alloc format context";
    return;
  }
  formatCtx->interrupt_callback.callback = ProbeInterruptCallback;
  formatCtx->interrupt_callback.opaque = &interruptCtx;

  AVDictionary *options = nullptr;
  if (!ctx->headerLines.empty()) {
    av_dict_set(&options, "headers", ctx->headerLines.c_str(), 0);
  }
  // 限制 probe 量，避免 find_stream_info 在大型网络文件上耗费过长时间
  av_dict_set(&options, "probesize", "65536", 0);
  av_dict_set(&options, "analyzeduration", "0", 0);

  int ret = avformat_open_input(&formatCtx, ctx->url.c_str(), nullptr, &options);
  av_dict_free(&options);
  if (ret < 0) {
    ctx->errorMessage = "extractSub: open input failed: " + FfmpegErrorToString(ret);
    if (formatCtx) avformat_close_input(&formatCtx);
    return;
  }

  // MKV 等格式在 avformat_open_input 后已通过 Tracks 元素填充流信息，
  // 可在调用耗时较长的 find_stream_info 之前就完成图像字幕的快速检测。
  {
    const int earlySi = ctx->streamIndex;
    if (formatCtx->nb_streams > 0 &&
        earlySi >= 0 && earlySi < (int)formatCtx->nb_streams &&
        formatCtx->streams[earlySi]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
      const AVCodecID earlyId = formatCtx->streams[earlySi]->codecpar->codec_id;
      const char *earlyName = avcodec_get_name(earlyId);
      bool earlyImageBased = (earlyId == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                              earlyId == AV_CODEC_ID_DVD_SUBTITLE ||
                              earlyId == AV_CODEC_ID_DVB_SUBTITLE);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "extractSub early-check stream[%d] codec=%s imageBased=%d",
                   earlySi, earlyName ? earlyName : "?", (int)earlyImageBased);
      if (earlyImageBased) {
        ctx->errorMessage = std::string("image-based subtitle not supported: ") +
                            (earlyName ? earlyName : "unknown");
        avformat_close_input(&formatCtx);
        return;
      }
    }
  }

  ret = avformat_find_stream_info(formatCtx, nullptr);
  if (ret < 0) {
    ctx->errorMessage = "extractSub: find stream info failed: " + FfmpegErrorToString(ret);
    avformat_close_input(&formatCtx);
    return;
  }

  // 重置中断时钟：find_stream_info 完成，给读包阶段完整的 timeoutMs 预算
  interruptCtx.startTimeUs = av_gettime_relative();
  interruptCtx.timeoutUs = ctx->timeoutMs > 0 ? ctx->timeoutMs * 1000 : 60LL * 1000000LL;

  const int si = ctx->streamIndex;
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub nb_streams=%u target_si=%d", formatCtx->nb_streams, si);

  if (si < 0 || si >= (int)formatCtx->nb_streams ||
      formatCtx->streams[si]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
    // 目标 index 不是字幕流，打印所有流信息辅助排查
    for (unsigned int i = 0; i < formatCtx->nb_streams; i++) {
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "  stream[%u] codec_type=%d codec_id=%d",
                   i,
                   (int)formatCtx->streams[i]->codecpar->codec_type,
                   (int)formatCtx->streams[i]->codecpar->codec_id);
    }
    ctx->errorMessage = "extractSub: invalid subtitle stream index " + std::to_string(si);
    avformat_close_input(&formatCtx);
    return;
  }

  AVStream *subStream = formatCtx->streams[si];
  AVRational tb = subStream->time_base;

  // 检测图像类字幕（PGS/VOBSUB/DVB）：这类字幕数据是二进制位图，无法提取为文本，
  // 直接快速失败，避免白白等待 60 秒超时。
  const AVCodecID subCodecId = subStream->codecpar->codec_id;
  const char *subCodecName = avcodec_get_name(subCodecId);
  bool isImageBased = (subCodecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                       subCodecId == AV_CODEC_ID_DVD_SUBTITLE ||
                       subCodecId == AV_CODEC_ID_DVB_SUBTITLE);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub stream[%d] codec_id=%d codec_name=%s imageBased=%d",
               si, (int)subCodecId, subCodecName ? subCodecName : "?", (int)isImageBased);
  if (isImageBased) {
    ctx->errorMessage = std::string("image-based subtitle not supported: ") +
                        (subCodecName ? subCodecName : "unknown");
    avformat_close_input(&formatCtx);
    return;
  }

  // 尝试打开解码器（subrip 在 OHOS 可能未编译进去，则退回原始包）
  const AVCodec *codec = avcodec_find_decoder(subCodecId);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub stream[%d] codec_id=%d decoder=%s",
               si, (int)subCodecId,
               codec ? codec->name : "NULL(raw-pkt-mode)");
  AVCodecContext *codecCtx = nullptr;
  if (codec != nullptr) {
    codecCtx = avcodec_alloc_context3(codec);
    if (codecCtx != nullptr) {
      avcodec_parameters_to_context(codecCtx, subStream->codecpar);
      if (avcodec_open2(codecCtx, codec, nullptr) < 0) {
        avcodec_free_context(&codecCtx);
        codecCtx = nullptr;
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "ExtractSub",
                     "extractSub codec open failed, fallback to raw-pkt-mode");
      }
    }
  }

  // Cues-based seek 策略（针对蓝光原盘等非交错封装 MKV）：
  // MKV Cues 元素记录了每条流各 Cluster 的字节偏移；FFmpeg 在 avformat_open_input 后
  // 通过 SeekHead 读取 Cues，并将结果存入 stream index_entries。
  // 若字幕流有 index_entries，可直接 seek 到字幕 Cluster 起始位置后顺序读取，
  // 避免从文件头部顺序扫描大量视频/音频数据（可能需要数分钟）。
  {
    int nIdx = avformat_index_get_entries_count(subStream);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                 "extractSub stream[%d] nb_index_entries=%d", si, nIdx);
    if (nIdx > 0) {
      // 找字幕流所有 index_entries 中字节偏移最小的一个作为起始 seek 点
      const AVIndexEntry *firstEntry = avformat_index_get_entry(subStream, 0);
      int64_t minPos = firstEntry ? firstEntry->pos : INT64_MAX;
      int64_t firstTs = firstEntry ? firstEntry->timestamp : 0;
      for (int ie = 1; ie < nIdx; ie++) {
        const AVIndexEntry *e = avformat_index_get_entry(subStream, ie);
        if (e && e->pos < minPos) {
          minPos = e->pos;
          firstTs = e->timestamp;
        }
      }
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "extractSub cues-seek firstTs=%lld minPos=%lld nIdx=%d",
                   (long long)firstTs, (long long)minPos, nIdx);
      // seek 到字幕最早的 Cluster 位置；MKV demuxer 会用 Cues 精确定位
      avformat_seek_file(formatCtx, si, firstTs - 1, firstTs, firstTs + 1, 0);
      // 重置超时，为从字幕起始位置做顺序读取提供完整时间窗口
      interruptCtx.startTimeUs = av_gettime_relative();
      interruptCtx.timeoutUs = ctx->timeoutMs > 0 ? ctx->timeoutMs * 1000 : 60LL * 1000000LL;
    }
    // 若 nb_index_entries == 0（Cues 无字幕条目），保持当前文件位置顺序读取
  }

  // 顺序读取 packet 并过滤字幕流
  // 注意：不设 AVDISCARD_ALL——HTTP/WebDAV 场景下 AVDISCARD_ALL 会对每个 video/audio block
  // 调用 avio_skip()，进而发起大量 HTTP Range 请求（每帧一次），高 RTT 下速度极慢。

  std::string json = "[";
  bool first = true;
  int64_t totalPkts = 0;
  int64_t subPkts = 0;
  // 防止超大字幕文件耗尽内存：限制最大条目数和 JSON 字节数
  static constexpr int MAX_SUBTITLE_ENTRIES = 50000;
  static constexpr size_t MAX_JSON_BYTES = 16 * 1024 * 1024; // 16 MB

  AVPacket *pkt = av_packet_alloc();
  if (pkt == nullptr) {
    if (codecCtx != nullptr) avcodec_free_context(&codecCtx);
    avformat_close_input(&formatCtx);
    ctx->errorMessage = "extractSub: cannot alloc packet";
    return;
  }
  int readRet = 0;
  while ((readRet = av_read_frame(formatCtx, pkt)) >= 0) {
    totalPkts++;
    if (pkt->stream_index != si || pkt->size <= 0 || pkt->data == nullptr) {
      av_packet_unref(pkt);
      continue;
    }
    subPkts++;

    int64_t startMs = (pkt->pts == AV_NOPTS_VALUE) ? 0 :
      (int64_t)((double)pkt->pts * av_q2d(tb) * 1000.0);
    int64_t endMs = (pkt->duration > 0) ?
      startMs + (int64_t)((double)pkt->duration * av_q2d(tb) * 1000.0) :
      startMs + 5000;

    std::string text;

    if (codecCtx != nullptr) {
      // 有解码器：走 avcodec_decode_subtitle2
      AVSubtitle sub = {};
      int gotSub = 0;
      int dr = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt);
      if (dr >= 0 && gotSub && sub.num_rects > 0) {
        for (unsigned int r = 0; r < sub.num_rects; r++) {
          if (sub.rects[r]->ass != nullptr) {
            text = ParseAssDialogue(sub.rects[r]->ass);
          } else if (sub.rects[r]->text != nullptr) {
            text = std::string(sub.rects[r]->text);
          }
          if (!text.empty()) break;
        }
      }
      avsubtitle_free(&sub);
    } else {
      // 无解码器：subrip 在 MKV 中 pkt->data 可能是 ASS block 格式或纯 SRT 文本
      text = std::string(reinterpret_cast<char *>(pkt->data),
                         static_cast<size_t>(pkt->size));
      // 检测 MKV ASS block 格式：readorder,layer,style,name,marginL,marginR,marginV,effect,text
      // 特征：首字符为数字，前 200 字节内有 8 个逗号
      bool isAssBlock = !text.empty() && std::isdigit((unsigned char)text[0]);
      if (isAssBlock) {
        int commas = 0;
        size_t pos = 0;
        size_t scanEnd = std::min(text.size(), (size_t)200);
        while (pos < scanEnd && commas < 8) {
          if (text[pos] == ',') commas++;
          pos++;
        }
        if (commas == 8 && pos < text.size()) {
          text = StripAssOverrideTags(text.substr(pos));
        } else {
          isAssBlock = false; // 逗号不足，不是 ASS block，走 SRT 路径
        }
      }
      if (!isAssBlock) {
        // SRT 格式：去除序号行和时间行
        size_t lineStart = 0;
        for (int linePass = 0; linePass < 3 && lineStart < text.size(); linePass++) {
          size_t nlPos = text.find('\n', lineStart);
          if (nlPos == std::string::npos) break;
          std::string line = text.substr(lineStart, nlPos - lineStart);
          if (!line.empty() && line.back() == '\r') line.pop_back();
          bool isSeqOrTime = !line.empty() &&
            (std::all_of(line.begin(), line.end(), [](unsigned char c){ return std::isdigit(c) != 0; }) ||
             line.find("-->") != std::string::npos);
          if (isSeqOrTime) {
            lineStart = nlPos + 1;
          } else {
            break;
          }
        }
        text = text.substr(lineStart);
      }
      size_t ts = text.find_first_not_of(" \t\r\n");
      size_t te = text.find_last_not_of(" \t\r\n");
      if (ts != std::string::npos) {
        text = text.substr(ts, te - ts + 1);
      } else {
        text.clear();
      }
    }

    av_packet_unref(pkt);

    if (text.empty()) continue;

    // OOM guard：超过上限时终止，避免超大文件耗尽内存
    if (subPkts >= MAX_SUBTITLE_ENTRIES || json.size() >= MAX_JSON_BYTES) {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "ExtractSub",
                   "extractSub cap reached entries=%lld jsonBytes=%zu, stopping",
                   (long long)subPkts, json.size());
      av_packet_unref(pkt);
      break;
    }

    if (!first) json += ",";
    first = false;
    json += "{\"startMs\":";
    json += std::to_string(startMs);
    json += ",\"endMs\":";
    json += std::to_string(endMs);
    json += ",\"text\":\"";
    json += JsonEscape(text);
    json += "\"}";
  }
  av_packet_free(&pkt);

  const int nbStreams = formatCtx ? (int)formatCtx->nb_streams : 0;
  if (codecCtx) avcodec_free_context(&codecCtx);
  avformat_close_input(&formatCtx);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub done stream=%d totalPkts=%lld subPkts=%lld",
               si, (long long)totalPkts, (long long)subPkts);

  if (readRet < 0 && readRet != AVERROR_EOF) {
    ctx->errorMessage = "extractSub: read failed: " + FfmpegErrorToString(readRet) +
                        " totalPkts=" + std::to_string(totalPkts) +
                        " subPkts=" + std::to_string(subPkts);
  } else if (first) {
    // count=0：以错误形式 reject，让 ArkTS catch 能打印 codec/packet 诊断信息
    ctx->errorMessage = "count=0 codec=" + std::string(subCodecName ? subCodecName : "?") +
                        " totalPkts=" + std::to_string(totalPkts) +
                        " subPkts=" + std::to_string(subPkts) +
                        " nbStreams=" + std::to_string(nbStreams);
  } else {
    json += "]";
    ctx->jsonResult = json;
  }
}

static void CompleteExtractSubAsync(napi_env env, napi_status status, void *data) {
  ExtractSubAsyncContext *ctx = static_cast<ExtractSubAsyncContext *>(data);
  if (ctx == nullptr) return;

  bool settled = false;
  if (status == napi_ok && ctx->errorMessage.empty()) {
    napi_value settleValue = nullptr;
    if (napi_create_string_utf8(env, ctx->jsonResult.c_str(), NAPI_AUTO_LENGTH, &settleValue) == napi_ok &&
        napi_resolve_deferred(env, ctx->deferred, settleValue) == napi_ok) {
      settled = true;
    }
  }
  if (!settled) {
    napi_value msg = nullptr;
    napi_value err = nullptr;
    const std::string &errStr = ctx->errorMessage.empty() ? "extractSub cancelled" : ctx->errorMessage;
    if (napi_create_string_utf8(env, errStr.c_str(), NAPI_AUTO_LENGTH, &msg) == napi_ok &&
        napi_create_error(env, nullptr, msg, &err) == napi_ok) {
      napi_reject_deferred(env, ctx->deferred, err);
    } else {
      // 兜底：确保 Promise 一定被 settle，避免 JS 端永久挂起
      napi_value fallback = nullptr;
      napi_create_string_utf8(env, "extractSub: internal napi error", NAPI_AUTO_LENGTH, &fallback);
      napi_value fallbackErr = nullptr;
      napi_create_error(env, nullptr, fallback, &fallbackErr);
      napi_reject_deferred(env, ctx->deferred, fallbackErr);
    }
  }

  napi_delete_async_work(env, ctx->work);
  delete ctx;
}

static napi_value ExtractSubtitleEntries(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = { nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 4) {
    ThrowTypeError(env, "extractSubtitleEntries requires (url, headerLines, streamIndex, timeoutMs)");
    return nullptr;
  }

  std::string url;
  std::string headerLines;
  int64_t streamIndex = -1;
  int64_t timeoutMs = 30000;

  if (!ReadUtf8String(env, args[0], url)) {
    ThrowTypeError(env, "extractSubtitleEntries: url must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[1], headerLines)) {
    ThrowTypeError(env, "extractSubtitleEntries: headerLines must be string");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[2], &streamIndex) != napi_ok) {
    ThrowTypeError(env, "extractSubtitleEntries: streamIndex must be int64");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[3], &timeoutMs) != napi_ok) {
    ThrowTypeError(env, "extractSubtitleEntries: timeoutMs must be int64");
    return nullptr;
  }

  if (streamIndex < 0 || streamIndex > (int64_t)INT_MAX) {
    ThrowRangeError(env, "extractSubtitleEntries: streamIndex out of range");
    return nullptr;
  }

  ExtractSubAsyncContext *ctx = new ExtractSubAsyncContext();
  ctx->url = url;
  ctx->headerLines = headerLines;
  ctx->streamIndex = (int)streamIndex;
  ctx->timeoutMs = timeoutMs;

  napi_value promise = nullptr;
  if (napi_create_promise(env, &ctx->deferred, &promise) != napi_ok) {
    delete ctx;
    ThrowTypeError(env, "extractSubtitleEntries: failed to create promise");
    return nullptr;
  }

  napi_value resourceName = nullptr;
  napi_create_string_utf8(env, "extractSubtitleEntriesAsync", NAPI_AUTO_LENGTH, &resourceName);

  if (napi_create_async_work(env, nullptr, resourceName,
                             ExecuteExtractSubAsync, CompleteExtractSubAsync,
                             ctx, &ctx->work) != napi_ok) {
    delete ctx;
    ThrowTypeError(env, "extractSubtitleEntries: failed to create async work");
    return nullptr;
  }

  if (napi_queue_async_work(env, ctx->work) != napi_ok) {
    napi_delete_async_work(env, ctx->work);
    delete ctx;
    ThrowTypeError(env, "extractSubtitleEntries: failed to queue work");
    return nullptr;
  }

  return promise;
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

  // ── SMB / FFmpeg 软件解码播放字段（isSmbPlayback == true 时有效）──────────────────────────
  // 生命周期：Prepare 时由 ExecuteSmbPrepare 填充，Release/ResetRuntimeState 时由
  // SmbCleanupResources 清理；播放线程通过 smbStopFlag/smbPauseFlag/smbSeekTargetMs 与主线程通信。
  // proxyPlayUrl: Prepare 时赋值，供 GetProxyUrl NAPI 返回给 JS 层（SMB fallback 场景使用）
  std::string      proxyPlayUrl;
  bool             isSmbPlayback   = false;
  SmbAVIOContext  *smbAvioOpaque   = nullptr;  // 由 SmbCleanupResources 负责 delete
  AVIOContext     *ffmpegAvio      = nullptr;  // 由 SmbCleanupResources 负责 free
  AVFormatContext *ffmpegFmt       = nullptr;  // 由 SmbCleanupResources 负责 close
  std::thread      smbPlayThread;              // 播放线程；joinable 时表示线程正在运行
  std::atomic<bool>    smbStopFlag  {false};   // 通知播放线程退出（原子）
  std::atomic<bool>    smbPauseFlag {false};   // 通知播放线程暂停（原子）
  std::atomic<int64_t> smbSeekTargetMs {-1};   // ≥0 时表示待执行的 seek 目标（原子）
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
static constexpr int32_t ERR_SMB_PREPARE_FAILED = 1008;   // SMB/AVIO prepare 失败
static constexpr int32_t ERR_SMB_PLAYBACK_ERROR = 1009;   // SMB 播放线程运行时错误

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

// ============================================================================
// ============================================================================
// SMB → local HTTP proxy (仅在 VIDALL_HAS_LIBSMB2=1 时编译)
// Bridges libsmb2 reads to OH_AVPlayer via http://127.0.0.1:PORT/
// Each OH_AVPlayer Range request spawns one handler thread with its own smb2 context.
// ============================================================================
#if VIDALL_HAS_LIBSMB2

// 并发 handler 线程上限。OH_AVPlayer 并发 Range 请求较多时，避免无界 detach 线程耗尽系统资源。
// 超出上限时返回 503，OH_AVPlayer 会在短暂延迟后重试。
static constexpr int SMB_MAX_CONCURRENT_HANDLERS = 8;
static std::atomic<int> g_smbActiveHandlers{0};

static void SmbProxyHandleRequest(int clientFd, SmbUrlComponents comps) {
    // 并发限流：超出上限直接返回 503，防止 detached 线程数无界增长
    if (g_smbActiveHandlers.fetch_add(1, std::memory_order_relaxed) >= SMB_MAX_CONCURRENT_HANDLERS) {
        g_smbActiveHandlers.fetch_sub(1, std::memory_order_relaxed);
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll/SmbProxy",
                     "too many concurrent handlers (max=%{public}d), rejecting request",
                     SMB_MAX_CONCURRENT_HANDLERS);
        const char *e = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nRetry-After: 1\r\nConnection: close\r\n\r\n";
        (void)write(clientFd, e, strlen(e));
        close(clientFd);
        return;
    }
    // RAII：函数退出时（任何路径）递减计数
    struct HandlerGuard {
        ~HandlerGuard() { g_smbActiveHandlers.fetch_sub(1, std::memory_order_relaxed); }
    } guard;
    // Read HTTP request headers (until "\r\n\r\n")
    std::string req;
    req.reserve(2048);
    {
        char tmp[1024];
        while (req.find("\r\n\r\n") == std::string::npos) {
            struct pollfd pfd;
            pfd.fd = clientFd; pfd.events = POLLIN; pfd.revents = 0;
            if (poll(&pfd, 1, 5000) <= 0) { close(clientFd); return; }
            int n = static_cast<int>(read(clientFd, tmp, sizeof(tmp)));
            if (n <= 0) { close(clientFd); return; }
            req.append(tmp, static_cast<size_t>(n));
        }
    }

    bool isHead = req.size() >= 4 && req.compare(0, 4, "HEAD") == 0;

    // 方案 A：从 HTTP 请求行解析路径，覆盖 comps.share 和 comps.subPath。
    // 请求行格式：GET /share/subPath HTTP/1.1
    // Prepare() 中将 comps.share 和 comps.subPath 编码进了代理 URL，
    // 这里解码还原，保持路径作为唯一真相来源（URL）。
    // host/port/user/password 仍沿用传入的 comps（不在 HTTP 路径中）。
    {
        size_t methodEnd = req.find(' ');
        if (methodEnd != std::string::npos) {
            size_t pathStart = methodEnd + 1;
            size_t pathEnd = req.find(' ', pathStart);
            if (pathEnd != std::string::npos) {
                std::string rawPath = req.substr(pathStart, pathEnd - pathStart);
                // 去掉查询串（如 ?xxx），FFmpeg 可能附加
                auto qmark = rawPath.find('?');
                if (qmark != std::string::npos) rawPath = rawPath.substr(0, qmark);
                // 去掉前导 '/'
                if (!rawPath.empty() && rawPath[0] == '/') rawPath = rawPath.substr(1);
                // 第一个 '/' 前是 share（PercentEncodePathSegment 编码），后是 subPath
                auto sep = rawPath.find('/');
                if (sep != std::string::npos) {
                    comps.share   = PercentDecode(rawPath.substr(0, sep));
                    // subPath 可能含多级目录，整体 PercentDecode 即可（'/' 不会被编码）
                    comps.subPath = PercentDecode(rawPath.substr(sep + 1));
                } else if (!rawPath.empty()) {
                    comps.share   = PercentDecode(rawPath);
                    comps.subPath.clear();
                }
            }
        }
    }

    // Parse Range: bytes=START-[END]
    int64_t rangeStart = 0, rangeEnd = -1;
    {
        size_t pos = req.find("Range: bytes=");
        if (pos == std::string::npos) pos = req.find("range: bytes=");
        if (pos != std::string::npos) {
            std::string rng = req.substr(pos + 13);
            auto nl = rng.find('\r');
            if (nl != std::string::npos) rng = rng.substr(0, nl);
            auto dash = rng.find('-');
            if (dash != std::string::npos) {
                try { rangeStart = std::stoll(rng.substr(0, dash)); } catch (...) { rangeStart = 0; }
                std::string endStr = rng.substr(dash + 1);
                if (!endStr.empty()) {
                    try { rangeEnd = std::stoll(endStr); } catch (...) { rangeEnd = -1; }
                }
            }
        }
    }

    // Open SMB connection
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        const char *e = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        (void)write(clientFd, e, strlen(e));
        close(clientFd);
        return;
    }
    if (!comps.user.empty())     smb2_set_user(smb2,     comps.user.c_str());
    if (!comps.password.empty()) smb2_set_password(smb2, comps.password.c_str());
    smb2_set_timeout(smb2, 30);

    // smb2_set_port() 在此版本 libsmb2 中不存在。
    // libsmb2 的 smb2_connect_share() server 参数支持 "host:port" 格式（经由 getaddrinfo 解析），
    // 在非标准端口时构造 "host:port" 字符串传入，445 端口无需拼接。
    std::string connectHost = comps.host;
    if (comps.port > 0 && comps.port != 445) {
        connectHost = comps.host + ":" + std::to_string(comps.port);
    }

    int ret = smb2_connect_share(smb2, connectHost.c_str(), comps.share.c_str(),
                                  comps.user.empty() ? nullptr : comps.user.c_str());
    if (ret < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll/SmbProxy",
                     "connect failed: %{public}s", smb2_get_error(smb2));
        smb2_destroy_context(smb2);
        const char *e = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        (void)write(clientFd, e, strlen(e));
        close(clientFd);
        return;
    }

    struct smb2fh *fh = smb2_open(smb2, comps.subPath.c_str(), O_RDONLY);
    if (!fh) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll/SmbProxy",
                     "open failed: %{public}s path=%{public}s",
                     smb2_get_error(smb2), comps.subPath.c_str());
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        const char *e = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        (void)write(clientFd, e, strlen(e));
        close(clientFd);
        return;
    }

    struct smb2_stat_64 st = {};
    if (smb2_fstat(smb2, fh, &st) < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll/SmbProxy",
                     "smb2_fstat failed: %{public}s", smb2_get_error(smb2));
        smb2_close(smb2, fh);
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        const char *e = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        (void)write(clientFd, e, strlen(e));
        close(clientFd);
        return;
    }
    int64_t fileSize = static_cast<int64_t>(st.smb2_size);
    if (fileSize <= 0) fileSize = 0;

    if (rangeEnd < 0 || rangeEnd >= fileSize) rangeEnd = (fileSize > 0) ? fileSize - 1 : 0;
    int64_t contentLen = (fileSize > 0) ? (rangeEnd - rangeStart + 1) : 0;
    if (contentLen < 0) contentLen = 0;

    if (rangeStart > 0) {
        int64_t seekRet = smb2_lseek(smb2, fh, rangeStart, SEEK_SET, nullptr);
        if (seekRet < 0) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAll/SmbProxy",
                         "smb2_lseek failed: %{public}s rangeStart=%{public}lld",
                         smb2_get_error(smb2), (long long)rangeStart);
            smb2_close(smb2, fh);
            smb2_disconnect_share(smb2);
            smb2_destroy_context(smb2);
            const char *e = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            (void)write(clientFd, e, strlen(e));
            close(clientFd);
            return;
        }
    }

    bool isPartial = (rangeStart > 0 || (fileSize > 0 && rangeEnd < fileSize - 1));
    char hdr[512];
    if (isPartial) {
        snprintf(hdr, sizeof(hdr),
            "HTTP/1.1 206 Partial Content\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Content-Length: %lld\r\n"
            "Content-Range: bytes %lld-%lld/%lld\r\n"
            "Accept-Ranges: bytes\r\n"
            "Connection: close\r\n\r\n",
            (long long)contentLen, (long long)rangeStart,
            (long long)rangeEnd,   (long long)fileSize);
    } else {
        snprintf(hdr, sizeof(hdr),
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Content-Length: %lld\r\n"
            "Accept-Ranges: bytes\r\n"
            "Connection: close\r\n\r\n",
            (long long)fileSize);
    }
    (void)write(clientFd, hdr, strlen(hdr));

    if (!isHead && contentLen > 0) {
        uint8_t buf[65536];
        int64_t remaining = contentLen;
        bool writeErr = false;
        while (remaining > 0 && !writeErr) {
            uint32_t toRead = static_cast<uint32_t>(std::min(static_cast<int64_t>(sizeof(buf)), remaining));
            int n = smb2_read(smb2, fh, buf, toRead);
            if (n <= 0) break;
            ssize_t sent = 0;
            while (sent < static_cast<ssize_t>(n)) {
                ssize_t r = write(clientFd, buf + sent, static_cast<size_t>(n - sent));
                if (r <= 0) { writeErr = true; break; }
                sent += r;
            }
            remaining -= static_cast<int64_t>(n);
        }
    }

    smb2_close(smb2, fh);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
    close(clientFd);
}

static void SmbProxyAcceptLoop(int serverFd, SmbUrlComponents comps,
                                std::atomic<bool> *stopFlag) {
    while (!stopFlag->load(std::memory_order_relaxed)) {
        struct pollfd pfd;
        pfd.fd = serverFd; pfd.events = POLLIN; pfd.revents = 0;
        if (poll(&pfd, 1, 300) <= 0) continue;
        if (!(pfd.revents & POLLIN)) continue;
        int clientFd = accept(serverFd, nullptr, nullptr);
        if (clientFd < 0) continue;
        std::thread([clientFd, comps]() {
            SmbProxyHandleRequest(clientFd, comps);
        }).detach();
    }
    close(serverFd);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll/SmbProxy", "accept loop exited");
}

// Returns listening port, or -1 on error
static int SmbStartProxy(NativePlayerSkeletonState &state, const SmbUrlComponents &comps) {
    int serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (serverFd < 0) return -1;
    int opt = 1;
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr = {};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = 0;  // OS assigns port
    if (bind(serverFd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0 ||
        listen(serverFd, 8) < 0) {
        close(serverFd);
        return -1;
    }
    socklen_t addrLen = sizeof(addr);
    getsockname(serverFd, reinterpret_cast<struct sockaddr *>(&addr), &addrLen);
    int port = ntohs(addr.sin_port);
    state.smbStopFlag.store(false, std::memory_order_relaxed);
    state.smbPlayThread = std::thread(SmbProxyAcceptLoop, serverFd, comps, &state.smbStopFlag);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll/SmbProxy",
                 "proxy started port=%{public}d host=%{public}s share=%{public}s",
                 port, comps.host.c_str(), comps.share.c_str());
    return port;
}

static void SmbStopProxy(NativePlayerSkeletonState &state) {
    if (!state.isSmbPlayback) return;
    state.smbStopFlag.store(true, std::memory_order_relaxed);
    if (state.smbPlayThread.joinable()) {
        state.smbPlayThread.join();
    }
    state.isSmbPlayback = false;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll/SmbProxy", "proxy stopped");
}

#else  // VIDALL_HAS_LIBSMB2 == 0

// libsmb2 未编译时的空实现，避免调用方报错
static int SmbStartProxy(NativePlayerSkeletonState & /*state*/,
                          const SmbUrlComponents & /*comps*/) { return -1; }
static void SmbStopProxy(NativePlayerSkeletonState & /*state*/) {}

#endif // VIDALL_HAS_LIBSMB2

static void ResetRuntimeState(NativePlayerSkeletonState &state, bool keepProxy = false) {
  if (!keepProxy) {
    SmbStopProxy(state);  // 停止 SMB HTTP 代理（如果正在运行）
    state.proxyPlayUrl.clear();
  }
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
// A4：OH_AVPlayer 状态 / 错误回调（媒体线程调用，userData = NativePlayerSkeletonState*）
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

  // SMB 源：启动本地 HTTP 代理，将 smb:// 透明转换为 http://127.0.0.1:PORT/
  // OH_AVPlayer 通过 Range 请求访问本地代理，代理再通过 libsmb2 读取 SMB 文件。
  // state.url 保持不变（保留原始 smb:// URL），避免重复 prepare 时丢失 URL。
  std::string playUrl = state.url;
  if (state.url.size() > 6 && state.url.compare(0, 6, "smb://") == 0) {
#if VIDALL_HAS_LIBSMB2
    SmbUrlComponents comps = ParseSmbUrl(state.url);
    if (!comps.valid) {
      EmitError(state, ERR_SMB_PREPARE_FAILED, "prepare failed: invalid smb:// URL");
      return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
    }
    SmbStopProxy(state);  // 清理旧代理（防止 surface 切换后残留，含上次 keepProxy 遗留代理）
    state.proxyPlayUrl.clear();
    int proxyPort = SmbStartProxy(state, comps);
    if (proxyPort < 0) {
      EmitError(state, ERR_SMB_PREPARE_FAILED, "prepare failed: SMB HTTP proxy start failed");
      return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
    }
    state.isSmbPlayback = true;
    // 修复：构建包含完整路径的 HTTP 代理 URL，格式：http://127.0.0.1:PORT/share/subPath
    // comps.share 和 comps.subPath 已由 ParseSmbUrl() PercentDecode，
    // 这里重新编码为合法 HTTP URL 路径，原因：
    //   1. OH_AVPlayer/FFmpeg 通过文件扩展名感知媒体格式，路径缺失会导致黑屏；
    //   2. SmbProxyHandleRequest() 从请求行解析路径并 decode 后传给 libsmb2，
    //      libsmb2 需要 decoded 路径（不含 %XX），此处编码 → 传输 → 解码保证正确性。
    // 注意：playUrl 仅含 127.0.0.1 地址，不含 SMB 凭据，日志可安全输出。
    playUrl = "http://127.0.0.1:" + std::to_string(proxyPort) + "/"
              + PercentEncodePathSegment(comps.share) + "/"
              + PercentEncodePath(comps.subPath);
    // 存储 proxy URL，供 GetProxyUrl NAPI 返回给 JS 层（SMB fallback 到 ijkplayer 时使用）
    state.proxyPlayUrl = playUrl;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll/SmbProxy",
                 "SMB rewritten to %{public}s", playUrl.c_str());
#else
    EmitError(state, ERR_SMB_PREPARE_FAILED,
              "prepare failed: SMB playback not supported (VIDALL_HAS_LIBSMB2=0)");
    return ReturnUndefinedOrThrow(env, "prepare failed to create return value");
#endif
  }

  // 设置播放源 URL
  OH_AVErrCode avRet = OH_AVPlayer_SetURLSource(state.avPlayer, playUrl.c_str());
  if (avRet != AV_ERR_OK) {
    // SMB 代理已启动，SetURLSource 失败时必须先停止代理，防止线程泄漏
    if (state.isSmbPlayback) {
      SmbStopProxy(state);
    }
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
  // 支持可选的 keepProxy 参数：Release(handle, keepProxy=false)
  // 当 keepProxy=true 时，SMB HTTP 代理线程不会被停止，允许 ijkplayer 在 fallback 后继续使用代理 URL。
  size_t argc = 2;
  napi_value args[2] = { nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
    ThrowTypeError(env, "release requires (handle[, keepProxy])");
    return nullptr;
  }
  int32_t handle = 0;
  if (napi_get_value_int32(env, args[0], &handle) != napi_ok) {
    ThrowTypeError(env, "release handle must be int32");
    return nullptr;
  }
  bool keepProxy = false;
  if (argc >= 2 && args[1] != nullptr) {
    napi_get_value_bool(env, args[1], &keepProxy);
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
  // keepProxy=true 时跳过 SmbStopProxy，保持代理线程继续服务 ijkplayer；
  // proxyPlayUrl 保留供 JS 层在 erase 后已不可访问前读取（erase 前已读完）。
  ResetRuntimeState(state, keepProxy);
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

// GetProxyUrl(handle) → string
// 返回当前 SMB 播放的 HTTP 代理 URL（如 http://127.0.0.1:PORT/share/path/file.mkv）。
// 在 native player 失败时由 JS 层调用，将 proxy URL 传给 ijkplayer 进行 fallback 软解。
// 若 handle 无效或尚未 prepare SMB 源，返回空字符串，不 crash。
static napi_value GetProxyUrl(napi_env env, napi_callback_info info) {
  int32_t handle = 0;
  if (!ReadHandleArg(env, info, 1, handle)) {
    ThrowTypeError(env, "getProxyUrl requires (handle)");
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(g_playersMutex);
  auto iter = g_players.find(handle);
  if (iter == g_players.end()) {
    // handle 无效：安全返回空字符串，不 crash
    napi_value emptyStr = nullptr;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &emptyStr);
    return emptyStr;
  }
  const std::string &proxyUrl = iter->second.proxyPlayUrl;
  napi_value result = nullptr;
  napi_create_string_utf8(env, proxyUrl.c_str(), proxyUrl.size(), &result);
  return result;
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

// ─────────────────────────────────────────────────────────────────────────────
// 设备解码能力查询（供 ijkplayer 硬解决策使用）
// ─────────────────────────────────────────────────────────────────────────────

struct VideoCapResult {
  bool capabilityKnown = false;
  bool supported = false;
  bool isHardware = false;
  int maxWidth = 0;
  int maxHeight = 0;
  std::string decoderName;
  std::string mimeType;
  std::string errorMessage;
};

struct AudioCapResult {
  bool capabilityKnown = false;
  bool supported = false;
  bool isHardware = false;
  int maxChannels = 0;
  std::string decoderName;
  std::string mimeType;
  std::string errorMessage;
};

static std::string BuildVideoMime(const std::string &codecOrMime) {
  if (codecOrMime == "h264" || codecOrMime == "avc" || codecOrMime == "video/avc") return "video/avc";
  if (codecOrMime == "h265" || codecOrMime == "hevc" || codecOrMime == "video/hevc") return "video/hevc";
  if (codecOrMime == "vp9"  || codecOrMime == "video/x-vnd.on2.vp9") return "video/x-vnd.on2.vp9";
  return codecOrMime;
}

static std::string BuildAudioMime(const std::string &codecOrMime) {
  if (codecOrMime == "aac"  || codecOrMime == "audio/mp4a-latm") return "audio/mp4a-latm";
  if (codecOrMime == "opus" || codecOrMime == "audio/opus") return "audio/opus";
  if (codecOrMime == "flac" || codecOrMime == "audio/flac") return "audio/flac";
  if (codecOrMime == "mp3"  || codecOrMime == "audio/mpeg") return "audio/mpeg";
  return codecOrMime;
}

static napi_value MakeStringField(napi_env env, const std::string &s) {
  napi_value v = nullptr;
  napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &v);
  return v;
}

static VideoCapResult QueryVideoCapInternal(const std::string &codecOrMime) {
  VideoCapResult r;
  r.mimeType = BuildVideoMime(codecOrMime);
  r.capabilityKnown = true;

  // 先查硬件解码器
  OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory(r.mimeType.c_str(), false, HARDWARE);
  bool isHw = true;
  if (cap == nullptr) {
    // 回退到任意解码器
    cap = OH_AVCodec_GetCapability(r.mimeType.c_str(), false);
    isHw = (cap != nullptr) && OH_AVCapability_IsHardware(cap);
  }
  if (cap == nullptr) {
    r.errorMessage = "decoder not found";
    return r;
  }

  r.supported = true;
  r.isHardware = isHw;
  const char *name = OH_AVCapability_GetName(cap);
  if (name) r.decoderName = name;
  OH_AVRange wr = {0, 0}, hr = {0, 0};
  OH_AVCapability_GetVideoWidthRange(cap, &wr);
  OH_AVCapability_GetVideoHeightRange(cap, &hr);
  r.maxWidth  = wr.maxVal;
  r.maxHeight = hr.maxVal;
  return r;
}

static AudioCapResult QueryAudioCapInternal(const std::string &codecOrMime) {
  AudioCapResult r;
  r.mimeType = BuildAudioMime(codecOrMime);
  r.capabilityKnown = true;

  OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory(r.mimeType.c_str(), false, HARDWARE);
  bool isHw = true;
  if (cap == nullptr) {
    cap = OH_AVCodec_GetCapability(r.mimeType.c_str(), false);
    isHw = (cap != nullptr) && OH_AVCapability_IsHardware(cap);
  }
  if (cap == nullptr) {
    r.errorMessage = "decoder not found";
    return r;
  }

  r.supported = true;
  r.isHardware = isHw;
  const char *name = OH_AVCapability_GetName(cap);
  if (name) r.decoderName = name;
  OH_AVRange ch = {0, 0};
  OH_AVCapability_GetAudioChannelCountRange(cap, &ch);
  r.maxChannels = ch.maxVal;
  return r;
}

static napi_value QueryVideoDecoderCapability(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
    ThrowTypeError(env, "queryVideoDecoderCapability requires (codecOrMime)");
    return nullptr;
  }
  char buf[128] = {0};
  size_t len = 0;
  if (napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len) != napi_ok) {
    ThrowTypeError(env, "queryVideoDecoderCapability codecOrMime must be string");
    return nullptr;
  }

  VideoCapResult cap = QueryVideoCapInternal(std::string(buf, len));

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok) {
    ThrowTypeError(env, "queryVideoDecoderCapability failed to create result");
    return nullptr;
  }
  auto set = [&](const char *k, napi_value v) { napi_set_named_property(env, result, k, v); };
  set("capabilityKnown", CreateBoolean(env, cap.capabilityKnown));
  set("supported",       CreateBoolean(env, cap.supported));
  set("isHardware",      CreateBoolean(env, cap.isHardware));
  set("maxWidth",        CreateInt32(env, cap.maxWidth));
  set("maxHeight",       CreateInt32(env, cap.maxHeight));
  set("decoderName",     MakeStringField(env, cap.decoderName));
  set("mimeType",        MakeStringField(env, cap.mimeType));
  set("errorMessage",    MakeStringField(env, cap.errorMessage));
  return result;
}

static napi_value QueryAudioDecoderCapability(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
    ThrowTypeError(env, "queryAudioDecoderCapability requires (codecOrMime)");
    return nullptr;
  }
  char buf[128] = {0};
  size_t len = 0;
  if (napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len) != napi_ok) {
    ThrowTypeError(env, "queryAudioDecoderCapability codecOrMime must be string");
    return nullptr;
  }

  AudioCapResult cap = QueryAudioCapInternal(std::string(buf, len));

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok) {
    ThrowTypeError(env, "queryAudioDecoderCapability failed to create result");
    return nullptr;
  }
  auto set = [&](const char *k, napi_value v) { napi_set_named_property(env, result, k, v); };
  set("capabilityKnown", CreateBoolean(env, cap.capabilityKnown));
  set("supported",       CreateBoolean(env, cap.supported));
  set("isHardware",      CreateBoolean(env, cap.isHardware));
  set("maxChannels",     CreateInt32(env, cap.maxChannels));
  set("decoderName",     MakeStringField(env, cap.decoderName));
  set("mimeType",        MakeStringField(env, cap.mimeType));
  set("errorMessage",    MakeStringField(env, cap.errorMessage));
  return result;
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

// ============================================================
// VPE (Video Processing Engine) — AI 画质增强 (Detail Enhancer)
// API 12+，不支持的设备返回空字符串而不是报错
// 用 VIDALL_HAS_VPE 宏守卫，避免 IDE 在不支持的设备上误报警告
// ============================================================

#ifdef VIDALL_HAS_VPE

static OH_VideoProcessing*    g_vpeProcessor  = nullptr;
static OHNativeWindow*        g_vpeInputWindow  = nullptr;
static OHNativeWindow*        g_vpeDisplayWindow = nullptr;
static VideoProcessing_Callback* g_vpeCallback  = nullptr;
static std::mutex g_vpeMutex;

static void VpeOnError(OH_VideoProcessing* /*vp*/, VideoProcessing_ErrorCode error, void* /*userData*/) {
  OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE onError: %{public}d", static_cast<int>(error));
}

static void VpeOnState(OH_VideoProcessing* /*vp*/, VideoProcessing_State state, void* /*userData*/) {
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VPE onState: %{public}s",
    state == VIDEO_PROCESSING_STATE_RUNNING ? "RUNNING" : "STOPPED");
}

// 销毁现有 VPE 实例（调用方持锁）
static void DestroyVpeInstanceLocked() {
  if (g_vpeProcessor) {
    OH_VideoProcessing_Stop(g_vpeProcessor);
    OH_VideoProcessing_Destroy(g_vpeProcessor);
    g_vpeProcessor = nullptr;
  }
  if (g_vpeInputWindow) {
    OH_NativeWindow_DestroyNativeWindow(g_vpeInputWindow);
    g_vpeInputWindow = nullptr;
  }
  if (g_vpeDisplayWindow) {
    OH_NativeWindow_DestroyNativeWindow(g_vpeDisplayWindow);
    g_vpeDisplayWindow = nullptr;
  }
  if (g_vpeCallback) {
    OH_VideoProcessingCallback_Destroy(g_vpeCallback);
    g_vpeCallback = nullptr;
  }
  OH_VideoProcessing_DeinitializeEnvironment();
}

// isVpeDetailEnhancerSupported() → boolean
static napi_value IsVpeDetailEnhancerSupported(napi_env env, napi_callback_info /*info*/) {
  bool supported = false;
  if (OH_VideoProcessing_InitializeEnvironment() == VIDEO_PROCESSING_SUCCESS) {
    OH_VideoProcessing* probe = nullptr;
    if (OH_VideoProcessing_Create(&probe, VIDEO_PROCESSING_TYPE_DETAIL_ENHANCER) == VIDEO_PROCESSING_SUCCESS) {
      supported = true;
      OH_VideoProcessing_Destroy(probe);
    }
    OH_VideoProcessing_DeinitializeEnvironment();
  }
  napi_value result;
  napi_get_boolean(env, supported, &result);
  return result;
}

// createVpeDetailEnhancer(displaySurfaceId: string, qualityLevel: number) → string
// 成功返回 VPE 输入 surfaceId；失败/不支持返回空字符串（不抛异常）
static napi_value CreateVpeDetailEnhancer(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  auto returnEmpty = [&]() -> napi_value {
    napi_value empty;
    napi_create_string_utf8(env, "", 0, &empty);
    return empty;
  };

  if (argc < 2) return returnEmpty();

  char surfaceIdBuf[32] = {0};
  size_t strLen = 0;
  napi_get_value_string_utf8(env, argv[0], surfaceIdBuf, sizeof(surfaceIdBuf), &strLen);
  if (strLen == 0) return returnEmpty();

  int32_t qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
  napi_get_value_int32(env, argv[1], &qualityLevel);
  // 边界保护：确保 level 在有效范围内
  if (qualityLevel < VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_NONE ||
      qualityLevel > VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_HIGH) {
    qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
  }

  std::lock_guard<std::mutex> lock(g_vpeMutex);
  DestroyVpeInstanceLocked(); // 清理旧实例

  if (OH_VideoProcessing_InitializeEnvironment() != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: InitializeEnvironment failed");
    return returnEmpty();
  }

  if (OH_VideoProcessing_Create(&g_vpeProcessor, VIDEO_PROCESSING_TYPE_DETAIL_ENHANCER) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: Create failed (not supported on this device)");
    OH_VideoProcessing_DeinitializeEnvironment();
    return returnEmpty();
  }

  // 设置质量等级
  OH_AVFormat* param = OH_AVFormat_Create();
  OH_AVFormat_SetIntValue(param, VIDEO_DETAIL_ENHANCER_PARAMETER_KEY_QUALITY_LEVEL, qualityLevel);
  OH_VideoProcessing_SetParameter(g_vpeProcessor, param); // 失败不致命，使用默认
  OH_AVFormat_Destroy(param);

  // 注册回调（必须在 Start 前）
  OH_VideoProcessingCallback_Create(&g_vpeCallback);
  OH_VideoProcessingCallback_BindOnError(g_vpeCallback, VpeOnError);
  OH_VideoProcessingCallback_BindOnState(g_vpeCallback, VpeOnState);
  OH_VideoProcessing_RegisterCallback(g_vpeProcessor, g_vpeCallback, nullptr);

  // 从 surfaceId 字符串恢复 uint64_t
  uint64_t displaySurfaceId = strtoull(surfaceIdBuf, nullptr, 10);
  if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(displaySurfaceId, &g_vpeDisplayWindow) != 0) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: CreateNativeWindowFromSurfaceId failed for id=%{public}s", surfaceIdBuf);
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 绑定输出（VPE → 显示）
  if (OH_VideoProcessing_SetSurface(g_vpeProcessor, g_vpeDisplayWindow) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: SetSurface (output) failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 获取输入 Surface（解码器 → VPE）
  if (OH_VideoProcessing_GetSurface(g_vpeProcessor, &g_vpeInputWindow) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: GetSurface (input) failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 启动 VPE
  if (OH_VideoProcessing_Start(g_vpeProcessor) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: Start failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 获取输入 Surface 的 surfaceId，回传给 ArkTS
  uint64_t inputSurfaceId = 0;
  if (OH_NativeWindow_GetSurfaceId(g_vpeInputWindow, &inputSurfaceId) != 0) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: GetSurfaceId (input) failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  char inputIdBuf[32];
  snprintf(inputIdBuf, sizeof(inputIdBuf), "%llu", static_cast<unsigned long long>(inputSurfaceId));
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VPE: Created OK — inputSurfaceId=%{public}s quality=%{public}d",
    inputIdBuf, qualityLevel);

  napi_value result;
  napi_create_string_utf8(env, inputIdBuf, NAPI_AUTO_LENGTH, &result);
  return result;
}

// destroyVpeDetailEnhancer() → void
static napi_value DestroyVpeDetailEnhancer(napi_env env, napi_callback_info /*info*/) {
  std::lock_guard<std::mutex> lock(g_vpeMutex);
  DestroyVpeInstanceLocked();
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VPE: Destroyed");
  napi_value undef;
  napi_get_undefined(env, &undef);
  return undef;
}

// updateVpeQuality(level: number): void
// 动态更新已运行中的 VPE 质量参数（无需重建管线，避免 Surface 断开）
// level: 0=NONE(透传/关闭), 1=LOW, 2=MEDIUM, 3=HIGH
static napi_value UpdateVpeQuality(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int32_t qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
  if (argc >= 1) {
    napi_get_value_int32(env, argv[0], &qualityLevel);
    if (qualityLevel < VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_NONE ||
        qualityLevel > VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_HIGH) {
      qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_NONE;
    }
  }

  napi_value undef;
  napi_get_undefined(env, &undef);

  std::lock_guard<std::mutex> lock(g_vpeMutex);
  if (!g_vpeProcessor) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: updateQuality ignored (no processor)");
    return undef;
  }

  OH_AVFormat* param = OH_AVFormat_Create();
  OH_AVFormat_SetIntValue(param, VIDEO_DETAIL_ENHANCER_PARAMETER_KEY_QUALITY_LEVEL, qualityLevel);
  VideoProcessing_ErrorCode ret = OH_VideoProcessing_SetParameter(g_vpeProcessor, param);
  OH_AVFormat_Destroy(param);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
    "VPE: quality updated to %{public}d ret=%{public}d", qualityLevel, static_cast<int>(ret));
  return undef;
}

#else // !VIDALL_HAS_VPE — 桩函数（无 VPE 支持时保持 NAPI 表完整）
static napi_value IsVpeDetailEnhancerSupported(napi_env env, napi_callback_info /*info*/) {
  napi_value r; napi_get_boolean(env, false, &r); return r;
}
static napi_value CreateVpeDetailEnhancer(napi_env env, napi_callback_info /*info*/) {
  napi_value r; napi_create_string_utf8(env, "", 0, &r); return r;
}
static napi_value DestroyVpeDetailEnhancer(napi_env env, napi_callback_info /*info*/) {
  napi_value r; napi_get_undefined(env, &r); return r;
}
static napi_value UpdateVpeQuality(napi_env env, napi_callback_info /*info*/) {
  napi_value r; napi_get_undefined(env, &r); return r;
}
#endif // VIDALL_HAS_VPE

// ============================================================================
// SMB Protocol NAPI Functions
// ============================================================================

#if VIDALL_HAS_LIBSMB2

// ── 异步上下文：SmbTestConnection ──────────────────────────────────────────
struct SmbConnTestContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int64_t port = 445;
    std::string username;
    std::string password;
    std::string domain;
    std::string shareName;
    int64_t timeoutMs = 5000;
    bool success = false;
    std::string errorMessage;
};

static void ExecuteSmbTestConnection(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbConnTestContext *>(data);

    // ── TCP 预检：验证 host:port 是否可达，排除网络层问题 ──────────────────
    {
        int tcpFd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (tcpFd < 0) {
            ctx->errorMessage = std::string("socket() failed, errno:") + std::to_string(errno)
                                + " (" + std::strerror(errno) + ")";
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check: socket() failed errno=%{public}d", errno);
            return;
        }
        // 设置连接超时（非阻塞 connect + poll）
        int flags = ::fcntl(tcpFd, F_GETFL, 0);
        ::fcntl(tcpFd, F_SETFL, flags | O_NONBLOCK);

        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port   = htons((uint16_t)ctx->port);
        if (::inet_pton(AF_INET, ctx->host.c_str(), &addr.sin_addr) != 1) {
            // 非纯 IPv4 字面量（主机名/IPv6），跳过 TCP 预检，由 libsmb2 自行解析
            ::close(tcpFd);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient",
                "TCP pre-check skipped (not IPv4 literal), host=%{public}s", ctx->host.c_str());
        } else {

        int connRet = ::connect(tcpFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        if (connRet < 0 && errno != EINPROGRESS) {
            int savedErrno = errno;
            ::close(tcpFd);
            ctx->errorMessage = std::string("TCP connect() failed, host=") + ctx->host
                                + " port=" + std::to_string(ctx->port)
                                + " errno:" + std::to_string(savedErrno)
                                + " (" + std::strerror(savedErrno) + ")";
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check failed errno=%{public}d host=%{public}s port=%{public}lld",
                        savedErrno, ctx->host.c_str(), (long long)ctx->port);
            return;
        }
        // 等待连接完成
        int timeoutMs = (ctx->timeoutMs > 0 && ctx->timeoutMs < 10000) ? (int)ctx->timeoutMs : 5000;
        struct pollfd pfd{};
        pfd.fd = tcpFd;
        pfd.events = POLLOUT;
        int pollRet = ::poll(&pfd, 1, timeoutMs);
        if (pollRet <= 0) {
            ::close(tcpFd);
            ctx->errorMessage = std::string("TCP connect timeout/error, host=") + ctx->host
                                + " port=" + std::to_string(ctx->port)
                                + (pollRet == 0 ? " (timed out)" : " (poll error)");
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check poll ret=%{public}d host=%{public}s port=%{public}lld",
                        pollRet, ctx->host.c_str(), (long long)ctx->port);
            return;
        }
        // 检查 SO_ERROR
        int soErr = 0;
        socklen_t soErrLen = sizeof(soErr);
        int gsRet = ::getsockopt(tcpFd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen);
        ::close(tcpFd);
        if (gsRet != 0 || soErr != 0) {
            int finalErr = (gsRet != 0) ? errno : soErr;
            ctx->errorMessage = std::string("TCP connect refused/error, host=") + ctx->host
                                + " port=" + std::to_string(ctx->port)
                                + " errno:" + std::to_string(finalErr)
                                + " (" + std::strerror(finalErr) + ")";
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check SO_ERROR=%{public}d host=%{public}s port=%{public}lld",
                        finalErr, ctx->host.c_str(), (long long)ctx->port);
            return;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient", "TCP pre-check OK host=%{public}s port=%{public}lld",
                    ctx->host.c_str(), (long long)ctx->port);
        } // end IPv4 pre-check else
    }


    // ── libsmb2 连接 ──────────────────────────────────────────────────────
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!ctx->username.empty()) smb2_set_user(smb2, ctx->username.c_str());
    if (!ctx->password.empty()) smb2_set_password(smb2, ctx->password.c_str());
    if (!ctx->domain.empty()) smb2_set_domain(smb2, ctx->domain.c_str());
    int timeoutSec = (ctx->timeoutMs > 0) ? (int)(ctx->timeoutMs / 1000) : 5;
    if (timeoutSec < 1) timeoutSec = 1;
    smb2_set_timeout(smb2, timeoutSec);
    // 当 shareName 为空时，连接 IPC$（纯认证验证，不依赖具体共享名）
    const char *connectShare = ctx->shareName.empty() ? "IPC$" : ctx->shareName.c_str();
    int ret = smb2_connect_share(smb2, ctx->host.c_str(), connectShare,
                                  ctx->username.empty() ? nullptr : ctx->username.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "SMB connection failed";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "smb2_connect_share failed: %{public}s", ctx->errorMessage.c_str());
    } else {
        ctx->success = true;
        smb2_disconnect_share(smb2);
    }
    smb2_destroy_context(smb2);
}

static void CompleteSmbTestConnection(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbConnTestContext *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value successVal = nullptr;
    napi_get_boolean(env, ctx->success, &successVal);
    napi_set_named_property(env, result, "success", successVal);
    if (!ctx->success && !ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

// ── 异步上下文：SmbListDirectory ───────────────────────────────────────────
struct SmbFileEntry {
    std::string name;
    std::string path;           // 完整相对路径（dirPath/name），由 ArkTS 层基于 shareName+subPath 拼接
    bool isDirectory = false;
    uint64_t size = 0;
    uint64_t lastModified = 0;  // Unix epoch 毫秒（ms），对齐 ArkTS 侧 lastModifiedMs
};

struct SmbListDirContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int64_t port = 445;
    std::string username;
    std::string password;
    std::string domain;
    std::string shareName;
    std::string path;
    int64_t timeoutMs = 10000;
    std::vector<SmbFileEntry> files;
    std::string errorMessage;
};

// Windows FILETIME（100ns intervals since 1601-01-01）转为 POSIX 秒
static inline int64_t WinTimeToUnix(uint64_t winTime) {
    if (winTime == 0) return 0;
    return (int64_t)(winTime / 10000000ULL) - (int64_t)11644473600LL;
}

static void ExecuteSmbListDirectory(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbListDirContext *>(data);
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!ctx->username.empty()) smb2_set_user(smb2, ctx->username.c_str());
    if (!ctx->password.empty()) smb2_set_password(smb2, ctx->password.c_str());
    if (!ctx->domain.empty()) smb2_set_domain(smb2, ctx->domain.c_str());
    int timeoutSec = (ctx->timeoutMs > 0) ? (int)(ctx->timeoutMs / 1000) : 10;
    smb2_set_timeout(smb2, timeoutSec);
    int ret = smb2_connect_share(smb2, ctx->host.c_str(), ctx->shareName.c_str(),
                                  ctx->username.empty() ? nullptr : ctx->username.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "SMB connection failed";
        smb2_destroy_context(smb2);
        return;
    }
    // 空字符串表示 share 根目录（libsmb2 期望 ""，传 "/" 会触发 Windows STATUS_INVALID_PARAMETER）
    const char *dirPath = ctx->path.c_str();
    struct smb2dir *dir = smb2_opendir(smb2, dirPath);
    if (!dir) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "opendir failed";
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }
    struct smb2dirent *ent;
    while ((ent = smb2_readdir(smb2, dir)) != nullptr) {
        if (!ent->name) continue;
        if (std::strcmp(ent->name, ".") == 0 || std::strcmp(ent->name, "..") == 0) continue;
        SmbFileEntry entry;
        entry.name = ent->name;
        // 构造完整路径：dir/name（ArkTS 层不应再 re-derive）
        {
            std::string base = dirPath;
            while (!base.empty() && base.back() == '/') base.pop_back();
            entry.path = base + "/" + ent->name;
        }
        entry.isDirectory = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY);
        entry.size = ent->st.smb2_size;
        entry.lastModified = (uint64_t)WinTimeToUnix(ent->st.smb2_mtime) * 1000ULL;  // 转毫秒
        ctx->files.push_back(std::move(entry));
    }
    smb2_closedir(smb2, dir);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
}

// ── 异步上下文：SmbListShares ──────────────────────────────────────────────
struct SmbShareEntry {
    std::string name;
    std::string remark;
    uint32_t type = 0;
};

struct SmbListSharesContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int64_t port = 445;
    std::string username;
    std::string password;
    std::string domain;
    int64_t timeoutMs = 10000;
    std::vector<SmbShareEntry> shares;
    std::string errorMessage;
};

static void ExecuteSmbListShares(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbListSharesContext *>(data);
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!ctx->username.empty()) smb2_set_user(smb2, ctx->username.c_str());
    if (!ctx->password.empty()) smb2_set_password(smb2, ctx->password.c_str());
    if (!ctx->domain.empty()) smb2_set_domain(smb2, ctx->domain.c_str());
    int timeoutSec = (ctx->timeoutMs > 0) ? (int)(ctx->timeoutMs / 1000) : 10;
    if (timeoutSec < 1) timeoutSec = 1;
    smb2_set_timeout(smb2, timeoutSec);

    // 连接到 IPC$ 共享（SMB 共享枚举的标准路径）
    int ret = smb2_connect_share(smb2, ctx->host.c_str(), "IPC$",
                                  ctx->username.empty() ? nullptr : ctx->username.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "Failed to connect to IPC$";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "smbListShares IPC$ connect failed: %{public}s", ctx->errorMessage.c_str());
        smb2_destroy_context(smb2);
        return;
    }

    struct srvsvc_NetrShareEnum_rep *rep = smb2_share_enum_sync(smb2, SHARE_INFO_1);
    if (!rep) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_share_enum failed";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "smbListShares enum failed: %{public}s", ctx->errorMessage.c_str());
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    uint32_t count = rep->ses.ShareInfo.Level1.EntriesRead;
    struct srvsvc_SHARE_INFO_1_carray *buf = rep->ses.ShareInfo.Level1.Buffer;
    for (uint32_t i = 0; i < count && buf; i++) {
        struct srvsvc_SHARE_INFO_1 &si = buf->share_info_1[i];
        SmbShareEntry entry;
        entry.name   = si.netname.utf8 ? si.netname.utf8 : "";
        entry.remark = si.remark.utf8  ? si.remark.utf8  : "";
        entry.type   = si.type;
        ctx->shares.push_back(std::move(entry));
    }
    smb2_free_data(smb2, rep);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
}

static void CompleteSmbListShares(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbListSharesContext *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        napi_value errStr = nullptr;
        napi_create_string_utf8(env, "NAPI internal error: failed to create result object",
                                NAPI_AUTO_LENGTH, &errStr);
        napi_reject_deferred(env, ctx->deferred, errStr);
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value sharesArr = nullptr;
    napi_create_array_with_length(env, ctx->shares.size(), &sharesArr);
    for (size_t i = 0; i < ctx->shares.size(); i++) {
        const auto &s = ctx->shares[i];
        napi_value shareObj = nullptr;
        napi_create_object(env, &shareObj);
        napi_value nm = nullptr;
        napi_create_string_utf8(env, s.name.c_str(), NAPI_AUTO_LENGTH, &nm);
        napi_set_named_property(env, shareObj, "name", nm);
        napi_value rmk = nullptr;
        napi_create_string_utf8(env, s.remark.c_str(), NAPI_AUTO_LENGTH, &rmk);
        napi_set_named_property(env, shareObj, "remark", rmk);
        napi_value tp = nullptr;
        napi_create_uint32(env, s.type, &tp);
        napi_set_named_property(env, shareObj, "type", tp);
        napi_set_element(env, sharesArr, (uint32_t)i, shareObj);
    }
    napi_set_named_property(env, result, "shares", sharesArr);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static void CompleteSmbListDirectory(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbListDirContext *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        napi_value errStr = nullptr;
        napi_create_string_utf8(env, "NAPI internal error: failed to create result object",
                                NAPI_AUTO_LENGTH, &errStr);
        napi_reject_deferred(env, ctx->deferred, errStr);
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value filesArr = nullptr;
    napi_create_array_with_length(env, ctx->files.size(), &filesArr);
    for (size_t i = 0; i < ctx->files.size(); i++) {
        const auto &f = ctx->files[i];
        napi_value fileObj = nullptr;
        napi_create_object(env, &fileObj);
        napi_value nm = nullptr;
        napi_create_string_utf8(env, f.name.c_str(), NAPI_AUTO_LENGTH, &nm);
        napi_set_named_property(env, fileObj, "name", nm);
        napi_value pathVal = nullptr;
        napi_create_string_utf8(env, f.path.c_str(), NAPI_AUTO_LENGTH, &pathVal);
        napi_set_named_property(env, fileObj, "path", pathVal);
        napi_value isDir = nullptr;
        napi_get_boolean(env, f.isDirectory, &isDir);
        napi_set_named_property(env, fileObj, "isDirectory", isDir);
        napi_value sz = nullptr;
        napi_create_int64(env, (int64_t)f.size, &sz);
        napi_set_named_property(env, fileObj, "size", sz);
        napi_value lm = nullptr;
        napi_create_int64(env, (int64_t)f.lastModified, &lm);
        napi_set_named_property(env, fileObj, "lastModified", lm);
        napi_set_element(env, filesArr, (uint32_t)i, fileObj);
    }
    napi_set_named_property(env, result, "files", filesArr);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

#endif // VIDALL_HAS_LIBSMB2

/**
 * smbListShares(host, port, username, password, domain, timeoutMs)
 * -> Promise<{ shares: Array<{name, remark, type}>, error?: string }>
 *
 * 连接到服务器的 IPC$ 共享，枚举所有磁盘共享（type & 3 == SHARE_TYPE_DISKTREE）。
 * 不需要预先知道共享名。
 */
static napi_value SmbListShares(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbListShares failed to read args");
        return nullptr;
    }
    if (argc < 6) {
        ThrowTypeError(env, "smbListShares requires (host, port, username, password, domain, timeoutMs)");
        return nullptr;
    }

    std::string host, username, password, domain;
    int64_t port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], host)) {
        ThrowTypeError(env, "smbListShares host must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &port) != napi_ok) {
        ThrowTypeError(env, "smbListShares port must be int64");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[2], username)) {
        ThrowTypeError(env, "smbListShares username must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[3], password)) {
        ThrowTypeError(env, "smbListShares password must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[4], domain)) {
        ThrowTypeError(env, "smbListShares domain must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[5], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbListShares timeoutMs must be int64");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbListShares failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbListSharesContext();
        ctx->deferred = deferred;
        ctx->host = host;
        ctx->port = port;
        ctx->username = username;
        ctx->password = password;
        ctx->domain = domain;
        ctx->timeoutMs = timeoutMs;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbListSharesAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListShares failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbListShares, CompleteSmbListShares,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListShares failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbListShares failed to queue async work");
            return nullptr;
        }
    }
#else
    {
        napi_value result = nullptr;
        napi_create_object(env, &result);
        napi_value sharesArr = nullptr;
        napi_create_array(env, &sharesArr);
        napi_set_named_property(env, result, "shares", sharesArr);
        napi_value errorMsg = nullptr;
        napi_create_string_utf8(env,
            "SMB protocol not yet available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg);
        napi_set_named_property(env, result, "error", errorMsg);
        napi_resolve_deferred(env, deferred, result);
    }
#endif

    return promise;
}


/**
 * smbDiscoverHosts(subnetPrefix, startOctet, endOctet, port, timeoutMs)
 * -> Promise<{ hosts: string[]; error?: string }>
 *
 * 并发扫描指定子网（subnetPrefix + startOctet..endOctet）的 TCP 端口，
 * 返回在 timeoutMs 内成功建立连接的主机 IP 列表。
 * 不依赖 libsmb2，使用纯 POSIX socket。
 */
struct SmbDiscoverCtx {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string subnetPrefix;   // 如 "192.168.3."
    int startOctet = 1;
    int endOctet = 254;
    int port = 445;
    int timeoutMs = 3000;
    std::vector<std::string> hosts;
    std::string errorMessage;
};

static void ExecuteSmbDiscoverHosts(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbDiscoverCtx *>(data);

    struct Probe {
        int fd = -1;
        std::string ip;
        bool done = false;
    };

    int count = ctx->endOctet - ctx->startOctet + 1;
    if (count <= 0) return;

    std::vector<Probe> probes(count);
    for (int i = 0; i < count; i++) {
        int octet = ctx->startOctet + i;
        std::string ip = ctx->subnetPrefix + std::to_string(octet);
        int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) continue;
        // 非阻塞
        int flags = ::fcntl(fd, F_GETFL, 0);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            ::close(fd);
            continue;
        }
        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)ctx->port);
        if (::inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) != 1) {
            ::close(fd);
            continue;
        }
        ::connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
        probes[i] = { fd, ip, false };
    }

    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(ctx->timeoutMs);

    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now >= deadline) break;

        auto remMs = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
        int pollTimeout = (int)std::min(remMs, (long long)100);

        std::vector<struct pollfd> pfds;
        std::vector<int> indices;
        pfds.reserve(count);
        indices.reserve(count);
        for (int j = 0; j < count; j++) {
            if (!probes[j].done && probes[j].fd >= 0) {
                struct pollfd pfd{};
                pfd.fd = probes[j].fd;
                pfd.events = POLLOUT;
                pfds.push_back(pfd);
                indices.push_back(j);
            }
        }
        if (pfds.empty()) break;

        int n = ::poll(pfds.data(), (nfds_t)pfds.size(), pollTimeout);
        if (n < 0) continue;

        for (size_t k = 0; k < pfds.size(); k++) {
            if (pfds[k].revents & (POLLOUT | POLLERR | POLLHUP)) {
                int j = indices[k];
                probes[j].done = true;
                int err = 0;
                socklen_t errlen = sizeof(err);
                if (::getsockopt(pfds[k].fd, SOL_SOCKET, SO_ERROR, &err, &errlen) == 0 && err == 0) {
                    ctx->hosts.push_back(probes[j].ip);
                }
                ::close(pfds[k].fd);
                probes[j].fd = -1;
            }
        }
    }

    for (auto &p : probes) {
        if (p.fd >= 0) ::close(p.fd);
    }
}

static void CompleteSmbDiscoverHosts(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbDiscoverCtx *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        napi_value errStr = nullptr;
        napi_create_string_utf8(env, "NAPI internal error: failed to create result object",
                                NAPI_AUTO_LENGTH, &errStr);
        napi_reject_deferred(env, ctx->deferred, errStr);
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value hostsArr = nullptr;
    napi_create_array_with_length(env, ctx->hosts.size(), &hostsArr);
    for (size_t i = 0; i < ctx->hosts.size(); i++) {
        napi_value ipVal = nullptr;
        napi_create_string_utf8(env, ctx->hosts[i].c_str(), NAPI_AUTO_LENGTH, &ipVal);
        napi_set_element(env, hostsArr, (uint32_t)i, ipVal);
    }
    napi_set_named_property(env, result, "hosts", hostsArr);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value SmbDiscoverHosts(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 5) {
        ThrowTypeError(env, "smbDiscoverHosts requires (subnetPrefix, startOctet, endOctet, port, timeoutMs)");
        return nullptr;
    }
    std::string subnetPrefix;
    int64_t startOctet = 0, endOctet = 0, port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], subnetPrefix)) {
        ThrowTypeError(env, "smbDiscoverHosts subnetPrefix must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &startOctet) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts startOctet must be int64");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[2], &endOctet) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts endOctet must be int64");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[3], &port) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts port must be int64");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[4], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts timeoutMs must be int64");
        return nullptr;
    }
    // 参数范围校验，防止 FD/内存耗尽
    if (startOctet < 0 || startOctet > 255 || endOctet < 0 || endOctet > 255 || endOctet < startOctet) {
        ThrowTypeError(env, "smbDiscoverHosts: octet must be in [0,255] with startOctet <= endOctet");
        return nullptr;
    }
    if (endOctet - startOctet + 1 > 254) {
        ThrowTypeError(env, "smbDiscoverHosts: scan range too large (max 254 hosts)");
        return nullptr;
    }
    if (port < 1 || port > 65535) {
        ThrowTypeError(env, "smbDiscoverHosts: port must be in [1,65535]");
        return nullptr;
    }
    if (timeoutMs <= 0 || timeoutMs > 30000) {
        ThrowTypeError(env, "smbDiscoverHosts: timeoutMs must be in (0, 30000]");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts failed to create promise");
        return nullptr;
    }

    auto *ctx = new SmbDiscoverCtx();
    ctx->deferred = deferred;
    ctx->subnetPrefix = subnetPrefix;
    ctx->startOctet = (int)startOctet;
    ctx->endOctet = (int)endOctet;
    ctx->port = (int)port;
    ctx->timeoutMs = (int)timeoutMs;

    napi_value resourceName = nullptr;
    if (napi_create_string_utf8(env, "smbDiscoverHostsAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
        delete ctx;
        ThrowTypeError(env, "smbDiscoverHosts failed to create resource name");
        return nullptr;
    }
    if (napi_create_async_work(env, nullptr, resourceName,
                               ExecuteSmbDiscoverHosts, CompleteSmbDiscoverHosts,
                               ctx, &ctx->work) != napi_ok) {
        delete ctx;
        ThrowTypeError(env, "smbDiscoverHosts failed to create async work");
        return nullptr;
    }
    if (napi_queue_async_work(env, ctx->work) != napi_ok) {
        napi_delete_async_work(env, ctx->work);
        delete ctx;
        ThrowTypeError(env, "smbDiscoverHosts failed to queue async work");
        return nullptr;
    }
    return promise;
}

/**
 * smbTestConnection(host, port, username, password, domain, shareName, timeoutMs)
 * -> Promise<{ success: boolean; error?: string; serverInfo?: string }>
 *
 * 阶段一（VIDALL_HAS_LIBSMB2=0）：返回未实现提示
 * 阶段二（VIDALL_HAS_LIBSMB2=1）：调用 libsmb2 真实连接
 */
static napi_value SmbTestConnection(napi_env env, napi_callback_info info) {
    // ── 参数校验（仿照 Ffprobe / WebdavRequest 模式）─────────────────────────
    size_t argc = 7;
    napi_value args[7] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection failed to read args");
        return nullptr;
    }
    if (argc < 7) {
        ThrowTypeError(env, "smbTestConnection requires (host, port, username, password, domain, shareName, timeoutMs)");
        return nullptr;
    }

    std::string host, username, password, domain, shareName;
    int64_t port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], host)) {
        ThrowTypeError(env, "smbTestConnection host must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &port) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection port must be int64");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[2], username)) {
        ThrowTypeError(env, "smbTestConnection username must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[3], password)) {
        ThrowTypeError(env, "smbTestConnection password must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[4], domain)) {
        ThrowTypeError(env, "smbTestConnection domain must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[5], shareName)) {
        ThrowTypeError(env, "smbTestConnection shareName must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[6], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection timeoutMs must be int64");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbConnTestContext();
        ctx->deferred = deferred;
        ctx->host = host;
        ctx->port = port;
        ctx->username = username;
        ctx->password = password;
        ctx->domain = domain;
        ctx->shareName = shareName;
        ctx->timeoutMs = timeoutMs;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbTestConnectionAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbTestConnection failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbTestConnection, CompleteSmbTestConnection,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbTestConnection failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbTestConnection failed to queue async work");
            return nullptr;
        }
    }
#else
    // libsmb2 未启用，返回明确的未实现状态
    {
        napi_value result = nullptr;
        if (napi_create_object(env, &result) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to create result object");
            return nullptr;
        }
        napi_value successVal = nullptr;
        if (napi_get_boolean(env, false, &successVal) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to create boolean");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "success", successVal) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to set success");
            return nullptr;
        }
        napi_value errorMsg = nullptr;
        if (napi_create_string_utf8(env,
            "SMB protocol not yet available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to create error string");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "error", errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to set error");
            return nullptr;
        }
        if (napi_resolve_deferred(env, deferred, result) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to resolve deferred");
            return nullptr;
        }
    }
#endif

    return promise;
}

/**
 * smbListDirectory(host, port, username, password, domain, shareName, path, timeoutMs)
 * -> Promise<{ files: SmbFileInfo[]; error?: string }>
 *
 * SmbFileInfo: { name, path, isDirectory, size, lastModified }
 */
static napi_value SmbListDirectory(napi_env env, napi_callback_info info) {
    // ── 参数校验（仿照 Ffprobe / WebdavRequest 模式）─────────────────────────
    size_t argc = 8;
    napi_value args[8] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory failed to read args");
        return nullptr;
    }
    if (argc < 8) {
        ThrowTypeError(env, "smbListDirectory requires (host, port, username, password, domain, shareName, path, timeoutMs)");
        return nullptr;
    }

    std::string host, username, password, domain, shareName, path;
    int64_t port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], host)) {
        ThrowTypeError(env, "smbListDirectory host must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &port) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory port must be int64");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[2], username)) {
        ThrowTypeError(env, "smbListDirectory username must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[3], password)) {
        ThrowTypeError(env, "smbListDirectory password must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[4], domain)) {
        ThrowTypeError(env, "smbListDirectory domain must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[5], shareName)) {
        ThrowTypeError(env, "smbListDirectory shareName must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[6], path)) {
        ThrowTypeError(env, "smbListDirectory path must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[7], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory timeoutMs must be int64");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbListDirContext();
        ctx->deferred = deferred;
        ctx->host = host;
        ctx->port = port;
        ctx->username = username;
        ctx->password = password;
        ctx->domain = domain;
        ctx->shareName = shareName;
        ctx->path = path;
        ctx->timeoutMs = timeoutMs;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbListDirectoryAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListDirectory failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbListDirectory, CompleteSmbListDirectory,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListDirectory failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbListDirectory failed to queue async work");
            return nullptr;
        }
    }
#else
    // libsmb2 未启用，返回空文件列表和错误信息
    {
        napi_value result = nullptr;
        if (napi_create_object(env, &result) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to create result object");
            return nullptr;
        }
        napi_value filesArr = nullptr;
        if (napi_create_array(env, &filesArr) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to create files array");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "files", filesArr) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to set files property");
            return nullptr;
        }
        napi_value errorMsg = nullptr;
        if (napi_create_string_utf8(env,
            "SMB protocol not yet available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to create error string");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "error", errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to set error property");
            return nullptr;
        }
        if (napi_resolve_deferred(env, deferred, result) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to resolve deferred");
            return nullptr;
        }
    }
#endif

    return promise;
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
    { "getProxyUrl", nullptr, GetProxyUrl, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "getCurrentTime", nullptr, GetCurrentTime, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "getDuration", nullptr, GetDuration, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setCallbacks", nullptr, SetCallbacks, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "ffprobe", nullptr, Ffprobe, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "ffmpegSelfCheck", nullptr, FfmpegSelfCheck, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "webdavRequest", nullptr, WebdavRequest, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "downloadToFile", nullptr, DownloadToFile, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "getNativeCapabilities", nullptr, GetNativeCapabilities, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "queryVideoDecoderCapability", nullptr, QueryVideoDecoderCapability, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "queryAudioDecoderCapability", nullptr, QueryAudioDecoderCapability, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "isVpeDetailEnhancerSupported", nullptr, IsVpeDetailEnhancerSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "createVpeDetailEnhancer", nullptr, CreateVpeDetailEnhancer, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "destroyVpeDetailEnhancer", nullptr, DestroyVpeDetailEnhancer, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "updateVpeQuality", nullptr, UpdateVpeQuality, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "extractSubtitleEntries", nullptr, ExtractSubtitleEntries, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbTestConnection", nullptr, SmbTestConnection, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbListDirectory",  nullptr, SmbListDirectory,  nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbListShares",     nullptr, SmbListShares,     nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbDiscoverHosts",  nullptr, SmbDiscoverHosts,  nullptr, nullptr, nullptr, napi_default, nullptr }
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