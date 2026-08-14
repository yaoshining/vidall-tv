#include "napi_common.h"
#include "ffmpeg_probe.h"
#include "subtitle_extract.h"
#include "webdav.h"
#include "audio_capability.h"
#include "vpe.h"
#include "smb_ops.h"
#include "player_core.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include "napi/native_api.h"

using namespace vidall;

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
    { "queryAudioDecoderCapability", nullptr, QueryAudioDecoderCapability, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "isVpeDetailEnhancerSupported", nullptr, IsVpeDetailEnhancerSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "createVpeDetailEnhancer", nullptr, CreateVpeDetailEnhancer, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "destroyVpeDetailEnhancer", nullptr, DestroyVpeDetailEnhancer, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "updateVpeQuality", nullptr, UpdateVpeQuality, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "extractSubtitleEntries", nullptr, ExtractSubtitleEntries, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbTestConnection", nullptr, SmbTestConnection, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbListDirectory",  nullptr, SmbListDirectory,  nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbListShares",     nullptr, SmbListShares,     nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbDiscoverHosts",  nullptr, SmbDiscoverHosts,  nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbReadTextFile",   nullptr, SmbReadTextFile,   nullptr, nullptr, nullptr, napi_default, nullptr },
    { "smbDownloadFile",   nullptr, SmbDownloadFile,   nullptr, nullptr, nullptr, napi_default, nullptr }
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
      vidall::VidAllRegisterXComponentCallback(nativeXC);
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

// NAPI 模块卸载时安全清理 libavformat 网络层（仅在已成功初始化时调用）
__attribute__((destructor)) static void OnNapiModuleUnload() {
  VidAllDeinitAvNetwork();
}

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
