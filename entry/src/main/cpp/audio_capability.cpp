#include "napi_common.h"
#include "audio_capability.h"
#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>
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
#ifdef VIDALL_HAS_VPE
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

// 音频解码能力查询
// ─────────────────────────────────────────────────────────────────────────────

struct AudioCapResult {
  bool capabilityKnown = false;
  bool supported = false;
  bool isHardware = false;
  int maxChannels = 0;
  std::string decoderName;
  std::string mimeType;
  std::string errorMessage;
};

static std::string BuildAudioMime(const std::string &codecOrMime) {
  if (codecOrMime == "aac"  || codecOrMime == "audio/mp4a-latm") return "audio/mp4a-latm";
  if (codecOrMime == "opus" || codecOrMime == "audio/opus") return "audio/opus";
  if (codecOrMime == "flac" || codecOrMime == "audio/flac") return "audio/flac";
  if (codecOrMime == "mp3"  || codecOrMime == "audio/mpeg") return "audio/mpeg";
  return codecOrMime;
}

static napi_value MakeStringField(napi_env env, const std::string &s) {
  napi_value v = nullptr;
  napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &v);
  return v;
}

static AudioCapResult QueryAudioCapInternal(const std::string &codecOrMime) {
  AudioCapResult r;
  r.mimeType = BuildAudioMime(codecOrMime);
  r.capabilityKnown = true;

  OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory(r.mimeType.c_str(), false, HARDWARE);
  bool isHw = true;
  if (cap == nullptr) {
    cap = OH_AVCodec_GetCapability(r.mimeType.c_str(), false);
    isHw = (cap != nullptr) && OH_AVCapability_IsHardware(cap);
  }
  if (cap == nullptr) {
    r.errorMessage = "decoder not found";
    return r;
  }

  r.supported = true;
  r.isHardware = isHw;
  const char *name = OH_AVCapability_GetName(cap);
  if (name) r.decoderName = name;
  OH_AVRange ch = {0, 0};
  OH_AVCapability_GetAudioChannelCountRange(cap, &ch);
  r.maxChannels = ch.maxVal;
  return r;
}

napi_value QueryAudioDecoderCapability(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
    ThrowTypeError(env, "queryAudioDecoderCapability requires (codecOrMime)");
    return nullptr;
  }
  char buf[128] = {0};
  size_t len = 0;
  if (napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len) != napi_ok) {
    ThrowTypeError(env, "queryAudioDecoderCapability codecOrMime must be string");
    return nullptr;
  }

  AudioCapResult cap = QueryAudioCapInternal(std::string(buf, len));

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok) {
    ThrowTypeError(env, "queryAudioDecoderCapability failed to create result");
    return nullptr;
  }
  auto set = [&](const char *k, napi_value v) { napi_set_named_property(env, result, k, v); };
  set("capabilityKnown", CreateBoolean(env, cap.capabilityKnown));
  set("supported",       CreateBoolean(env, cap.supported));
  set("isHardware",      CreateBoolean(env, cap.isHardware));
  set("maxChannels",     CreateInt32(env, cap.maxChannels));
  set("decoderName",     MakeStringField(env, cap.decoderName));
  set("mimeType",        MakeStringField(env, cap.mimeType));
  set("errorMessage",    MakeStringField(env, cap.errorMessage));
  return result;
}

napi_value GetNativeCapabilities(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok || result == nullptr) {
    ThrowTypeError(env, "getNativeCapabilities failed to create result object");
    return nullptr;
  }

  napi_value ffmpegEnabled = CreateBoolean(env, true);
  if (ffmpegEnabled == nullptr) {
    ThrowTypeError(env, "getNativeCapabilities failed to create ffmpegEnabled");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "ffmpegEnabled", ffmpegEnabled) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to set ffmpegEnabled");
    return nullptr;
  }

  const bool libcurlEnabledValue = (VIDALL_HAS_LIBCURL == 1);
  napi_value libcurlEnabled = CreateBoolean(env, libcurlEnabledValue);
  if (libcurlEnabled == nullptr) {
    ThrowTypeError(env, "getNativeCapabilities failed to create libcurlEnabled");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "libcurlEnabled", libcurlEnabled) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to set libcurlEnabled");
    return nullptr;
  }

#if VIDALL_HAS_LIBCURL
  const char *libcurlVersion = curl_version();
#else
  const char *libcurlVersion = "disabled";
#endif
  napi_value libcurlVersionValue = nullptr;
  if (napi_create_string_utf8(env, libcurlVersion, NAPI_AUTO_LENGTH, &libcurlVersionValue) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to create libcurlVersion");
    return nullptr;
  }
  if (napi_set_named_property(env, result, "libcurlVersion", libcurlVersionValue) != napi_ok) {
    ThrowTypeError(env, "getNativeCapabilities failed to set libcurlVersion");
    return nullptr;
  }

  return result;
}

// ============================================================
// VPE (Video Processing Engine) — AI 画质增强 (Detail Enhancer)
// API 12+，不支持的设备返回空字符串而不是报错
// 用 VIDALL_HAS_VPE 宏守卫，避免 IDE 在不支持的设备上误报警告

} // namespace vidall
