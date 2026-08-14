#ifndef VIDALL_SUBTITLE_EXTRACT_H
#define VIDALL_SUBTITLE_EXTRACT_H

#include "napi/native_api.h"

namespace vidall {
napi_value ExtractSubtitleEntries(napi_env env, napi_callback_info info);

} // namespace vidall

#endif // VIDALL_SUBTITLE_EXTRACT_H
