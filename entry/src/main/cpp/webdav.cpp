#include "napi_common.h"
#include "webdav.h"
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
#include <limits>
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
#if VIDALL_HAS_LIBCURL
#include <curl/curl.h>
#endif
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#if VIDALL_HAS_LIBSMB2
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include <smb2/libsmb2-dcerpc-srvsvc.h>
#endif
namespace vidall {

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

napi_value WebdavRequest(napi_env env, napi_callback_info info) {
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

napi_value DownloadToFile(napi_env env, napi_callback_info info) {
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

} // namespace vidall
