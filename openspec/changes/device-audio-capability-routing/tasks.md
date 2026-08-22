## 1. Native 解码能力查询

- [x] 1.1 扩展 `audio_capability.cpp` 的 `BuildAudioMime`，补齐 ac3/eac3/truehd/dts/dtshd/mlp/vivid/vorbis/pcm 的归一化 codec → MIME 映射
- [x] 1.2 修正 `capabilityKnown` 语义：解码器不存在时 `capabilityKnown=true, supported=false`，保留 `errorMessage="decoder not found"`

## 2. 能力服务与类型

- [x] 2.1 新增 `services/audioCapability/AudioCapabilityTypes.ets`（能力结果、兼容结论、纠偏条目、CapabilityProvider 抽象）
- [x] 2.2 新增 `services/audioCapability/AudioDecoderCapabilityService.ets`（NAPI bridge、两级缓存、纠偏读写、`resolveTrackCompatibility`/`recordCorrection`）
- [x] 2.3 新增 `PrefKey.AUDIO_CAPABILITY_CORRECTIONS`，纠偏结果经 AppPreferences 持久化并按 device/os 过滤

## 3. 路由类型与决策改造

- [x] 3.1 抽 `services/audioRouting/AudioCodecUtil.ets`（normalizeAudioCodec、声道归一化），避免循环依赖，保留旧 re-export
- [x] 3.2 `AudioRoutingTypes.ets`：`AudioTrackAnalysis` 增加 `compatible/maxChannels/isHardware/capabilitySource`，`AudioRoutingDecision` 增加 `recommendedInitialTrackIndex/recommendedCodec/capabilitySummary`
- [x] 3.3 `AudioTrackRoutingService.resolveRoutingDecision` 按归一化 codec 去重后查询能力，填充每条音轨兼容性
- [x] 3.4 `buildRoutingDecision` 改用真实能力判定（兼容→avplayer+预选；无兼容→mpv；异常→mpv+黑名单兜底），并实现最佳兼容轨排名
- [x] 3.5 `resolveInitialTrackIndex`/`rankAudioTracksByCapability` 改用 per-track 兼容排名，无能力信息回退现有排名

## 4. 控制器接线

- [x] 4.1 `VideoPlayerController` 存储 `lastRoutingDecision`，`AudioTrackItem` 增加 `channels?` 并填充
- [x] 4.2 `selectInitialAudioTrackByService` 经 `resolveInitialTrackIndex` 应用能力排名选轨
- [x] 4.3 AVPlayer 显式失败（onUnsupportedFormat / 5400106 / 5400103）时记录纠偏并保留续播
- [x] 4.4 路由决策与能力日志补充 source/cache-hit/correction/recommendedTrack 字段

## 5. AVPlayerAdapter 收敛

- [x] 5.1 移除 PREPARED 阶段全局黑名单"全不支持即 fallback"判定，PREPARED 直接 ready（保留诊断日志）
- [x] 5.2 保留 error 5400106/5400103 → onUnsupportedFormat 动态降级；降级全局黑名单为查询异常迁移兜底

## 6. 单元测试

- [x] 6.1 `AudioCodecUtil.test.ets`：归一化 codec 与声道边界
- [x] 6.2 `AudioDecoderCapabilityService.test.ets`：codec 去重、声道边界、缓存命中/失效、查询异常、纠偏优先
- [x] 6.3 路由决策测试：多轨混合、全不兼容→mpv、全 unknown→mpv、预选最优轨
- [x] 6.4 既有 `VideoPlayerController.test.ets` 保持通过（`findInitialAudioTrackIndex` 回退路径兼容）

## 7. 验证

- [x] 7.1 本地单测编译通过（UnitTestBuild）+ 设备端单测 604/604 通过
- [x] 7.2 ArkTS HAP 构建通过，无新增编译/ArkTS 护栏错误
- [x] 7.3 真机验证：eac3→mpv（能力缓存命中，无兼容轨直接选 MPV）、aac→avplayer（兼容轨）；日志可见 capabilitySource/缓存/recommendedTrack；修复并验证了"直接选 MPV 时后端切换触发冗余重建导致黑屏/无音轨"的问题（design.md 决策 7）
