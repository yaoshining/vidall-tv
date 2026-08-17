## Why

issue #255：HDR 视频走 avplayer + AI 画质增强（VPE）时黑屏。根因是 VPE 只支持 SDR，HDR 视频（`hdrType 3`）经 VPE 处理时报 `29210006`（`[aisr_video_algorithm.cpp] hdrType 3 is not sdr, not support`），视频时间前进但画面渲染失败。

本变更采用修复方向 1：ffprobe 探测视频色彩元数据判 HDR，HDR 时跳过 VPE 管线，走 AVPlayer 原生渲染。

## What Changes

- **native ffprobe 输出视频色彩元数据**：`ffmpeg_probe.cpp` 的 `BuildProbeJson` 在视频流中追加输出 `pix_fmt` / `profile` / `bits_per_raw_sample` / `color_primaries` / `color_transfer` / `color_space` / `color_range`，并解析 `AV_PKT_DATA_DOVI_CONF` 输出 `dv_profile` / `dv_level` / `dv_bl_signal_compatibility_id`。其中 `color_transfer` 是关键字段（`SMPTE2084=16`→HDR10、`ARIB_STD_B67=18`→HLG）。
- **TS 侧透传 HDR 类型**：`AudioTrackRoutingService.resolveRoutingDecision` 从 `probe.videoTracks[0].hdrType` 提取 HDR 类型（未知/缺失统一空串），经 `AudioRoutingDecision.videoHdrType` → `PlaybackBackendDecision.videoHdrType` → `VideoData.videoHdrType` 透传到 controller。
- **VPE 门控**：`VideoPlayerController.tryCreateVpeEnhancer` 在 `isHdrVideo()` 为 true 时跳过 VPE 创建（并销毁 SDR→HDR 切换残留的旧增强器），返回原始 surfaceId；`shouldShowAiEnhanceSettings()` 对 HDR 视频隐藏「画质增强」设置区。
- **新增纯函数** `isHdrVideo(hdrType)` 与扩展 `shouldShowAiEnhanceSettingsByRuntime(runtimeSupported, backend, isHdr)`，并补充单元测试。

## Capabilities

### Modified Capabilities

- `vpe-runtime-compatibility`：新增「HDR 视频不启用 VPE」与「ffprobe 输出视频色彩元数据」两条需求。

## Impact

- **修改代码**：
  - `entry/src/main/cpp/ffmpeg_probe.cpp`（native ffprobe 输出）
  - `entry/src/main/ets/services/audioRouting/AudioRoutingTypes.ets`、`AudioTrackRoutingService.ets`
  - `entry/src/main/ets/services/playback/PlaybackBackendTypes.ets`、`PlaybackBackendService.ets`
  - `entry/src/main/ets/components/core/player/VideoData.ets`、`VideoPlayerController.ets`
- **修改测试**：`entry/src/test/VideoPlayerController.test.ets`
- **不变**：后端路由决策（仍为 avplayer/mpv）；`aiEnhanceEnabled` 仍为用户全局偏好，不因 HDR 强制改写；`PlayerSettingsDialog` 无需改动。
- **依赖**：无新增第三方依赖；native 侧仅多调用 FFmpeg 8 已导出的 API（`av_get_pix_fmt_name` / `avcodec_profile_name` / `av_packet_side_data_get` / `AVCodecParameters` 色彩与 side data 字段），无需重编 FFmpeg `.so`。

## 延后（本次不做）

- 方向 2（HDR 直接路由 mpv）仅作为「AVPlayer 原生 HDR 渲染也不可用」时的后续 fallback，不在本变更范围。
- 变更归档（`openspec archive` 并同步 main specs）留待 PR 合并后的独立 chore 提交。
