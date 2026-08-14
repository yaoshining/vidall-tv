#ifndef VIDALL_SMB_OPS_H
#define VIDALL_SMB_OPS_H

#include "napi/native_api.h"

namespace vidall {
napi_value SmbTestConnection(napi_env env, napi_callback_info info);
napi_value SmbListDirectory(napi_env env, napi_callback_info info);
napi_value SmbListShares(napi_env env, napi_callback_info info);
napi_value SmbDiscoverHosts(napi_env env, napi_callback_info info);
napi_value SmbReadTextFile(napi_env env, napi_callback_info info);
napi_value SmbDownloadFile(napi_env env, napi_callback_info info);

} // namespace vidall

#endif // VIDALL_SMB_OPS_H
