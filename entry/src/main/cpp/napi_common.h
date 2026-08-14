// ============================================================================
// napi_common.h — vidall_core_player_napi 共享工具声明
//
// 供 ffprobe / subtitle / webdav / audio / vpe / smb / player 各域共用。
// 定义与实现见 napi_common.cpp。
// ============================================================================
#ifndef VIDALL_NAPI_COMMON_H
#define VIDALL_NAPI_COMMON_H

#include <string>
#include <cstdint>
#include <mutex>

#include "napi/native_api.h"

// 条件编译宏兜底（CMake 通常通过 target_compile_definitions 注入，
// 这里兜底便于 IDE 单文件编译与 lint）。
#if !defined(VIDALL_HAS_LIBCURL)
#define VIDALL_HAS_LIBCURL 0
#endif
#if !defined(VIDALL_HAS_LIBSMB2)
#define VIDALL_HAS_LIBSMB2 0
#endif
#if !defined(VIDALL_HAS_OH_AVPLAYER)
#define VIDALL_HAS_OH_AVPLAYER 0
#endif
#if !defined(VIDALL_HAS_VPE)
#define VIDALL_HAS_VPE 0
#endif

// ============================================================================
// SMB URL components – filled by ParseSmbUrl()
// ============================================================================
struct SmbUrlComponents {
  std::string host;
  int port = 445;
  std::string user;
  std::string password;
  std::string share;
  std::string subPath;  // file path within share, no leading /
  bool valid = false;
};

// ============================================================================
// URL / SMB URL helpers
// ============================================================================
std::string PercentDecode(const std::string &s);
std::string PercentEncodePathSegment(const std::string &s);
std::string PercentEncodePath(const std::string &path);
SmbUrlComponents ParseSmbUrl(const std::string &url);
std::string BuildSmbConnectHost(const std::string &host, int64_t port);

// ============================================================================
// 错误抛出 / 参数读取 / 值构造
// ============================================================================
void ThrowTypeError(napi_env env, const char *message);
void ThrowRangeError(napi_env env, const char *message);
bool ReadUtf8String(napi_env env, napi_value value, std::string &output);
napi_value CreateInt32(napi_env env, int32_t value);
napi_value CreateInt64(napi_env env, int64_t value);
napi_value CreateUint32(napi_env env, uint32_t value);
napi_value CreateBoolean(napi_env env, bool value);

// ============================================================================
// ffprobe 中断探测（ffprobe 与字幕提取共用）
// ============================================================================
struct ProbeInterruptContext {
  int64_t startTimeUs = 0;
  int64_t timeoutUs = 0;
};
int ProbeInterruptCallback(void *opaque);

// ============================================================================
// JSON 构建
// ============================================================================
std::string JsonEscape(const std::string &value);
void AppendJsonStringField(std::string &json, const char *key, const std::string &value, bool &firstField);
void AppendJsonIntField(std::string &json, const char *key, int64_t value, bool &firstField);
std::string FfmpegErrorToString(int errnum);

// ============================================================================
// libavformat 网络层初始化（修复 SIGSEGV #169）
// ============================================================================
void VidAllEnsureAvNetworkInit();
bool VidAllAvNetworkReady();
void VidAllDeinitAvNetwork();
extern std::mutex g_ffmpegNetworkMutex;

#endif // VIDALL_NAPI_COMMON_H
