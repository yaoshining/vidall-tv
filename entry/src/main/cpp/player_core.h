#ifndef VIDALL_PLAYER_CORE_H
#define VIDALL_PLAYER_CORE_H

#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>

namespace vidall {
napi_value CreatePlayer(napi_env env, napi_callback_info info);
napi_value SetSource(napi_env env, napi_callback_info info);
napi_value SetDurationHint(napi_env env, napi_callback_info info);
napi_value SetHeaders(napi_env env, napi_callback_info info);
napi_value SetXComponent(napi_env env, napi_callback_info info);
napi_value Prepare(napi_env env, napi_callback_info info);
napi_value Play(napi_env env, napi_callback_info info);
napi_value Pause(napi_env env, napi_callback_info info);
napi_value Seek(napi_env env, napi_callback_info info);
napi_value SelectTrack(napi_env env, napi_callback_info info);
napi_value Release(napi_env env, napi_callback_info info);
napi_value GetProxyUrl(napi_env env, napi_callback_info info);
napi_value GetCurrentTime(napi_env env, napi_callback_info info);
napi_value GetDuration(napi_env env, napi_callback_info info);
napi_value SetCallbacks(napi_env env, napi_callback_info info);
napi_value FfmpegSelfCheck(napi_env env, napi_callback_info info);

void VidAllRegisterXComponentCallback(OH_NativeXComponent *nativeXC);

} // namespace vidall

#endif // VIDALL_PLAYER_CORE_H
