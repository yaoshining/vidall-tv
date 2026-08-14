#ifndef VIDALL_WEBDAV_H
#define VIDALL_WEBDAV_H

#include "napi/native_api.h"

namespace vidall {
napi_value WebdavRequest(napi_env env, napi_callback_info info);
napi_value DownloadToFile(napi_env env, napi_callback_info info);

} // namespace vidall

#endif // VIDALL_WEBDAV_H
