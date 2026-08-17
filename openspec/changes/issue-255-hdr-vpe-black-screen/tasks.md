## 1. Native ffprobe 输出色彩元数据

- [x] 1.1 `ffmpeg_probe.cpp` 引入 `libavutil/pixdesc.h`
- [x] 1.2 `BuildProbeJson` 视频流分支追加 `pix_fmt` / `profile`（空值跳过）与 `bits_per_raw_sample` / `color_primaries` / `color_transfer` / `color_space` / `color_range`

## 2. TS 类型契约

- [x] 2.1 `VideoData` 新增 `videoHdrType?: string`
- [x] 2.2 `AudioRoutingTypes`：`AudioRoutingInput.probeVideoHdrType`、`AudioRoutingDecision.videoHdrType`、`DEFAULT_AUDIO_ROUTING_DECISION` 补默认值
- [x] 2.3 `PlaybackBackendTypes`：`PlaybackBackendDecision.videoHdrType`、`DEFAULT_BACKEND_DECISION` 与 `buildDefaultBackendDecision()` 补默认值

## 3. 路由 service 透传 HDR 类型

- [x] 3.1 `AudioTrackRoutingService.resolveRoutingDecision` 提取 `probe.videoTracks[0].hdrType ?? 'SDR'`
- [x] 3.2 `buildRoutingDecision` 输出 `videoHdrType`
- [x] 3.3 `PlaybackBackendService.chooseBackend` 映射 `videoHdrType`

## 4. Controller VPE 门控

- [x] 4.1 新增导出纯函数 `isHdrVideo`
- [x] 4.2 扩展 `shouldShowAiEnhanceSettingsByRuntime(runtimeSupported, backend, isHdr=false)`
- [x] 4.3 `initPlayer` 写回 `videoData.videoHdrType` 并在 route-decision 日志带出
- [x] 4.4 `tryCreateVpeEnhancer` 增加 HDR 跳过守卫
- [x] 4.5 `shouldShowAiEnhanceSettings()` 对 HDR 隐藏设置区

## 5. 单元测试

- [x] 5.1 新增 `isHdrVideo` 判定用例
- [x] 5.2 扩展 `shouldShowAiEnhanceSettingsByRuntime` HDR 用例

## 6. OpenSpec 产物

- [x] 6.1 `.openspec.yaml` / `proposal.md` / `design.md` / `tasks.md`
- [x] 6.2 delta spec `specs/vpe-runtime-compatibility/spec.md`

## 7. 验证

- [ ] 7.1 `openspec validate issue-255-hdr-vpe-black-screen` 通过
- [ ] 7.2 `openspec validate --strict issue-255-hdr-vpe-black-screen` 通过
- [ ] 7.3 `./hvigorw --mode module -p module=entry@default -p product=default assembleHap` 编译通过
- [ ] 7.4 `./hvigorw --mode module -p module=entry@default UnitTestBuild --no-daemon` 通过
- [ ] 7.5 真机验证：HDR 出现「[VPE] 跳过创建: HDR 视频不启用 VPE」且无 `29210006`；SDR 仍「[VPE] 管线建立」
