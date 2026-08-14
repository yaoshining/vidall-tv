#ifndef VIDALL_VPE_H
#define VIDALL_VPE_H

#include "napi/native_api.h"

namespace vidall {
napi_value IsVpeDetailEnhancerSupported(napi_env env, napi_callback_info info);
napi_value CreateVpeDetailEnhancer(napi_env env, napi_callback_info info);
napi_value DestroyVpeDetailEnhancer(napi_env env, napi_callback_info info);
napi_value UpdateVpeQuality(napi_env env, napi_callback_info info);

} // namespace vidall

#endif // VIDALL_VPE_H
