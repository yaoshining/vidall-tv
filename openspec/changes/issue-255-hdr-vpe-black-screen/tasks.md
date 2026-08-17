## 1. Native ffprobe 输出色彩元数据

- [x] 1.1 `ffmpeg_probe.cpp` 引入 `libavutil/pixdesc.h` / `libavutil/dovi_meta.h`
- [x] 1.2 `BuildProbeJson` 视频流分支追加 `pix_fmt` / `profile`（空值跳过）与 `bits_per_raw_sample` / `color_primaries` / `color_transfer` / `color_space` / `color_range`
- [x] 1.3 `BuildProbeJson` 解析 `codecpar->coded_side_data` 的 `AV_PKT_DATA_DOVI_CONF`，输出 `dv_profile` / `dv_level` / `dv_bl_signal_compatibility_id`

## 2. TS 类型契约

- [x] 2.1 `VideoData` 新增 `videoHdrType?: string`
- [x] 2.2 `AudioRoutingTypes`：`AudioRoutingInput.probeVideoHdrType`、`AudioRoutingDecision.videoHdrType`、`DEFAULT_AUDIO_ROUTING_DECISION` 补默认值
- [x] 2.3 `PlaybackBackendTypes`：`PlaybackBackendDecision.videoHdrType`、`DEFAULT_BACKEND_DECISION` 与 `buildDefaultBackendDecision()` 补默认值

## 3. 路由 service 透传 HDR 类型

- [x] 3.1 `AudioTrackRoutingService.resolveRoutingDecision` 提取 `probe.videoTracks[0].hdrType ?? ''`（未知/缺失统一空串）
- [x] 3.2 `buildRoutingDecision` 输出 `videoHdrType`
- [x] 3.3 `PlaybackBackendService.chooseBackend` 映射 `videoHdrType`

## 4. Controller VPE 门控

- [x] 4.1 新增导出纯函数 `isHdrVideo`
- [x] 4.2 扩展 `shouldShowAiEnhanceSettingsByRuntime(runtimeSupported, backend, isHdr=false)`
- [x] 4.3 `initPlayer` 写回 `videoData.videoHdrType` 并在 route-decision 日志带出（空串显示「未知」）
- [x] 4.4 `tryCreateVpeEnhancer` 增加 HDR 跳过守卫
- [x] 4.5 `shouldShowAiEnhanceSettings()` 对 HDR 隐藏设置区
- [x] 4.6 `tryCreateVpeEnhancer` HDR 分支销毁已运行的 VPE 实例（SDR→HDR 切换释放旧 surface）

## 5. 单元测试

- [x] 5.1 新增 `isHdrVideo` 判定用例
- [x] 5.2 扩展 `shouldShowAiEnhanceSettingsByRuntime` HDR 用例
- [x] 5.3 controller 层 `shouldShowAiEnhanceSettings()` 对 HDR 隐藏 / SDR 显示的接线用例

## 6. OpenSpec 产物

- [x] 6.1 `.openspec.yaml` / `proposal.md` / `design.md` / `tasks.md`
- [x] 6.2 delta spec `specs/vpe-runtime-compatibility/spec.md`

## 7. 验证

- [x] 7.1 `openspec validate issue-255-hdr-vpe-black-screen` 通过
- [x] 7.2 `openspec validate --strict issue-255-hdr-vpe-black-screen` 通过
- [x] 7.3 `assembleHap` 编译通过（native C++ + ArkTS）
- [x] 7.4 `UnitTestBuild` 编译通过
- [ ] 7.5 真机验证：HDR 出现「[VPE] 跳过创建: HDR 视频不启用 VPE」且无 `29210006`；SDR 仍「[VPE] 管线建立」（待 EDIS-790A 真机样本确认）
