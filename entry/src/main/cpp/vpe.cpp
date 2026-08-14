#include "napi_common.h"
#include "vpe.h"
#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>
#include <cstdlib>
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
#if VIDALL_HAS_VPE
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

// ============================================================

#if VIDALL_HAS_VPE

static OH_VideoProcessing*    g_vpeProcessor  = nullptr;
static OHNativeWindow*        g_vpeInputWindow  = nullptr;
static OHNativeWindow*        g_vpeDisplayWindow = nullptr;
static VideoProcessing_Callback* g_vpeCallback  = nullptr;
static std::mutex g_vpeMutex;
static void* g_vpeLibraryHandle = nullptr;
static bool g_vpeLibraryLoadAttempted = false;
static bool g_vpeRuntimeSupportProbed = false;
static bool g_vpeRuntimeSupported = false;
static bool g_vpeEnvironmentInitialized = false;
static std::string g_vpeRuntimeStatusDetail;

struct VpeRuntimeSymbols {
  decltype(&OH_VideoProcessing_InitializeEnvironment) initializeEnvironment = nullptr;
  decltype(&OH_VideoProcessing_DeinitializeEnvironment) deinitializeEnvironment = nullptr;
  decltype(&OH_VideoProcessing_Create) create = nullptr;
  decltype(&OH_VideoProcessing_Destroy) destroy = nullptr;
  decltype(&OH_VideoProcessing_RegisterCallback) registerCallback = nullptr;
  decltype(&OH_VideoProcessing_SetSurface) setSurface = nullptr;
  decltype(&OH_VideoProcessing_GetSurface) getSurface = nullptr;
  decltype(&OH_VideoProcessing_SetParameter) setParameter = nullptr;
  decltype(&OH_VideoProcessing_Start) start = nullptr;
  decltype(&OH_VideoProcessing_Stop) stop = nullptr;
  decltype(&OH_VideoProcessingCallback_Create) createCallback = nullptr;
  decltype(&OH_VideoProcessingCallback_Destroy) destroyCallback = nullptr;
  decltype(&OH_VideoProcessingCallback_BindOnError) bindOnError = nullptr;
  decltype(&OH_VideoProcessingCallback_BindOnState) bindOnState = nullptr;
  decltype(&VIDEO_PROCESSING_TYPE_DETAIL_ENHANCER) detailEnhancerType = nullptr;
  decltype(&VIDEO_DETAIL_ENHANCER_PARAMETER_KEY_QUALITY_LEVEL) qualityLevelKey = nullptr;
};

static VpeRuntimeSymbols g_vpeRuntimeSymbols;

template <typename T>
static bool ResolveVpeSymbolLocked(const char* symbolName, T& target, std::string& errorDetail) {
  dlerror();
  void* symbol = dlsym(g_vpeLibraryHandle, symbolName);
  const char* error = dlerror();
  if (error != nullptr || symbol == nullptr) {
    errorDetail = std::string("missing symbol ") + symbolName;
    if (error != nullptr) {
      errorDetail += ": ";
      errorDetail += error;
    }
    return false;
  }
  target = reinterpret_cast<T>(symbol);
  return true;
}

static void LogVpeRuntimeStatusLocked(bool supported, const std::string& detail) {
  if (detail == g_vpeRuntimeStatusDetail) {
    return;
  }
  g_vpeRuntimeStatusDetail = detail;
  if (supported) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
      "VPE runtime available: %{public}s", detail.c_str());
    return;
  }
  OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
    "VPE runtime degraded: %{public}s", detail.c_str());
}

static void MarkVpeRuntimeSupportedLocked(const std::string& detail) {
  g_vpeRuntimeSupportProbed = true;
  g_vpeRuntimeSupported = true;
  LogVpeRuntimeStatusLocked(true, detail);
}

static void MarkVpeRuntimeUnsupportedLocked(const std::string& detail) {
  g_vpeRuntimeSupportProbed = true;
  g_vpeRuntimeSupported = false;
  LogVpeRuntimeStatusLocked(false, detail);
}

static bool LoadVpeRuntimeLocked() {
  if (g_vpeLibraryHandle != nullptr) {
    return true;
  }
  if (g_vpeLibraryLoadAttempted) {
    return false;
  }
  g_vpeLibraryLoadAttempted = true;
  g_vpeLibraryHandle = dlopen("libvideo_processing.so", RTLD_NOW | RTLD_LOCAL);
  if (g_vpeLibraryHandle == nullptr) {
    const char* error = dlerror();
    MarkVpeRuntimeUnsupportedLocked(
      error != nullptr
        ? std::string("libvideo_processing.so unavailable: ") + error
        : std::string("libvideo_processing.so unavailable"));
    return false;
  }

  std::string errorDetail;
  if (!ResolveVpeSymbolLocked("OH_VideoProcessing_InitializeEnvironment",
        g_vpeRuntimeSymbols.initializeEnvironment, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_DeinitializeEnvironment",
        g_vpeRuntimeSymbols.deinitializeEnvironment, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_Create",
        g_vpeRuntimeSymbols.create, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_Destroy",
        g_vpeRuntimeSymbols.destroy, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_RegisterCallback",
        g_vpeRuntimeSymbols.registerCallback, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_SetSurface",
        g_vpeRuntimeSymbols.setSurface, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_GetSurface",
        g_vpeRuntimeSymbols.getSurface, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_SetParameter",
        g_vpeRuntimeSymbols.setParameter, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_Start",
        g_vpeRuntimeSymbols.start, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessing_Stop",
        g_vpeRuntimeSymbols.stop, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessingCallback_Create",
        g_vpeRuntimeSymbols.createCallback, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessingCallback_Destroy",
        g_vpeRuntimeSymbols.destroyCallback, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessingCallback_BindOnError",
        g_vpeRuntimeSymbols.bindOnError, errorDetail) ||
      !ResolveVpeSymbolLocked("OH_VideoProcessingCallback_BindOnState",
        g_vpeRuntimeSymbols.bindOnState, errorDetail) ||
      !ResolveVpeSymbolLocked("VIDEO_PROCESSING_TYPE_DETAIL_ENHANCER",
        g_vpeRuntimeSymbols.detailEnhancerType, errorDetail) ||
      !ResolveVpeSymbolLocked("VIDEO_DETAIL_ENHANCER_PARAMETER_KEY_QUALITY_LEVEL",
        g_vpeRuntimeSymbols.qualityLevelKey, errorDetail)) {
    dlclose(g_vpeLibraryHandle);
    g_vpeLibraryHandle = nullptr;
    g_vpeRuntimeSymbols = VpeRuntimeSymbols{};
    MarkVpeRuntimeUnsupportedLocked(errorDetail);
    return false;
  }
  return true;
}

static bool InitializeVpeEnvironmentLocked(const char* context, bool cacheUnsupported) {
  if (!LoadVpeRuntimeLocked()) {
    return false;
  }
  if (g_vpeEnvironmentInitialized) {
    return true;
  }
  VideoProcessing_ErrorCode ret = g_vpeRuntimeSymbols.initializeEnvironment();
  if (ret != VIDEO_PROCESSING_SUCCESS) {
    const std::string detail =
      std::string(context) + ": InitializeEnvironment failed ret=" + std::to_string(static_cast<int>(ret));
    if (cacheUnsupported) {
      MarkVpeRuntimeUnsupportedLocked(detail);
    } else {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
        "VPE: %{public}s", detail.c_str());
    }
    return false;
  }
  g_vpeEnvironmentInitialized = true;
  return true;
}

static void DeinitializeVpeEnvironmentLocked() {
  if (!g_vpeEnvironmentInitialized || g_vpeRuntimeSymbols.deinitializeEnvironment == nullptr) {
    return;
  }
  VideoProcessing_ErrorCode ret = g_vpeRuntimeSymbols.deinitializeEnvironment();
  if (ret != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
      "VPE runtime degraded: DeinitializeEnvironment returned %{public}d",
      static_cast<int>(ret));
  }
  g_vpeEnvironmentInitialized = false;
}

static bool ProbeVpeRuntimeSupportLocked() {
  if (g_vpeRuntimeSupportProbed) {
    return g_vpeRuntimeSupported;
  }
  if (!InitializeVpeEnvironmentLocked("probe", true)) {
    return false;
  }
  OH_VideoProcessing* probe = nullptr;
  const int32_t detailEnhancerType = *g_vpeRuntimeSymbols.detailEnhancerType;
  VideoProcessing_ErrorCode ret = g_vpeRuntimeSymbols.create(&probe, detailEnhancerType);
  if (ret != VIDEO_PROCESSING_SUCCESS || probe == nullptr) {
    MarkVpeRuntimeUnsupportedLocked(
      std::string("probe: detail enhancer unavailable ret=") + std::to_string(static_cast<int>(ret)));
    if (probe != nullptr) {
      g_vpeRuntimeSymbols.destroy(probe);
    }
    DeinitializeVpeEnvironmentLocked();
    return false;
  }
  g_vpeRuntimeSymbols.destroy(probe);
  DeinitializeVpeEnvironmentLocked();
  MarkVpeRuntimeSupportedLocked("probe: detail enhancer ready");
  return true;
}

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
    if (g_vpeRuntimeSymbols.stop != nullptr) {
      g_vpeRuntimeSymbols.stop(g_vpeProcessor);
    }
    if (g_vpeRuntimeSymbols.destroy != nullptr) {
      g_vpeRuntimeSymbols.destroy(g_vpeProcessor);
    }
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
    if (g_vpeRuntimeSymbols.destroyCallback != nullptr) {
      g_vpeRuntimeSymbols.destroyCallback(g_vpeCallback);
    }
    g_vpeCallback = nullptr;
  }
  DeinitializeVpeEnvironmentLocked();
}

// isVpeDetailEnhancerSupported() → boolean
napi_value IsVpeDetailEnhancerSupported(napi_env env, napi_callback_info /*info*/) {
  std::lock_guard<std::mutex> lock(g_vpeMutex);
  const bool supported = ProbeVpeRuntimeSupportLocked();
  napi_value result = nullptr;
  if (napi_get_boolean(env, supported, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

// createVpeDetailEnhancer(displaySurfaceId: string, qualityLevel: number) → string
// 成功返回 VPE 输入 surfaceId；失败/不支持返回空字符串（不抛异常）
napi_value CreateVpeDetailEnhancer(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = { nullptr, nullptr };

  auto returnEmpty = [&]() -> napi_value {
    napi_value empty = nullptr;
    if (napi_create_string_utf8(env, "", 0, &empty) != napi_ok) {
      return nullptr;
    }
    return empty;
  };

  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) {
    return returnEmpty();
  }
  if (argc < 2) return returnEmpty();

  char surfaceIdBuf[32] = {0};
  size_t strLen = 0;
  if (napi_get_value_string_utf8(env, argv[0], surfaceIdBuf, sizeof(surfaceIdBuf), &strLen) != napi_ok) {
    return returnEmpty();
  }
  // 拒绝空串与被截断的输入（strLen == sizeof(buf) 表示可能被截断）
  if (strLen == 0 || strLen >= sizeof(surfaceIdBuf)) return returnEmpty();

  int32_t qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
  napi_get_value_int32(env, argv[1], &qualityLevel);
  // 边界保护：确保 level 在有效范围内
  if (qualityLevel < VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_NONE ||
      qualityLevel > VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_HIGH) {
    qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
  }

  std::lock_guard<std::mutex> lock(g_vpeMutex);
  DestroyVpeInstanceLocked(); // 清理旧实例

  if (!ProbeVpeRuntimeSupportLocked()) {
    return returnEmpty();
  }
  if (!InitializeVpeEnvironmentLocked("create", false)) {
    return returnEmpty();
  }

  const int32_t detailEnhancerType = *g_vpeRuntimeSymbols.detailEnhancerType;
  if (g_vpeRuntimeSymbols.create(&g_vpeProcessor, detailEnhancerType) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll",
      "VPE: Create failed after runtime probe passed");
    DeinitializeVpeEnvironmentLocked();
    return returnEmpty();
  }

  // 设置质量等级
  OH_AVFormat* param = OH_AVFormat_Create();
  if (param == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: OH_AVFormat_Create failed, skip quality parameter");
  } else {
    OH_AVFormat_SetIntValue(param, *g_vpeRuntimeSymbols.qualityLevelKey, qualityLevel);
    g_vpeRuntimeSymbols.setParameter(g_vpeProcessor, param); // 失败不致命，使用默认
    OH_AVFormat_Destroy(param);
  }

  // 注册回调（必须在 Start 前）
  if (g_vpeRuntimeSymbols.createCallback(&g_vpeCallback) != VIDEO_PROCESSING_SUCCESS || g_vpeCallback == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: callback creation failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }
  if (g_vpeRuntimeSymbols.bindOnError(g_vpeCallback, VpeOnError) != VIDEO_PROCESSING_SUCCESS ||
      g_vpeRuntimeSymbols.bindOnState(g_vpeCallback, VpeOnState) != VIDEO_PROCESSING_SUCCESS ||
      g_vpeRuntimeSymbols.registerCallback(g_vpeProcessor, g_vpeCallback, nullptr) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: callback registration failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 从 surfaceId 字符串恢复 uint64_t，并校验解析终点与溢出
  char *endPtr = nullptr;
  errno = 0;
  uint64_t displaySurfaceId = strtoull(surfaceIdBuf, &endPtr, 10);
  if (endPtr == surfaceIdBuf || *endPtr != '\0' || errno == ERANGE) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: invalid surfaceId: %{public}s", surfaceIdBuf);
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }
  if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(displaySurfaceId, &g_vpeDisplayWindow) != 0) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: CreateNativeWindowFromSurfaceId failed for id=%{public}s", surfaceIdBuf);
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 绑定输出（VPE → 显示）
  if (g_vpeRuntimeSymbols.setSurface(g_vpeProcessor, g_vpeDisplayWindow) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: SetSurface (output) failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 获取输入 Surface（解码器 → VPE）
  if (g_vpeRuntimeSymbols.getSurface(g_vpeProcessor, &g_vpeInputWindow) != VIDEO_PROCESSING_SUCCESS) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: GetSurface (input) failed");
    DestroyVpeInstanceLocked();
    return returnEmpty();
  }

  // 启动 VPE
  if (g_vpeRuntimeSymbols.start(g_vpeProcessor) != VIDEO_PROCESSING_SUCCESS) {
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
  MarkVpeRuntimeSupportedLocked("create: detail enhancer running");
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VPE: Created OK — inputSurfaceId=%{public}s quality=%{public}d",
    inputIdBuf, qualityLevel);

  napi_value result = nullptr;
  if (napi_create_string_utf8(env, inputIdBuf, NAPI_AUTO_LENGTH, &result) != napi_ok) {
    return nullptr;
  }
  return result;
}

// destroyVpeDetailEnhancer() → void
napi_value DestroyVpeDetailEnhancer(napi_env env, napi_callback_info /*info*/) {
  std::lock_guard<std::mutex> lock(g_vpeMutex);
  DestroyVpeInstanceLocked();
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll", "VPE: Destroyed");
  napi_value undef = nullptr;
  if (napi_get_undefined(env, &undef) != napi_ok) {
    return nullptr;
  }
  return undef;
}

// updateVpeQuality(level: number): void
// 动态更新已运行中的 VPE 质量参数（无需重建管线，避免 Surface 断开）
// level: 0=NONE(透传/关闭), 1=LOW, 2=MEDIUM, 3=HIGH
napi_value UpdateVpeQuality(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = { nullptr };

  napi_value undef = nullptr;
  if (napi_get_undefined(env, &undef) != napi_ok) {
    return nullptr;
  }

  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) {
    return undef;
  }

  int32_t qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
  if (argc >= 1) {
    if (napi_get_value_int32(env, argv[0], &qualityLevel) != napi_ok) {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: updateQuality invalid level argument");
      return undef;
    }
    // 边界保护：越界回退到 MEDIUM（与 CreateVpeDetailEnhancer 一致）
    if (qualityLevel < VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_NONE ||
        qualityLevel > VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_HIGH) {
      qualityLevel = VIDEO_DETAIL_ENHANCER_QUALITY_LEVEL_MEDIUM;
    }
  }

  std::lock_guard<std::mutex> lock(g_vpeMutex);
  if (!g_vpeProcessor) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: updateQuality ignored (no processor)");
    return undef;
  }

  OH_AVFormat* param = OH_AVFormat_Create();
  if (param == nullptr) {
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "VidAll", "VPE: OH_AVFormat_Create failed for quality update");
    return undef;
  }
  OH_AVFormat_SetIntValue(param, *g_vpeRuntimeSymbols.qualityLevelKey, qualityLevel);
  VideoProcessing_ErrorCode ret = g_vpeRuntimeSymbols.setParameter(g_vpeProcessor, param);
  OH_AVFormat_Destroy(param);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "VidAll",
    "VPE: quality updated to %{public}d ret=%{public}d", qualityLevel, static_cast<int>(ret));
  return undef;
}

#else // !VIDALL_HAS_VPE — 桩函数（无 VPE 支持时保持 NAPI 表完整）
napi_value IsVpeDetailEnhancerSupported(napi_env env, napi_callback_info /*info*/) {
  napi_value r = nullptr;
  if (napi_get_boolean(env, false, &r) != napi_ok) { return nullptr; }
  return r;
}
napi_value CreateVpeDetailEnhancer(napi_env env, napi_callback_info /*info*/) {
  napi_value r = nullptr;
  if (napi_create_string_utf8(env, "", 0, &r) != napi_ok) { return nullptr; }
  return r;
}
napi_value DestroyVpeDetailEnhancer(napi_env env, napi_callback_info /*info*/) {
  napi_value r = nullptr;
  if (napi_get_undefined(env, &r) != napi_ok) { return nullptr; }
  return r;
}
napi_value UpdateVpeQuality(napi_env env, napi_callback_info /*info*/) {
  napi_value r = nullptr;
  if (napi_get_undefined(env, &r) != napi_ok) { return nullptr; }
  return r;
}
#endif // VIDALL_HAS_VPE

} // namespace vidall
