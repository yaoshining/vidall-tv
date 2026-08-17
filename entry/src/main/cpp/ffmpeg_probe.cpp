#include "napi_common.h"
#include "ffmpeg_probe.h"
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
#include <libavutil/dovi_meta.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
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

struct FfprobeAsyncContext {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string url;
  std::string headerLines;
  int64_t timeoutMs = 0;
  std::string jsonResult;
  std::string errorMessage;
};

static std::string CodecTypeToString(AVMediaType mediaType) {
  switch (mediaType) {
    case AVMEDIA_TYPE_VIDEO:
      return "video";
    case AVMEDIA_TYPE_AUDIO:
      return "audio";
    case AVMEDIA_TYPE_SUBTITLE:
      return "subtitle";
    default:
      return "unknown";
  }
}

static std::string RationalToString(AVRational value) {
  return std::to_string(value.num) + "/" + std::to_string(value.den);
}

static std::string ReadMetadataValue(AVDictionary *metadata, const char *key) {
  AVDictionaryEntry *entry = av_dict_get(metadata, key, nullptr, 0);
  if (entry == nullptr || entry->value == nullptr) {
    return "";
  }
  return std::string(entry->value);
}

static std::string DescribeChannelLayout(const AVCodecParameters *codecpar) {
  if (codecpar == nullptr) {
    return "";
  }
  char buffer[128] = { 0 };
  if (av_channel_layout_describe(&codecpar->ch_layout, buffer, sizeof(buffer)) < 0) {
    return "";
  }
  return std::string(buffer);
}

static std::string BuildProbeJson(AVFormatContext *formatContext) {
  std::string json = "{\"streams\":[";
  bool firstStream = true;
  for (unsigned int index = 0; index < formatContext->nb_streams; ++index) {
    AVStream *stream = formatContext->streams[index];
    if (stream == nullptr || stream->codecpar == nullptr) {
      continue;
    }

    if (!firstStream) {
      json += ",";
    }
    firstStream = false;

    const AVCodecParameters *codecpar = stream->codecpar;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(codecpar->codec_id);
    const std::string codecName = std::string(avcodec_get_name(codecpar->codec_id));
    const std::string codecLongName = descriptor != nullptr && descriptor->long_name != nullptr
      ? std::string(descriptor->long_name)
      : codecName;
    const std::string language = ReadMetadataValue(stream->metadata, "language");
    const std::string title = ReadMetadataValue(stream->metadata, "title");

    json += "{";
    bool firstField = true;
    AppendJsonIntField(json, "index", static_cast<int64_t>(stream->index), firstField);
    AppendJsonStringField(json, "codec_type", CodecTypeToString(codecpar->codec_type), firstField);
    AppendJsonStringField(json, "codec_name", codecName, firstField);
    AppendJsonStringField(json, "codec_long_name", codecLongName, firstField);

    if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      AppendJsonIntField(json, "width", codecpar->width, firstField);
      AppendJsonIntField(json, "height", codecpar->height, firstField);
      AppendJsonStringField(json, "r_frame_rate", RationalToString(stream->r_frame_rate), firstField);
      AppendJsonStringField(json, "avg_frame_rate", RationalToString(stream->avg_frame_rate), firstField);
      if (codecpar->bit_rate > 0) {
        AppendJsonStringField(json, "bit_rate", std::to_string(codecpar->bit_rate), firstField);
      }
      // 视频色彩元数据：供 TS 侧 FfprobeUtil.parseHdrType 判定 HDR。
      // color_transfer 是关键字段：AVCOL_TRC_SMPTE2084(16)=HDR10、AVCOL_TRC_ARIB_STD_B67(18)=HLG。
      const char *pixFmtName = av_get_pix_fmt_name(static_cast<AVPixelFormat>(codecpar->format));
      if (pixFmtName != nullptr) {
        AppendJsonStringField(json, "pix_fmt", std::string(pixFmtName), firstField);
      }
      const char *profileName = avcodec_profile_name(codecpar->codec_id, codecpar->profile);
      if (profileName != nullptr) {
        AppendJsonStringField(json, "profile", std::string(profileName), firstField);
      }
      AppendJsonIntField(json, "bits_per_raw_sample", codecpar->bits_per_raw_sample, firstField);
      AppendJsonIntField(json, "color_primaries", static_cast<int64_t>(codecpar->color_primaries), firstField);
      AppendJsonIntField(json, "color_transfer", static_cast<int64_t>(codecpar->color_trc), firstField);
      AppendJsonIntField(json, "color_space", static_cast<int64_t>(codecpar->color_space), firstField);
      AppendJsonIntField(json, "color_range", static_cast<int64_t>(codecpar->color_range), firstField);
      // Dolby Vision 配置（AV_PKT_DATA_DOVI_CONF coded side data）：
      // 输出 dv_profile / dv_level / dv_bl_signal_compatibility_id，供 parseHdrType 识别 DV。
      // 注意：FFmpeg 8 的 AVStream 已不再公开 side_data，DOVI 配置只能从 codecpar->coded_side_data 读取。
      const AVPacketSideData *doviSideData = av_packet_side_data_get(
          codecpar->coded_side_data, codecpar->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
      if (doviSideData != nullptr && doviSideData->data != nullptr &&
          doviSideData->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const AVDOVIDecoderConfigurationRecord *dovi =
            reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(doviSideData->data);
        AppendJsonIntField(json, "dv_profile", dovi->dv_profile, firstField);
        AppendJsonIntField(json, "dv_level", dovi->dv_level, firstField);
        AppendJsonIntField(json, "dv_bl_signal_compatibility_id",
            dovi->dv_bl_signal_compatibility_id, firstField);
      }
    } else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
      if (codecpar->sample_rate > 0) {
        AppendJsonStringField(json, "sample_rate", std::to_string(codecpar->sample_rate), firstField);
      }
      if (codecpar->ch_layout.nb_channels > 0) {
        AppendJsonIntField(json, "channels", codecpar->ch_layout.nb_channels, firstField);
      }
      const std::string channelLayout = DescribeChannelLayout(codecpar);
      if (!channelLayout.empty()) {
        AppendJsonStringField(json, "channel_layout", channelLayout, firstField);
      }
      if (codecpar->bit_rate > 0) {
        AppendJsonStringField(json, "bit_rate", std::to_string(codecpar->bit_rate), firstField);
      }
    }

    if (!language.empty() || !title.empty()) {
      if (!firstField) {
        json += ",";
      }
      json += "\"tags\":{";
      bool firstTagField = true;
      if (!language.empty()) {
        AppendJsonStringField(json, "language", language, firstTagField);
      }
      if (!title.empty()) {
        AppendJsonStringField(json, "title", title, firstTagField);
      }
      json += "}";
      firstField = false;
    }
    json += "}";
  }

  json += "],\"format\":{";
  bool firstFormatField = true;
  if (formatContext->duration != AV_NOPTS_VALUE && formatContext->duration > 0) {
    const double durationSeconds = static_cast<double>(formatContext->duration) / static_cast<double>(AV_TIME_BASE);
    AppendJsonStringField(json, "duration", std::to_string(durationSeconds), firstFormatField);
  }
  if (formatContext->bit_rate > 0) {
    AppendJsonStringField(json, "bit_rate", std::to_string(formatContext->bit_rate), firstFormatField);
  }
  if (formatContext->iformat != nullptr && formatContext->iformat->name != nullptr) {
    AppendJsonStringField(json, "format_name", std::string(formatContext->iformat->name), firstFormatField);
  }
  json += "}}";
  return json;
}

static bool RunFfprobe(
  const std::string &url,
  const std::string &headerLines,
  int64_t timeoutMs,
  std::string &jsonResult,
  std::string &errorMessage
) {
  VidAllEnsureAvNetworkInit();
  if (!VidAllAvNetworkReady()) {
    errorMessage = "ffprobe: libavformat network layer unavailable";
    return false;
  }

  ProbeInterruptContext interruptContext;
  interruptContext.startTimeUs = av_gettime_relative();
  interruptContext.timeoutUs = timeoutMs > 0 ? timeoutMs * 1000 : 0;

  AVFormatContext *formatContext = avformat_alloc_context();
  if (formatContext == nullptr) {
    errorMessage = "ffprobe failed: cannot allocate format context";
    return false;
  }

  formatContext->interrupt_callback.callback = ProbeInterruptCallback;
  formatContext->interrupt_callback.opaque = &interruptContext;

  AVDictionary *options = nullptr;
  if (!headerLines.empty()) {
    av_dict_set(&options, "headers", headerLines.c_str(), 0);
  }

  std::lock_guard<std::mutex> ffNetLock(g_ffmpegNetworkMutex);
  int openResult = avformat_open_input(&formatContext, url.c_str(), nullptr, &options);
  av_dict_free(&options);
  if (openResult < 0) {
    errorMessage = "ffprobe open input failed: " + FfmpegErrorToString(openResult);
    if (formatContext != nullptr) {
      avformat_close_input(&formatContext);
    }
    return false;
  }

  int findInfoResult = avformat_find_stream_info(formatContext, nullptr);
  if (findInfoResult < 0) {
    errorMessage = "ffprobe find stream info failed: " + FfmpegErrorToString(findInfoResult);
    avformat_close_input(&formatContext);
    return false;
  }

  jsonResult = BuildProbeJson(formatContext);
  avformat_close_input(&formatContext);
  return true;
}

static void ExecuteFfprobeAsync(napi_env env, void *data) {
  (void)env;
  FfprobeAsyncContext *context = static_cast<FfprobeAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }
  RunFfprobe(context->url, context->headerLines, context->timeoutMs, context->jsonResult, context->errorMessage);
}

static void CompleteFfprobeAsync(napi_env env, napi_status status, void *data) {
  FfprobeAsyncContext *context = static_cast<FfprobeAsyncContext *>(data);
  if (context == nullptr) {
    return;
  }

  napi_value settleValue = nullptr;
  if (status == napi_ok && context->errorMessage.empty()) {
    if (napi_create_string_utf8(env, context->jsonResult.c_str(), NAPI_AUTO_LENGTH, &settleValue) == napi_ok) {
      napi_resolve_deferred(env, context->deferred, settleValue);
    } else {
      context->errorMessage = "ffprobe failed to create result string";
    }
  }

  // 取消或其他非 napi_ok 状态且无错误信息时，保证 Promise 一定被 reject，避免永久挂起
  if (status != napi_ok && context->errorMessage.empty()) {
    context->errorMessage = "ffprobe async work cancelled or failed";
  }

  if (!context->errorMessage.empty()) {
    napi_value messageValue = nullptr;
    napi_value errorValue = nullptr;
    if (napi_create_string_utf8(env, context->errorMessage.c_str(), NAPI_AUTO_LENGTH, &messageValue) == napi_ok &&
      napi_create_error(env, nullptr, messageValue, &errorValue) == napi_ok) {
      napi_reject_deferred(env, context->deferred, errorValue);
    }
  }

  if (context->work != nullptr) {
    napi_delete_async_work(env, context->work);
  }
  delete context;
}

napi_value Ffprobe(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = { nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
    ThrowTypeError(env, "ffprobe failed to read args");
    return nullptr;
  }
  if (argc < 3) {
    ThrowTypeError(env, "ffprobe requires (url, headerLines, timeoutMs)");
    return nullptr;
  }

  std::string url;
  std::string headerLines;
  int64_t timeoutMs = 0;
  if (!ReadUtf8String(env, args[0], url)) {
    ThrowTypeError(env, "ffprobe url must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[1], headerLines)) {
    ThrowTypeError(env, "ffprobe headerLines must be string");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[2], &timeoutMs) != napi_ok) {
    ThrowTypeError(env, "ffprobe timeoutMs must be int64");
    return nullptr;
  }

  FfprobeAsyncContext *context = new FfprobeAsyncContext();
  context->url = url;
  context->headerLines = headerLines;
  context->timeoutMs = timeoutMs;

  napi_value promise = nullptr;
  if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
    delete context;
    ThrowTypeError(env, "ffprobe failed to create promise");
    return nullptr;
  }

  napi_value resourceName = nullptr;
  if (napi_create_string_utf8(env, "ffprobeAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
    delete context;
    ThrowTypeError(env, "ffprobe failed to create resource name");
    return nullptr;
  }

  if (napi_create_async_work(env, nullptr, resourceName, ExecuteFfprobeAsync, CompleteFfprobeAsync, context, &context->work) != napi_ok) {
    delete context;
    ThrowTypeError(env, "ffprobe failed to create async work");
    return nullptr;
  }

  if (napi_queue_async_work(env, context->work) != napi_ok) {
    napi_delete_async_work(env, context->work);
    delete context;
    ThrowTypeError(env, "ffprobe failed to queue async work");
    return nullptr;
  }

  return promise;
}

} // namespace vidall
