# Design: issue-255-hdr-vpe-black-screen

## Context

HDR 视频（`御赐小仵作第二季/01.mp4`）从季详情页打开黑屏；SDR（`S01 4K EP 01.mkv`）正常。两者都走 avplayer + VPE。日志显示 `VPE onError: 29210006` 与 `hdrType 3 is not sdr, not support`，即 VPE 只支持 SDR。

TS 侧 `FfprobeUtil.parseHdrType` 已具备 HDR 判定逻辑（`color_transfer===16`→HDR10、`===18`→HLG、DV→DOLBY_VISION），但 native `ffmpeg_probe.cpp` 的 `BuildProbeJson` 从未输出这些色彩字段，导致 `hdrType` 恒为 `SDR`。因此修复分两层：native 补输出、TS 侧透传并门控 VPE。

## Goals / Non-Goals

**Goals:**
- HDR（HDR10/HLG/DV）视频不建立 VPE 管线，走 AVPlayer 原生渲染。
- SDR 视频保持现有 VPE 行为不变。
- 让 ffprobe 探测结果携带视频色彩元数据，供 HDR 判定（也为后续能力判断复用）。

**Non-Goals:**
- 不改变后端路由决策（仍 avplayer/mpv）。
- 不引入「HDR 自动路由 mpv」。
- 不重编/替换 FFmpeg `.so`（复用 FFmpeg 8 已导出的符号）。
- 不改动 `PlayerSettingsDialog`（通过 `shouldShowAiEnhanceSettings()` 隐藏区段即可）。

## Decisions

### 1. 用 `color_trc`（`color_transfer`）作为 HDR 判定核心信号
FFmpeg `AVCodecParameters.color_trc` 是 HDR 的标准判定依据：`AVCOL_TRC_SMPTE2084=16`（PQ/HDR10）、`AVCOL_TRC_ARIB_STD_B67=18`（HLG）。
- **为什么**：与 issue 修复方向 1 的描述（smpte2084 / arib-std-b67）一致，且不依赖文件名字符串、不把「10bit」误判为 HDR（10bit SDR 存在）。
- **备选**：`pix_fmt` 含 `p10` + `color_primaries=9`(BT2020) 组合判断 —— 更复杂且仍无法覆盖 HLG 的 transfer 差异，弃用为辅助字段。

### 2. native 侧只补输出、不改 FFmpeg
`BuildProbeJson` 追加 `pix_fmt`/`profile`/`bits_per_raw_sample`/`color_primaries`/`color_transfer`/`color_space`/`color_range`，全部来自 `AVCodecParameters` 已有字段。
- **为什么**：这些字段在 FFmpeg 8 的 `AVCodecParameters` 中已存在，`av_get_pix_fmt_name` / `avcodec_profile_name` 也已导出；只需读取并写入 JSON，无需重编 `.so`。
- **边界**：本捆绑 FFmpeg 的 `AVStream` 无 `side_data`、无 `av_stream_get_side_data`，故 DV 的 `dv_profile` 侧数据无法输出。DV 依赖 `color_trc`（通常 16/18）与 `profile` 字符串含 "Dolby Vision" 兜底，best-effort。

### 3. HDR 类型经 routing decision 透传（不另起 probe）
HDR 类型随 `resolveRoutingDecision` 内的既有 ffprobe 结果（`probe.videoTracks[0]`）提取，沿 `AudioRoutingDecision.videoHdrType` → `PlaybackBackendDecision.videoHdrType` → `VideoData.videoHdrType` 传递。
- **为什么**：`videoCodecName` 已走同一条「routing service 的 ffprobe → decision → videoData」链路，HDR 类型与其同源同生命周期；避免在各播放入口页重复探测。
- **降级**：ffprobe 失败时 `probeVideoHdrType=''`，`videoHdrType=''`，`isHdrVideo` 为 false → VPE 按现状启用（与既有行为一致，无法判定时保守放行）。

### 4. VPE 门控放在 `tryCreateVpeEnhancer`（按当前视频内容）
在 `tryCreateVpeEnhancer` 内，`isHdrVideo(this.currentVideoData?.videoHdrType)` 为 true 时直接返回 `displaySurfaceId`。
- **为什么**：VPE 只对 `backend==='avplayer'` 生效，且 `currentVideoData` 在 `initPlayer` 内已同步赋值；门控点单一、覆盖所有 avplayer 入口。
- **不强制改写 `aiEnhanceEnabled`**：HDR 是「当前视频内容」属性，不是运行时能力或用户偏好；跳过 VPE 是每会话行为，切回 SDR 自动恢复。设置区通过 `shouldShowAiEnhanceSettings()` 对 HDR 隐藏，避免用户看到「已开启」的误导。

### 5. 纯函数 `isHdrVideo` / 扩展 `shouldShowAiEnhanceSettingsByRuntime`
- `isHdrVideo(hdrType)` 集中判定 `'HDR10' | 'HLG' | 'DOLBY_VISION'`，便于单测。
- `shouldShowAiEnhanceSettingsByRuntime(runtimeSupported, backend, isHdr=false)` 追加 `!isHdr`，第三参默认 `false` 保持既有两参调用兼容。

## Risks / Trade-offs

- **AVPlayer 原生 HDR 渲染能力未经真机确认**：本变更假设「仅 VPE 破坏渲染」。若真机证明 AVPlayer 原生也黑屏，需启用方向 2（HDR 路由 mpv，见关联 issue）。
- **DV 识别不精确**：无 side data 时 DV 可能被归为 HDR10（`color_trc=16`），结果仍会跳过 VPE，行为安全。
- **JSON 体积微增**：每个视频流多约 7 个字段，可忽略。
