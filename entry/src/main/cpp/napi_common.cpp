// ============================================================================
// napi_common.cpp — 共享工具实现
// ============================================================================
#include "napi_common.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <atomic>
#include <vector>

#include <hilog/log.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/time.h>
}

// ============================================================================
// URL percent 编解码
// ============================================================================

// URL percent-decode: "%XX" → byte
std::string PercentDecode(const std::string &s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ) {
    if (s[i] == '%' && i + 2 < s.size() &&
        std::isxdigit((unsigned char)s[i + 1]) &&
        std::isxdigit((unsigned char)s[i + 2])) {
      char hex[3] = { s[i + 1], s[i + 2], '\0' };
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
std::string PercentEncodePathSegment(const std::string &s) {
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
std::string PercentEncodePath(const std::string &path) {
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
SmbUrlComponents ParseSmbUrl(const std::string &url) {
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
      c.user = PercentDecode(userInfo.substr(0, colonPos));
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
    try {
      c.port = std::stoi(hostPort.substr(colonPos + 1));
    } catch (...) {
      c.port = 445;
    }
  } else {
    c.host = hostPort;
    c.port = 445;
  }

  // Extract share[/subPath]
  auto slash2 = pathPart.find('/');
  if (slash2 != std::string::npos) {
    c.share = PercentDecode(pathPart.substr(0, slash2));
    c.subPath = PercentDecode(pathPart.substr(slash2 + 1));
  } else {
    c.share = PercentDecode(pathPart);
    c.subPath = std::string();
  }

  c.valid = !c.host.empty() && !c.share.empty() && !c.subPath.empty();
  return c;
}

// ============================================================================
// 错误抛出 / 值构造 / 参数读取
// ============================================================================

void ThrowTypeError(napi_env env, const char *message) {
  napi_throw_type_error(env, nullptr, message);
}

void ThrowRangeError(napi_env env, const char *message) {
  napi_throw_range_error(env, nullptr, message);
}

napi_value CreateInt32(napi_env env, int32_t value) {
  napi_value result = nullptr;
  if (napi_create_int32(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

napi_value CreateInt64(napi_env env, int64_t value) {
  napi_value result = nullptr;
  if (napi_create_int64(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

napi_value CreateUint32(napi_env env, uint32_t value) {
  napi_value result = nullptr;
  if (napi_create_uint32(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

napi_value CreateBoolean(napi_env env, bool value) {
  napi_value result = nullptr;
  if (napi_get_boolean(env, value, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

bool ReadUtf8String(napi_env env, napi_value value, std::string &output) {
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

// ============================================================================
// ffprobe 中断探测
// ============================================================================
int ProbeInterruptCallback(void *opaque) {
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

// ============================================================================
// JSON 构建
// ============================================================================

std::string JsonEscape(const std::string &value) {
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

void AppendJsonStringField(std::string &json, const char *key, const std::string &value, bool &firstField) {
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

void AppendJsonIntField(std::string &json, const char *key, int64_t value, bool &firstField) {
  if (!firstField) {
    json += ",";
  }
  firstField = false;
  json += "\"";
  json += key;
  json += "\":";
  json += std::to_string(value);
}

std::string FfmpegErrorToString(int errnum) {
  char buffer[AV_ERROR_MAX_STRING_SIZE] = { 0 };
  av_make_error_string(buffer, sizeof(buffer), errnum);
  return std::string(buffer);
}

// ============================================================================
// libavformat 网络层初始化（修复 SIGSEGV #169）
// ============================================================================
static std::once_flag g_avNetworkInitFlag;
static std::atomic<bool> g_avNetworkReady{ false };
std::mutex g_ffmpegNetworkMutex;

void VidAllEnsureAvNetworkInit() {
  std::call_once(g_avNetworkInitFlag, []() {
    int ret = avformat_network_init();
    if (ret >= 0) {
      g_avNetworkReady.store(true);
    } else {
      OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "VidAllEnsureAvNetworkInit",
                   "avformat_network_init failed: %d", ret);
    }
  });
}

bool VidAllAvNetworkReady() {
  return g_avNetworkReady.load();
}

void VidAllDeinitAvNetwork() {
  std::lock_guard<std::mutex> lock(g_ffmpegNetworkMutex);
  if (g_avNetworkReady.exchange(false)) {
    avformat_network_deinit();
  }
}

