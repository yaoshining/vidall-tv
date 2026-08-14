#ifndef VIDALL_AUDIO_CAPABILITY_H
#define VIDALL_AUDIO_CAPABILITY_H

#include "napi/native_api.h"

namespace vidall {
napi_value QueryAudioDecoderCapability(napi_env env, napi_callback_info info);
napi_value GetNativeCapabilities(napi_env env, napi_callback_info info);

} // namespace vidall

#endif // VIDALL_AUDIO_CAPABILITY_H
