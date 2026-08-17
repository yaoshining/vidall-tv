# HDR 视频黑屏诊断（HDR + VPE / AI 画质增强）

> 目的：以后再遇到「HDR 视频黑屏 / 画面不渲染」时，能用日志在**第一时间定位根因**，而不是重新排查一遍。

## 一句话结论（快速定位）

**HDR 视频黑屏 + 时间在走 + `VPE onError: 29210006` = VPE（AI 画质增强）不支持 HDR，不是解码失败、不是片源损坏。**

原始案例：issue #255（`御赐小仵作第二季/01.mp4` HDR 黑屏 vs `S01 4K EP 01.mkv` SDR 正常，两者都走 avplayer + VPE）。

## 现象特征

- HDR 视频打开**黑屏**，但进度/时间在走（`play_result result=success elapsed_ms=...` 正常递增）。
- 同源/同目录的 **SDR 视频正常**。
- 两条都走 avplayer + AI 画质增强（VPE）。

## 日志签名（一眼定位，按顺序匹配）

```text
[initPlayer.route-decision] backend=avplayer, fallback=mpv, anyHardSupported=true
[VPE] tryCreate: supported=true enabled=true backend=avplayer quality=medium
VidAll_Metrics: play_result backend=avplayer result=success elapsed_ms=2499   ← 时间在走，首帧"成功"是假的
VidAll: VPE onError: 29210006                                                 ← 随后刷屏
[aisr_video_algorithm.cpp] hdrType 3 is not sdr, not support                  ← 决定性证据
```

**决定性证据**：`29210006` + `hdrType 3 is not sdr, not support`（来自华为系统库 `libvideo_processing.so` 的 `aisr_video_algorithm.cpp`）。

## 根因

VPE（Video Processing Engine，AI 画质增强）**只支持 SDR**。HDR 视频经 VPE 管线处理时 native 报 `29210006`，视频时间前进但画面渲染失败 → 黑屏。

## 判定方法（ffprobe 判 HDR）

`FfprobeUtil.parseHdrType` 依据 ffprobe 视频流的 `color_transfer` / DV profile 判定：

| 信号 | 值 | 判定 |
|---|---|---|
| `color_transfer` | 16（SMPTE ST 2084 / PQ） | HDR10 |
| `color_transfer` | 18（ARIB STD-B67） | HLG |
| `dv_profile > 0` 或 `profile` 含 "Dolby Vision" | — | Dolby Vision |
| 其它 | — | SDR |

注意：`color_transfer` 由 native ffprobe 输出（`ffmpeg_probe.cpp` `BuildProbeJson`）；字段名是 `color_transfer`（对应 `AVCodecParameters.color_trc`）。若日志里 `videoHdrType` 恒为 `SDR`/空，先确认 native ffprobe 是否输出了色彩字段。

修复后的路由日志会直接带出：

```text
[initPlayer.route-decision] ... videoHdrType=HDR10
```

## 修复方案

### 方向 1（已实现，issue #255）：HDR 时不启用 VPE，走 AVPlayer 原生渲染

- ffprobe 判 HDR → `VideoPlayerController.tryCreateVpeEnhancer` 跳过 VPE，返回原始 surfaceId。
- 期望日志：`[VPE] 跳过创建: HDR 视频不启用 VPE (hdrType=HDR10)`
- SDR 仍应：`[VPE] 管线建立`

### 方向 2（兜底，按需启用）：AVPlayer 原生 HDR 也渲染不了 → 路由 mpv（libmpv）

- VidAll_Player（`@vidall/player`，libmpv）侧已支持显式 tone mapping：`tone-mapping=bt.2390` + `hdr-compute-peak=auto`（VidAll_Player PR #67 / issue #66）。
- 触发条件：真机验证发现 AVPlayer **原生** HDR 也黑屏时，才需要在 VidAll_TV 补「检测到 HDR → `preferredBackend=mpv`」的路由逻辑。
- 注意：libmpv 的 tone mapping 依赖 **GL shader（vo_gpu）**；软件渲染/模拟器无 GL shader 不 tone map。HDR 效果仅在真机 GL 路径承诺。

## 关键代码位置

| 关注点 | 位置 |
|---|---|
| native ffprobe 输出 `color_transfer`/`pix_fmt` 等 | `entry/src/main/cpp/ffmpeg_probe.cpp`（`BuildProbeJson`） |
| HDR 判定 | `entry/src/main/ets/utils/FfprobeUtil.ets`（`parseHdrType`） |
| HDR 类型透传 | `AudioTrackRoutingService.resolveRoutingDecision` → `AudioRoutingDecision.videoHdrType` → `VideoData.videoHdrType` |
| VPE 门控 | `entry/src/main/ets/components/core/player/VideoPlayerController.ets`（`isHdrVideo` / `tryCreateVpeEnhancer` / `shouldShowAiEnhanceSettings`） |
| VPE native 封装 | `entry/src/main/ets/utils/VpeEnhancerUtil.ets` |

## 关联

- VidAll_TV issue [#255](https://github.com/yaoshining/vidall-tv/issues/255)
- VidAll_Player issue [#66](https://github.com/yaoshining/VidAll_Player/issues/66) / PR [#67](https://github.com/yaoshining/VidAll_Player/pull/67)
