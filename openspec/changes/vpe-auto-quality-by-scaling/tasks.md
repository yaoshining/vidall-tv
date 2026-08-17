## 1. TS 类型契约（源视频宽高透传）

- [x] 1.1 `VideoData` 新增 `videoWidth?: number` / `videoHeight?: number`
- [x] 1.2 `AudioRoutingTypes`：`AudioRoutingInput.probeVideoWidth` / `probeVideoHeight`、`AudioRoutingDecision.videoWidth` / `videoHeight`、`DEFAULT_AUDIO_ROUTING_DECISION` 补默认值（`undefined`）
- [x] 1.3 `PlaybackBackendTypes`：`PlaybackBackendDecision.videoWidth` / `videoHeight`、`DEFAULT_BACKEND_DECISION` 与 `buildDefaultBackendDecision()` 补默认值

## 2. 路由 service 透传宽高

- [x] 2.1 `AudioTrackRoutingService.resolveRoutingDecision` 提取 `probe.videoTracks[0].width` / `height`
- [x] 2.2 `buildRoutingDecision` 输出 `videoWidth` / `videoHeight`
- [x] 2.3 `PlaybackBackendService.chooseBackend` 映射 `videoWidth` / `videoHeight`
- [x] 2.4 `VideoPlayerController`（initPlayer 写回 videoData 处）写回 `videoWidth` / `videoHeight` 并在 route-decision 日志带出

## 3. 自动选档纯函数

- [x] 3.1 在 `VideoPlayerController.ets`（或独立 util）新增导出纯函数 `resolveVpeQualityByScaling(srcW, srcH, dispW, dispH): VpeQualityLevel | null`，规则见 design.md「决策 2」
- [x] 3.2 阈值常量集中定义（如 `VPE_SCALE_MEDIUM_THRESHOLD = 1.5`、`VPE_SCALE_HIGH_THRESHOLD = 2.0`、输入分辨率上下限 32/2000、HIGH 下限 512）

## 4. 显示尺寸获取（多级 fallback）

- [x] 4.1 avplayer 分支 XComponent 补 `onAreaChange`，`vp2px` 转物理像素后缓存到 controller（`displayWidth` / `displayHeight`）；mpv 分支复用同一缓存
- [x] 4.2 新增显示尺寸解析工具：优先 XComponent 缓存尺寸，其次 `@ohos.display.getDefaultDisplaySync()` 屏幕物理像素，两者都无则返回 `undefined`
- [x] 4.3 显示尺寸后到（`onAreaChange` 晚于 initPlayer）时重算档位，档位变化则 `VpeEnhancerUtil.updateQuality()`（运行中换档，不重建管线）

## 5. Controller 门控整合

- [x] 5.1 `tryCreateVpeEnhancer` 在 HDR 守卫后调用 `resolveVpeQualityByScaling`；返回 `null`（源分辨率超硬约束）时跳过并记日志，否则以返回档位替代 `this.aiEnhanceQuality` 调用 `VpeEnhancerUtil.createEnhancer`
- [x] 5.2 `setAiEnhance` 语义调整：不再接收/存储用户档位（入参删除或忽略），开启即启用（至少 LOW），档位由自动选档决定
- [x] 5.3 `aiEnhanceQuality` 改为「当前已解析档位」派生值，不再由用户设置；确认无持久化需迁移（grep 确认无 AppPreferences 持久化）

## 6. UI 改动

- [x] 6.1 `PlayerSettingsDialog` 画质增强区移除「低/中/高」三个 chip，保留「关闭 / 开启」两个 chip
- [x] 6.2 删除 `@State aiEnhanceQuality` 及档位样式/onClick 分支；开启调用改为不带档位的 `setAiEnhance()`

## 7. 单元测试

- [x] 7.1 新增 `resolveVpeQualityByScaling` 用例：大幅放大→high、中等放大→medium、轻微放大/1:1/缩小→low、超上限(>2000)→null、低于下限(<32)→null、源<512 且 scale≥2→medium、数据缺失→low
- [x] 7.2 扩展 `tryCreateVpeEnhancer`/门控相关测试（HDR 不建 VPE；开启且非超限必建 VPE）——门控核心下沉到纯函数（`isHdrVideo` + `resolveVpeQualityByScaling`）并补组合用例；`tryCreateVpeEnhancer` 的 native 管线由真机验证覆盖

## 8. OpenSpec 产物

- [x] 8.1 `.openspec.yaml` / `proposal.md` / `design.md` / `tasks.md`
- [x] 8.2 delta spec `specs/vpe-quality-selection/spec.md`

## 9. 验证

- [x] 9.1 `openspec validate vpe-auto-quality-by-scaling` 通过
- [x] 9.2 `openspec validate --strict vpe-auto-quality-by-scaling` 通过
- [x] 9.3 `./hvigorw --mode module -p module=entry@default -p product=default assembleHap` 编译通过
- [x] 9.4 `./hvigorw --mode module -p module=entry@default UnitTestBuild --no-daemon` 通过（测试代码编译通过）
- [ ] 9.5 真机验证：4K 原盘 1:1 播放以 low 档建 VPE（开启即生效）；1080p 源在 4K 屏放大时按比例选档并日志可见；HDR 源仍跳过 VPE；设置页无档位选项；开启后必见 VPE 管线建立日志
- [ ] 9.6 真机验证残余风险：ffprobe 失败（源宽高未知）时，SDR 4K 源开启画质增强的行为——确认不会因超限输入导致黑屏/报错；若复现，补「宽高未知时保守不启用」策略（见 design.md Risks）

## 10. 归档（黑屏 issue #255 合并后执行）

- [ ] 10.1 `openspec archive vpe-auto-quality-by-scaling` 并同步 main specs
