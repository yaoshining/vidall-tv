#include "napi_common.h"
#include "subtitle_extract.h"
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

// ─────────────────────────────────────────────────────────────
// ExtractSubtitleEntries: 从 MKV 等容器提取指定字幕流的全部条目
// 返回 JSON 数组：[{"startMs":N,"endMs":N,"text":"..."},...]
// 对于 subrip(SRT) 类型，pkt->data 即为原始文本，无需解码器
// ─────────────────────────────────────────────────────────────

struct ExtractSubAsyncContext {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string url;
  std::string headerLines;
  int streamIndex = -1;
  int64_t timeoutMs = 30000;
  std::string jsonResult;
  std::string errorMessage;
};

static std::string StripAssOverrideTags(const std::string &text) {
  std::string out;
  out.reserve(text.size());
  bool inTag = false;
  for (char c : text) {
    if (c == '{') { inTag = true; continue; }
    if (c == '}') { inTag = false; continue; }
    if (!inTag) out += c;
  }
  // 替换 \N（ASS 强制换行）为 \n
  size_t pos = 0;
  while ((pos = out.find("\\N", pos)) != std::string::npos) {
    out.replace(pos, 2, "\n");
  }
  return out;
}

// 从 ASS Dialogue 行提取纯文本（格式：Dialogue: layer,start,end,style,...,text）
static std::string ParseAssDialogue(const char *ass) {
  if (ass == nullptr) return "";
  // MKV ASS block 格式（avcodec_decode_subtitle2 及 raw-pkt 均输出此格式）：
  //   "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
  //   共 8 个逗号分隔的字段，第 8 个逗号之后即为 Text 字段。
  //
  // 注意：Text 字段本身可包含逗号（如 \fad(500,1000) 内的逗号），
  // 因此必须在恰好数到第 8 个逗号后立即停止，不得继续向后搜索。
  int commas = 0;
  const char *p = ass;
  while (*p && commas < 8) {
    if (*p == ',') commas++;
    p++;
  }
  if (commas < 8) return ""; // 字段不足，格式不符
  return StripAssOverrideTags(std::string(p));
}

static void ExecuteExtractSubAsync(napi_env env, void *data) {
  (void)env;
  ExtractSubAsyncContext *ctx = static_cast<ExtractSubAsyncContext *>(data);
  if (ctx == nullptr) return;

  VidAllEnsureAvNetworkInit();
  if (!VidAllAvNetworkReady()) {
    ctx->errorMessage = "extractSub: libavformat network layer unavailable";
    return;
  }

  // find_stream_info 阶段给 10s 超时（足够探测流信息），读包阶段单独计时
  ProbeInterruptContext interruptCtx;
  interruptCtx.startTimeUs = av_gettime_relative();
  interruptCtx.timeoutUs = 10LL * 1000000LL; // 10s for open+find_stream_info

  AVFormatContext *formatCtx = avformat_alloc_context();
  if (formatCtx == nullptr) {
    ctx->errorMessage = "extractSub: cannot alloc format context";
    return;
  }
  formatCtx->interrupt_callback.callback = ProbeInterruptCallback;
  formatCtx->interrupt_callback.opaque = &interruptCtx;

  AVDictionary *options = nullptr;
  if (!ctx->headerLines.empty()) {
    av_dict_set(&options, "headers", ctx->headerLines.c_str(), 0);
  }
  // 限制 probe 量，避免 find_stream_info 在大型网络文件上耗费过长时间
  av_dict_set(&options, "probesize", "65536", 0);
  av_dict_set(&options, "analyzeduration", "0", 0);

  std::lock_guard<std::mutex> ffNetLock(g_ffmpegNetworkMutex);
  int ret = avformat_open_input(&formatCtx, ctx->url.c_str(), nullptr, &options);
  av_dict_free(&options);
  if (ret < 0) {
    ctx->errorMessage = "extractSub: open input failed: " + FfmpegErrorToString(ret);
    if (formatCtx) avformat_close_input(&formatCtx);
    return;
  }

  // MKV 等格式在 avformat_open_input 后已通过 Tracks 元素填充流信息，
  // 可在调用耗时较长的 find_stream_info 之前就完成图像字幕的快速检测。
  {
    const int earlySi = ctx->streamIndex;
    if (formatCtx->nb_streams > 0 &&
        earlySi >= 0 && earlySi < (int)formatCtx->nb_streams &&
        formatCtx->streams[earlySi]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
      const AVCodecID earlyId = formatCtx->streams[earlySi]->codecpar->codec_id;
      const char *earlyName = avcodec_get_name(earlyId);
      bool earlyImageBased = (earlyId == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                              earlyId == AV_CODEC_ID_DVD_SUBTITLE ||
                              earlyId == AV_CODEC_ID_DVB_SUBTITLE);
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "extractSub early-check stream[%d] codec_type=%d codec=%s imageBased=%d",
                   earlySi, (int)formatCtx->streams[earlySi]->codecpar->codec_type,
                   earlyName ? earlyName : "?", (int)earlyImageBased);
      if (earlyImageBased) {
        ctx->errorMessage = std::string("image-based subtitle not supported: ") +
                            (earlyName ? earlyName : "unknown");
        avformat_close_input(&formatCtx);
        return;
      }
    }
  }

  ret = avformat_find_stream_info(formatCtx, nullptr);
  if (ret < 0) {
    ctx->errorMessage = "extractSub: find stream info failed: " + FfmpegErrorToString(ret);
    avformat_close_input(&formatCtx);
    return;
  }

  // 重置中断时钟：find_stream_info 完成，给读包阶段完整的 timeoutMs 预算
  interruptCtx.startTimeUs = av_gettime_relative();
  interruptCtx.timeoutUs = ctx->timeoutMs > 0 ? ctx->timeoutMs * 1000 : 60LL * 1000000LL;

  const int si = ctx->streamIndex;
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub nb_streams=%u target_si=%d", formatCtx->nb_streams, si);

  if (si < 0 || si >= (int)formatCtx->nb_streams ||
      formatCtx->streams[si]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
    // 目标 index 不是字幕流，打印所有流信息辅助排查
    for (unsigned int i = 0; i < formatCtx->nb_streams; i++) {
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "  stream[%u] codec_type=%d codec_id=%d",
                   i,
                   (int)formatCtx->streams[i]->codecpar->codec_type,
                   (int)formatCtx->streams[i]->codecpar->codec_id);
    }
    ctx->errorMessage = "extractSub: invalid subtitle stream index " + std::to_string(si);
    avformat_close_input(&formatCtx);
    return;
  }

  AVStream *subStream = formatCtx->streams[si];
  AVRational tb = subStream->time_base;

  // 检测图像类字幕（PGS/VOBSUB/DVB）：这类字幕数据是二进制位图，无法提取为文本，
  // 直接快速失败，避免白白等待 60 秒超时。
  const AVCodecID subCodecId = subStream->codecpar->codec_id;
  const char *subCodecName = avcodec_get_name(subCodecId);
  bool isImageBased = (subCodecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                       subCodecId == AV_CODEC_ID_DVD_SUBTITLE ||
                       subCodecId == AV_CODEC_ID_DVB_SUBTITLE);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub stream[%d] codec_id=%d codec_name=%s imageBased=%d",
               si, (int)subCodecId, subCodecName ? subCodecName : "?", (int)isImageBased);
  if (isImageBased) {
    ctx->errorMessage = std::string("image-based subtitle not supported: ") +
                        (subCodecName ? subCodecName : "unknown");
    avformat_close_input(&formatCtx);
    return;
  }

  // 尝试打开解码器（subrip 在 OHOS 可能未编译进去，则退回原始包）
  const AVCodec *codec = avcodec_find_decoder(subCodecId);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub stream[%d] codec_id=%d decoder=%s",
               si, (int)subCodecId,
               codec ? codec->name : "NULL(raw-pkt-mode)");
  AVCodecContext *codecCtx = nullptr;
  if (codec != nullptr) {
    codecCtx = avcodec_alloc_context3(codec);
    if (codecCtx != nullptr) {
      avcodec_parameters_to_context(codecCtx, subStream->codecpar);
      if (avcodec_open2(codecCtx, codec, nullptr) < 0) {
        avcodec_free_context(&codecCtx);
        codecCtx = nullptr;
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "ExtractSub",
                     "extractSub codec open failed, fallback to raw-pkt-mode");
      }
    }
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub codecCtx=%s extradata_size=%d",
               codecCtx != nullptr ? "opened" : "NULL(raw-pkt-mode)",
               subStream->codecpar->extradata_size);

  // Cues-based seek 策略（针对蓝光原盘等非交错封装 MKV）：
  // MKV Cues 元素记录了每条流各 Cluster 的字节偏移；FFmpeg 在 avformat_open_input 后
  // 通过 SeekHead 读取 Cues，并将结果存入 stream index_entries。
  // 若字幕流有 index_entries，可直接 seek 到字幕 Cluster 起始位置后顺序读取，
  // 避免从文件头部顺序扫描大量视频/音频数据（可能需要数分钟）。
  {
    int nIdx = avformat_index_get_entries_count(subStream);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                 "extractSub stream[%d] nb_index_entries=%d", si, nIdx);
    if (nIdx > 0) {
      // 找字幕流所有 index_entries 中字节偏移最小的一个作为起始 seek 点
      const AVIndexEntry *firstEntry = avformat_index_get_entry(subStream, 0);
      int64_t minPos = firstEntry ? firstEntry->pos : INT64_MAX;
      int64_t firstTs = firstEntry ? firstEntry->timestamp : 0;
      for (int ie = 1; ie < nIdx; ie++) {
        const AVIndexEntry *e = avformat_index_get_entry(subStream, ie);
        if (e && e->pos < minPos) {
          minPos = e->pos;
          firstTs = e->timestamp;
        }
      }
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "extractSub cues-seek firstTs=%lld minPos=%lld nIdx=%d",
                   (long long)firstTs, (long long)minPos, nIdx);
      // seek 到字幕最早的 Cluster 位置；MKV demuxer 会用 Cues 精确定位
      avformat_seek_file(formatCtx, si, firstTs - 1, firstTs, firstTs + 1, 0);
      // 重置超时，为从字幕起始位置做顺序读取提供完整时间窗口
      interruptCtx.startTimeUs = av_gettime_relative();
      interruptCtx.timeoutUs = ctx->timeoutMs > 0 ? ctx->timeoutMs * 1000 : 60LL * 1000000LL;
    } else {
      // Cues 无该字幕流索引条目，回退到从文件起始位置读取
      // avformat_find_stream_info 可能已将文件指针推进到中段，需 seek 回 0
      // 否则后续 av_read_frame 从中段顺序扫描，对大文件（4K SMB）需读 90000+ 包导致 30s 超时
      OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                   "extractSub stream[%d] no cues-seek, seek to beginning", si);
      const int seekRet = av_seek_frame(formatCtx, -1, 0, AVSEEK_FLAG_BACKWARD);
      if (seekRet < 0) {
        ctx->errorMessage = "extractSub: rewind failed: " + FfmpegErrorToString(seekRet);
        if (codecCtx != nullptr) { avcodec_free_context(&codecCtx); }
        avformat_close_input(&formatCtx);
        return;
      }
      // 重置超时时钟，为从起始位置完整读取提供完整时间窗口
      interruptCtx.startTimeUs = av_gettime_relative();
      interruptCtx.timeoutUs = ctx->timeoutMs > 0 ? ctx->timeoutMs * 1000 : 60LL * 1000000LL;
    }
  }

  // 丢弃所有非字幕流，减少 av_read_frame 返回的无效包数量。
  // 对于 MKV 容器：demuxer 在找到 subtitle cluster 之前仍需顺序解析块头，
  // 但设置 AVDISCARD_ALL 后 FFmpeg 会跳过这些包的解码，减少 CPU 开销。
  // 对于 localhost SMB proxy（127.0.0.1）：额外的 avio_skip()/Range 请求
  // 延迟可忽略不计（<1ms/请求），不存在 WebDAV 场景的高 RTT 问题。
  for (unsigned int discardI = 0; discardI < formatCtx->nb_streams; discardI++) {
    if ((int)discardI != si) {
      formatCtx->streams[discardI]->discard = AVDISCARD_ALL;
    }
  }

  std::string json = "[";
  bool first = true;
  int64_t totalPkts = 0;
  int64_t subPkts = 0;
  int64_t entryCount = 0;
  // 防止超大字幕文件耗尽内存：限制最大条目数和 JSON 字节数
  static constexpr int MAX_SUBTITLE_ENTRIES = 50000;
  static constexpr size_t MAX_JSON_BYTES = 16 * 1024 * 1024; // 16 MB

  AVPacket *pkt = av_packet_alloc();
  if (pkt == nullptr) {
    if (codecCtx != nullptr) avcodec_free_context(&codecCtx);
    avformat_close_input(&formatCtx);
    ctx->errorMessage = "extractSub: cannot alloc packet";
    return;
  }
  int readRet = 0;
  while ((readRet = av_read_frame(formatCtx, pkt)) >= 0) {
    totalPkts++;
    if (pkt->stream_index != si || pkt->size <= 0 || pkt->data == nullptr) {
      av_packet_unref(pkt);
      continue;
    }
    subPkts++;

    int64_t startMs = (pkt->pts == AV_NOPTS_VALUE) ? 0 :
      (int64_t)((double)pkt->pts * av_q2d(tb) * 1000.0);
    int64_t endMs = (pkt->duration > 0) ?
      startMs + (int64_t)((double)pkt->duration * av_q2d(tb) * 1000.0) :
      startMs + 5000;

    std::string text;

    // 诊断日志：前 3 个字幕包打印详情，帮助定位 entries=0 根因
    bool diagLog = (subPkts <= 3);

    if (codecCtx != nullptr) {
      // 有解码器：走 avcodec_decode_subtitle2
      AVSubtitle sub = {};
      int gotSub = 0;
      int dr = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt);

      if (diagLog) {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                     "extractSub pkt#%lld decode dr=%d gotSub=%d num_rects=%u",
                     (long long)subPkts, dr, gotSub,
                     (unsigned)(gotSub ? sub.num_rects : 0u));
        if (gotSub && sub.num_rects > 0 && sub.rects[0]->ass != nullptr) {
          // 截取前 100 字节，替换 \0 为 '?' 保证 %s 安全
          char assSnip[101] = {};
          int assLen = (int)strlen(sub.rects[0]->ass);
          int snipLen = assLen < 100 ? assLen : 100;
          for (int ci = 0; ci < snipLen; ci++) {
            assSnip[ci] = (sub.rects[0]->ass[ci] == '\0') ? '?' : sub.rects[0]->ass[ci];
          }
          OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                       "extractSub pkt#%lld ass[0](%d)=%{public}s",
                       (long long)subPkts, assLen, assSnip);
        }
      }

      if (dr >= 0 && gotSub && sub.num_rects > 0) {
        for (unsigned int r = 0; r < sub.num_rects; r++) {
          if (sub.rects[r]->ass != nullptr) {
            text = ParseAssDialogue(sub.rects[r]->ass);
          } else if (sub.rects[r]->text != nullptr) {
            text = std::string(sub.rects[r]->text);
          }
          if (!text.empty()) break;
        }
      }
      avsubtitle_free(&sub);

      // gotSub=0 降级：解码器未解出内容时，尝试将原始包当作 raw-pkt 解析
      // 常见于 OHOS 上 extradata 为空导致 ass 解码器拒绝所有包
      if (text.empty() && pkt->size > 0 && pkt->data != nullptr) {
        if (diagLog) {
          OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                       "extractSub pkt#%lld gotSub=0 fallback to raw-pkt",
                       (long long)subPkts);
        }
        goto raw_pkt_parse; // 跳到 raw-pkt 路径；goto 仅在此处使用，清晰且无资源泄漏
      }
    } else {
raw_pkt_parse:
      // 无解码器（或 gotSub=0 降级）：
      // subrip/ass 在 MKV 中 pkt->data 可能是 ASS block 格式或纯 SRT 文本
      if (diagLog) {
        // 截取前 200 字节，替换控制字符为 '?' 保证 %s 安全
        size_t snipLen = std::min((size_t)200, (size_t)pkt->size);
        char rawSnip[201] = {};
        for (size_t ci = 0; ci < snipLen; ci++) {
          unsigned char ch = pkt->data[ci];
          rawSnip[ci] = (ch < 0x20 && ch != '\n' && ch != '\r') ? '?' : (char)ch;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
                     "extractSub pkt#%lld raw(%d)=%{public}s",
                     (long long)subPkts, pkt->size, rawSnip);
      }

      text = std::string(reinterpret_cast<char *>(pkt->data),
                         static_cast<size_t>(pkt->size));
      // 检测 MKV ASS block 格式：readorder,layer,style,name,marginL,marginR,marginV,effect,text
      // 特征：首字符为数字，前 200 字节内有 8 个逗号
      bool isAssBlock = !text.empty() && std::isdigit((unsigned char)text[0]);
      if (isAssBlock) {
        int commas = 0;
        size_t pos = 0;
        size_t scanEnd = std::min(text.size(), (size_t)200);
        while (pos < scanEnd && commas < 8) {
          if (text[pos] == ',') commas++;
          pos++;
        }
        if (commas == 8 && pos < text.size()) {
          text = StripAssOverrideTags(text.substr(pos));
        } else {
          isAssBlock = false; // 逗号不足，不是 ASS block，走 SRT 路径
        }
      }
      if (!isAssBlock) {
        // SRT 格式：去除序号行和时间行
        size_t lineStart = 0;
        for (int linePass = 0; linePass < 3 && lineStart < text.size(); linePass++) {
          size_t nlPos = text.find('\n', lineStart);
          if (nlPos == std::string::npos) break;
          std::string line = text.substr(lineStart, nlPos - lineStart);
          if (!line.empty() && line.back() == '\r') line.pop_back();
          bool isSeqOrTime = !line.empty() &&
            (std::all_of(line.begin(), line.end(), [](unsigned char c){ return std::isdigit(c) != 0; }) ||
             line.find("-->") != std::string::npos);
          if (isSeqOrTime) {
            lineStart = nlPos + 1;
          } else {
            break;
          }
        }
        text = text.substr(lineStart);
      }
      size_t ts = text.find_first_not_of(" \t\r\n");
      size_t te = text.find_last_not_of(" \t\r\n");
      if (ts != std::string::npos) {
        text = text.substr(ts, te - ts + 1);
      } else {
        text.clear();
      }
    }

    av_packet_unref(pkt);

    if (text.empty()) continue;

    // OOM guard：超过上限时终止，避免超大文件耗尽内存
    // pkt 已在进入本轮时 av_packet_unref，此处只 break，不重复 unref
    if (entryCount >= MAX_SUBTITLE_ENTRIES || json.size() >= MAX_JSON_BYTES) {
      OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "ExtractSub",
                   "extractSub cap reached entries=%lld jsonBytes=%zu, stopping",
                   (long long)entryCount, json.size());
      break;
    }

    if (!first) json += ",";
    first = false;
    json += "{\"startMs\":";
    json += std::to_string(startMs);
    json += ",\"endMs\":";
    json += std::to_string(endMs);
    json += ",\"text\":\"";
    json += JsonEscape(text);
    json += "\"}";
    entryCount++;
  }
  av_packet_free(&pkt);

  const int nbStreams = formatCtx ? (int)formatCtx->nb_streams : 0;
  if (codecCtx) avcodec_free_context(&codecCtx);
  avformat_close_input(&formatCtx);

  OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "ExtractSub",
               "extractSub done stream=%d totalPkts=%lld subPkts=%lld",
               si, (long long)totalPkts, (long long)subPkts);

  if (!first) {
    // 找到至少一条字幕条目——即使超时也以已有结果 resolve（partial results）
    json += "]";
    ctx->jsonResult = json;
  } else if (readRet < 0 && readRet != AVERROR_EOF) {
    // 无条目且读取中途出错（超时 / 网络断开等）
    ctx->errorMessage = "extractSub: read failed: " + FfmpegErrorToString(readRet) +
                        " totalPkts=" + std::to_string(totalPkts) +
                        " subPkts=" + std::to_string(subPkts);
  } else {
    // 无条目且正常结束（EOF 或空文件）
    ctx->errorMessage = "count=0 codec=" + std::string(subCodecName ? subCodecName : "?") +
                        " totalPkts=" + std::to_string(totalPkts) +
                        " subPkts=" + std::to_string(subPkts) +
                        " nbStreams=" + std::to_string(nbStreams);
  }
}

static void CompleteExtractSubAsync(napi_env env, napi_status status, void *data) {
  ExtractSubAsyncContext *ctx = static_cast<ExtractSubAsyncContext *>(data);
  if (ctx == nullptr) return;

  bool settled = false;
  if (status == napi_ok && ctx->errorMessage.empty()) {
    napi_value settleValue = nullptr;
    if (napi_create_string_utf8(env, ctx->jsonResult.c_str(), NAPI_AUTO_LENGTH, &settleValue) == napi_ok &&
        napi_resolve_deferred(env, ctx->deferred, settleValue) == napi_ok) {
      settled = true;
    }
  }
  if (!settled) {
    napi_value msg = nullptr;
    napi_value err = nullptr;
    const std::string &errStr = ctx->errorMessage.empty() ? "extractSub cancelled" : ctx->errorMessage;
    if (napi_create_string_utf8(env, errStr.c_str(), NAPI_AUTO_LENGTH, &msg) == napi_ok &&
        napi_create_error(env, nullptr, msg, &err) == napi_ok) {
      napi_reject_deferred(env, ctx->deferred, err);
    } else {
      // 兜底：确保 Promise 一定被 settle，避免 JS 端永久挂起
      napi_value fallback = nullptr;
      napi_create_string_utf8(env, "extractSub: internal napi error", NAPI_AUTO_LENGTH, &fallback);
      napi_value fallbackErr = nullptr;
      napi_create_error(env, nullptr, fallback, &fallbackErr);
      napi_reject_deferred(env, ctx->deferred, fallbackErr);
    }
  }

  napi_delete_async_work(env, ctx->work);
  delete ctx;
}

napi_value ExtractSubtitleEntries(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = { nullptr, nullptr, nullptr, nullptr };
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 4) {
    ThrowTypeError(env, "extractSubtitleEntries requires (url, headerLines, streamIndex, timeoutMs)");
    return nullptr;
  }

  std::string url;
  std::string headerLines;
  int64_t streamIndex = -1;
  int64_t timeoutMs = 30000;

  if (!ReadUtf8String(env, args[0], url)) {
    ThrowTypeError(env, "extractSubtitleEntries: url must be string");
    return nullptr;
  }
  if (!ReadUtf8String(env, args[1], headerLines)) {
    ThrowTypeError(env, "extractSubtitleEntries: headerLines must be string");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[2], &streamIndex) != napi_ok) {
    ThrowTypeError(env, "extractSubtitleEntries: streamIndex must be int64");
    return nullptr;
  }
  if (napi_get_value_int64(env, args[3], &timeoutMs) != napi_ok) {
    ThrowTypeError(env, "extractSubtitleEntries: timeoutMs must be int64");
    return nullptr;
  }

  if (streamIndex < 0 || streamIndex > (int64_t)INT_MAX) {
    ThrowRangeError(env, "extractSubtitleEntries: streamIndex out of range");
    return nullptr;
  }

  ExtractSubAsyncContext *ctx = new ExtractSubAsyncContext();
  ctx->url = url;
  ctx->headerLines = headerLines;
  ctx->streamIndex = (int)streamIndex;
  ctx->timeoutMs = timeoutMs;

  napi_value promise = nullptr;
  if (napi_create_promise(env, &ctx->deferred, &promise) != napi_ok) {
    delete ctx;
    ThrowTypeError(env, "extractSubtitleEntries: failed to create promise");
    return nullptr;
  }

  napi_value resourceName = nullptr;
  napi_create_string_utf8(env, "extractSubtitleEntriesAsync", NAPI_AUTO_LENGTH, &resourceName);

  if (napi_create_async_work(env, nullptr, resourceName,
                             ExecuteExtractSubAsync, CompleteExtractSubAsync,
                             ctx, &ctx->work) != napi_ok) {
    delete ctx;
    ThrowTypeError(env, "extractSubtitleEntries: failed to create async work");
    return nullptr;
  }

  if (napi_queue_async_work(env, ctx->work) != napi_ok) {
    napi_delete_async_work(env, ctx->work);
    delete ctx;
    ThrowTypeError(env, "extractSubtitleEntries: failed to queue work");
    return nullptr;
  }

  return promise;
}

} // namespace vidall
