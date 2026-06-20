## Why

`VideoPlayerController` 当前同时承担后端选择、fallback、字幕会话、音轨路由、resume 恢复与大量运行时状态，已经成为播放器复杂度的单点堆积位置。若后续继续新增播放器后端、字幕策略或音频能力分支，controller 会进一步膨胀，因此需要把运行时核心会话拆成独立 service。

## What Changes

- 新增 `PlaybackBackendService`，统一后端选择、adapter 生命周期、fallback、init/release 与 UI 上下文绑定时序。
- 新增 `SubtitleSessionService`，统一字幕轨列表、激活状态、切换、延迟与会话级稳定 source key。
- 新增 `AudioTrackRoutingService`，统一 codec 探测、能力判断、初始音轨选择与 fallback 建议。
- 将 `VideoPlayerController` 调整为运行时 façade，保留现有 UI API，但把运行时核心编排委托给独立 service。
- 保持现有 UI 组件、播放入口参数、轨道切换语义与现有 fallback 结果不变。

## Capabilities

### New Capabilities
- `playback-backend-service`: 为播放器运行时提供后端选择、fallback、adapter 创建与 UI 上下文绑定编排能力。
- `subtitle-session-service`: 为一次播放会话提供统一的字幕轨加载、切换、延迟与当前激活状态管理能力。
- `audio-track-routing-service`: 为播放会话提供 codec 探测、能力判断、初始音轨恢复与 fallback 建议能力。

### Modified Capabilities
- `avplayer-codec-detection-fallback`: AVPlayer 不支持格式后的 fallback 逻辑改为由 backend service 统一编排，但外部行为保持兼容。
- `audio-track-binding`: 音轨恢复流程改为由 routing service 驱动，但用户绑定语义保持不变。
- `subtitle-priority-dispatcher`: 字幕优先级裁决将嵌入 subtitle session flow，但现有优先级语义保持不变。

## Impact

- 主要影响代码：
  - `entry/src/main/ets/components/core/player/VideoPlayerController.ets`
  - `entry/src/main/ets/components/core/player/VideoPlayer.ets`
  - `entry/src/main/ets/components/core/player/AVPlayerAdapter.ets`
  - `entry/src/main/ets/components/core/player/IjkPlayerAdapter.ets`
  - `entry/src/main/ets/components/core/player/VidAllPlayerAdapter.ets`
  - `entry/src/main/ets/components/core/player/SubtitleBridgeAdapter.ets`
  - `entry/src/main/ets/audio/AudioDispatcher.ets`
  - `entry/src/main/ets/subtitle/SubtitleDispatcher.ets`
- 保持不变：
  - `VideoPlayerController` 主要公开状态与方法
  - `switchSubtitleTrack(-1)`、`switchAudioTrack(index)` 等 UI 语义
  - 现有 prepared / seek / fallback 后恢复播放的总体时序结果
- 风险集中在播放时序、轨道恢复与 fallback-resume 状态机，需要在 controller façade 稳定前提下渐进迁移。
