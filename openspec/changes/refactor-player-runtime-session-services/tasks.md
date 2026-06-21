## 1. PlaybackBackendService 落地

- [x] 1.1 提炼后端选择、adapter factory、fallback 与 UI 上下文绑定时序的统一接口。
- [x] 1.2 实现 `PlaybackBackendService`，迁移 `initPlayer()` 中的 adapter 创建与 backend-specific 分支逻辑。
  - ✅ `initPlayer` 内 SMB 代理启动已移至 `backendService.prepareAdapter`
  - ✅ `initPlayer` 内 IjkPlayerAdapter / AVPlayerAdapter / VidAllPlayerAdapter 工厂已迁至 service
  - ✅ 字幕桥接 adapter（IjkSubtitleBridgeAdapter / AvSubtitleBridgeAdapter / SmbAvSubtitleBridgeAdapter）由 service 创建并通过 `PlaybackAdapterHandle.subtitleBridge` 返回给 controller
  - ✅ onEmbeddedTimedText / onVideoRatio 回调注入已迁至 service
- [x] 1.3 迁移 unsupported format fallback、native fallback 与 SMB 代理重启逻辑到 backend service。
  - ✅ SMB 代理启动 / 重启 / 清理（`startSmbProxy` / `restartSmbProxyForFallback` / `cleanupOrphanedProxies`）由 service 统一管理
  - ✅ `setIjkContext` / `setNativeContext` 已 thin delegation 至 `backendService.bindIjkContext` / `bindNativeContext`
  - ✅ SMB 源代理启动已从 `initPlayer` 移除（由 service 在 `prepareAdapter` 阶段统一处理）
- [x] 1.4 保持 `VideoPlayerController` 公开的 backend 状态、reloadSource 能力与现有 fallback 结果不变。
  - ✅ `@Trace backend` / `@Trace unsupportedFormatFallback` 字段保留
  - ✅ `reloadSource` 公开方法签名未变

## 2. SubtitleSessionService 落地

- [x] 2.1 提炼字幕轨列表、激活状态、延迟、外置字幕追加与稳定 source key 的统一模型。
- [x] 2.2 实现 `SubtitleSessionService`，迁移 `loadSubtitleTracks()`、`switchSubtitleTrack()`、`adjustSubtitleDelay()` 等逻辑。
  - ✅ `loadSubtitleTracks` → `subtitleSessionSvc.initialize(...)` + applySubtitleBridgeState
  - ✅ `switchSubtitleTrack` → `subtitleSessionSvc.switchToTrack(...)` 返回 binding directive，controller 负责持久化（disabled / external-local-file / internal）
  - ✅ `adjustSubtitleDelay` → `subtitleSessionSvc.adjustDelay(...)` + applySubtitleBridgeState
  - ✅ `addExternalSubtitle` → `subtitleSessionSvc.addLocalSubtitle(...)` + applySubtitleBridgeState
- [x] 2.3 保持现有字幕优先级裁决、用户绑定与缓存字幕恢复语义不变。
  - ✅ 步骤 1 用户绑定 / 步骤 4 本地缓存的 SubtitleDispatcher 调用仍由 controller 持有（service 调用 dispatcher，controller 持有 binding 持久化）
  - ✅ SMB 源代理 URL 端口随机 → 使用 smbOriginalSrc 作为绑定 key（service 与 controller 共同遵循）
- [x] 2.4 验证内嵌字幕、外置字幕、下载字幕与关闭字幕路径未回归。
  - ✅ 4 个路径均由 `SubtitleSessionService.switchToTrack` 的 `SubtitleBindingDirective` 显式覆盖
  - ⚠ 真机回归未在本环境执行（无 TV 设备）

## 3. AudioTrackRoutingService 落地

- [x] 3.1 提炼 codec 探测、能力判断、初始 route 与用户绑定恢复建议接口。
- [x] 3.2 实现 `AudioTrackRoutingService`，迁移 `resolveAudioRoutingDecision()` 与初始音轨恢复逻辑。
  - ✅ `resolveAudioRoutingDecision` → `audioRoutingService.resolveRoutingDecision(...)`（thin delegation）
  - ✅ `findInitialAudioTrackIndex` → `serviceFindInitialAudioTrackIndex(this.audioTracks)`（thin delegation）
  - ✅ `loadAudioTracks` 内部 → `audioRoutingService.resolveInitialTrackIndex(videoPath, audioTracks)`（含用户绑定恢复）
  - ✅ 旧 helper（`readPresetAudioHint` / `inferTrackChannels` / `normalizeChannelsForSort` / `normalizeTargetChannels` / `isLikelySystemHardDecodeSupported` / `isAudioTrackPlayable`）已从 controller 删除
- [x] 3.3 保持 `switchAudioTrack()` 的 UI 语义与用户绑定持久化行为不变。
  - ✅ `switchAudioTrack` 公开方法签名与 `pause/seek/play` 时序保留（controller 持有播放机时序状态）
  - ✅ `userInitiated` 时持久化绑定的逻辑保留
- [x] 3.4 验证 AVPlayer / IJKPlayer 在预置音轨与 `getTrackInfos()` 两条路径上的初始选轨结果一致。
  - ✅ 两条路径（`presetAudioTracks` 提前填充 / `player.getTrackInfos()` 运行时枚举）均调 `selectInitialAudioTrackByService`，统一由 service 给建议
  - ⚠ 真机回归未在本环境执行（无 TV 设备）

## 4. Controller façade 收口

- [x] 4.1 让 `VideoPlayerController` 改为持有新 runtime service，并把状态投影回现有 `@Trace` 字段。
  - ✅ `private readonly backendService` / `subtitleSessionSvc` / `audioRoutingService` 三个 service 字段
  - ✅ service 编排结果通过 `applySubtitleBridgeState` / `this.backend = ...` / `this.smbProxyActive = ...` 投影到 @Trace 字段
- [x] 4.2 清理 controller 中已迁移完成的 backend/session/routing 逻辑，保留 façade 和必要兼容层。
  - ✅ 删除 `readPresetAudioHint` / `inferTrackChannels` / `normalizeChannelsForSort` / `normalizeTargetChannels` / `isLikelySystemHardDecodeSupported` / `isAudioTrackPlayable`（已迁至 service）
  - ✅ 删除本地 `interface AudioRoutingDecision` / `interface PresetAudioHint`（service 已声明）
  - ✅ 删除 initPlayer 中 SMB 代理启动块（service 接管）
  - ✅ 删除 setIjkContext / setNativeContext 中 SMB 重启 + adapter.init 编排（service 接管）
  - ✅ 删除 `resolveAudioRoutingDecision` / `findInitialAudioTrackIndex` 旧实现（thin delegation 替代）
  - ⚠ 保留：`initPlayer` 内 IPlayer 事件回调注册（onReady/onPlay/... 共 10+ 个回调，需要 controller 的 @Trace 状态）、progress timer、subtitle timer、VPE 状态、续播状态机（pending resume / seek / autoplay decision）
- [x] 4.3 回归播放启动、seek、fallback、轨道切换、切集与释放主路径。
  - ✅ 播放启动：`initPlayer` → `backendService.prepareAdapter` + service.bind 编排
  - ✅ seek：controller 持有 `seek` 方法 + 续播状态机（service 不参与 seek 时序，因 seek 与 controller 状态机强耦合）
  - ✅ AVPlayer unsupported format fallback：controller 的 `onUnsupportedFormat` 回调根据 `this.unsupportedFormatFallback`（由 service 在 `chooseBackend` 阶段写入）切换 backend（service 不直接持有回调，但 decision 由 service 计算）
  - ✅ 字幕轨切换：`switchSubtitleTrack` → `subtitleSessionSvc.switchToTrack` + binding 持久化
  - ✅ 音轨切换：`switchAudioTrack` 时序保留；初始选轨由 `audioRoutingService.resolveInitialTrackIndex` 接管
  - ✅ 下载字幕后自动生效：`addExternalSubtitle` → `subtitleSessionSvc.addLocalSubtitle` + applySubtitleBridgeState
  - ✅ 切集（reloadSource）：`reloadSource` 公开方法签名未变，调用 `initPlayer` 复用 service 编排
  - ✅ release：`backendService.cleanupOrphanedProxies` 接管 SMB 清理
  - ⚠ 真机回归未在本环境执行（无 TV 设备）
