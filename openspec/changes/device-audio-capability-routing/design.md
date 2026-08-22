## Context

见 `proposal.md`。当前音频路由在 `AudioTrackRoutingService` 用静态 `codecCompatibilityRank` + `isLikelySystemHardDecodeSupported` 判定软/硬解，`buildRoutingDecision` 永远返回 `preferredBackend='avplayer'` 并以 `fallback='mpv'` 兜底；`AVPlayerAdapter` 在 PREPARED 阶段再用全局黑名单 `UNSUPPORTED_AUDIO_CODECS` 做二次判定。这导致路由决策与设备真实能力脱节，全局黑名单既可能误降级（设备能解码却仍降级），又延迟了"无兼容轨"的判定（要等 AVPlayer prepare 后才 fallback）。

本变更把能力判定前移到 `AudioDecoderCapabilityService`，路由决策与初始选轨都以它为准，后端在创建 AVPlayer 之前就确定，AVPlayerAdapter 的黑名单判定移除，显式失败转为纠偏记录。

## Goals / Non-Goals

**Goals:**
- 后端选择与初始音轨选择都由设备真实解码能力（codec 支持 + 最大声道）驱动。
- 无兼容音轨时在创建/prepare AVPlayer 前直接选 MPV，避免二次初始化。
- 按归一化 codec 去重查询，能力缓存按设备型号/系统版本/codec/声道数键控，系统升级自然失效。
- 设备/固件纠偏优先于系统声明，AVPlayer 显式失败可记录并复用纠偏。
- 能力查询异常不阻塞播放，保守降级并保留迁移期黑名单兜底。

**Non-Goals:**
- 不逐音轨试播、不新增批量 NAPI 接口、不改 MPV / FFmpeg 解码链。
- 不做"静默无声"的主动探测；纠偏触发点仅限 AVPlayer 明确失败。
- 不改变 `IPlayer`、`PlaybackBackendService` 对外方法与 controller 对 UI 暴露的行为契约。

## Decisions

### 1. 能力判定统一收敛到 `AudioDecoderCapabilityService`

新增 `services/audioCapability/`，封装 NAPI `queryAudioDecoderCapability` 的桥接、缓存与纠偏。路由服务与初始选轨都调用它的 `resolveTrackCompatibility(codec, channels)`，避免多处重复实现能力判定。NAPI 桥接仿 `VpeEnhancerUtil` 的 default/直接导出兼容解析，`.so` 未加载时返回 `capabilityKnown=false` 而非抛异常。

备选方案是在 `AudioTrackRoutingService` 内联查询，但会与 controller 的初始选轨逻辑重复，且无法单测注入假 provider，因此不采用。

### 2. 两级缓存：原始能力去重 + 派生兼容结论

- `codecCapCache`（键 `${deviceModel}|${osVersion}|${codec}`）缓存原始 NAPI 结果，负责"同 codec 去重查询"，满足"N 种唯一 codec 最多查 N 次"。
- `compatCache`（键 `${deviceModel}|${osVersion}|${codec}|${channels}`）缓存派生兼容结论，满足"缓存键包含设备型号/系统版本/codec/声道数"，并让系统版本变化自然失配。

两级分开比单层 `codec|channels` 缓存更清晰：原始查询天然按 codec 去重，声道边界校验在派生层完成。

### 3. 纠偏持久化到 AppPreferences

纠偏结果存 `PrefKey.AUDIO_CAPABILITY_CORRECTIONS`（JSON 数组 `{deviceModel, osVersion, codec, forceUnsupported, reason, updatedAt}`），加载时按当前 `deviceModel|osVersion` 过滤，旧系统条目自然不命中。内存 Map 作为热缓存，显式失败时先写内存再异步持久化。

备选方案仅内存保存会在应用重启后丢失"历史纠偏"，与"可复用"语义冲突，因此加入持久化。

### 4. 后端决策优先级

按 Issue 建议流程实现：

1. 设备/固件纠偏命中 → 以纠偏为准（`source='correction'`）。
2. 系统 codec 能力 + 最大声道范围 → `compatible = supported && channels <= maxChannels`。
3. 能力未知或查询异常 → `source='unknown'`，保守 `preferredBackend='mpv'`，迁移期黑名单仅此时兜底。

### 5. 预选最佳兼容轨

`buildRoutingDecision` 在所有兼容音轨中按「硬件解码优先 → 语言偏好（首选轨语言 / 用户绑定）→ 声道数更高（不超上限）→ 索引最小」排序，取最优作为 `recommendedInitialTrackIndex`。初始选轨 `resolveInitialTrackIndex` 复用同一套兼容排名；无能力信息时回退现有 codec 排名。

### 6. AVPlayerAdapter 移除黑名单判定，显式失败转纠偏

`PREPARED` 阶段不再读取 `getTrackDescription` 判"全不支持"，直接 `_onReadyCb`（保留诊断日志）。error 事件 5400106/5400103 → `onUnsupportedFormat` 的降级路径保留，并由 controller 在 fallback 前调 `recordCorrection` 记录纠偏。

## Risks / Trade-offs

- [NAPI 在 `.so` 未加载或 OH_AVCodec 异常时无结果] → bridge 捕获异常返回 `capabilityKnown=false`，路由保守选 MPV，不阻塞播放。
- [声道数据缺失] → 预置/ffprobe 有声道时严格校验；运行时 `getTrackInfos()` 无声道时保守按可用处理，交给显式失败纠偏。
- [归一化 codec 无法映射 MIME] → `source='unknown'`，黑名单兜底，日志记录未映射 codec。
- [缓存键含系统版本导致条目膨胀] → 缓存进程级、键空间有限（设备型号/系统版本/codec 归一化/声道 1/2/6/8），无需淘汰策略。
- [纠偏误判（临时网络失败被记为不支持）] → 仅"明确格式不支持"错误码（5400106/5400103）触发纠偏，不把网络/IO 错误记为不支持。
- [移除 PREPARED 黑名单后回归] → 后端已在创建前确定，无兼容轨不会走到 AVPlayer；保留显式失败动态降级作为安全网。

## Migration Plan

1. 抽 `AudioCodecUtil` 并新增 `AudioDecoderCapabilityService`（不改变现有决策行为）。
2. 改造 `AudioRoutingTypes`/`AudioTrackRoutingService`，接入能力判定与预选。
3. `VideoPlayerController` 接线（存储决策、记录纠偏、选轨）；`AVPlayerAdapter` 移除黑名单判定。
4. 补 C++ MIME 映射与 `capabilityKnown` 语义。
5. 单元测试 + ArkTS 构建验证；真机验证不同设备对同一片源产生不同后端决策。
6. 若回归，可先回退 `AVPlayerAdapter` 的黑名单判定为查询异常兜底，其余能力链路不受影响。
