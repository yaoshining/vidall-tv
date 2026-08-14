#ifndef VIDALL_FFMPEG_PROBE_H
#define VIDALL_FFMPEG_PROBE_H

#include "napi/native_api.h"

namespace vidall {
napi_value Ffprobe(napi_env env, napi_callback_info info);

} // namespace vidall

#endif // VIDALL_FFMPEG_PROBE_H
