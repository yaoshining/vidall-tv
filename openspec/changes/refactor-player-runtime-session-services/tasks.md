## 1. PlaybackBackendService 落地

- [x] 1.1 提炼后端选择、adapter factory、fallback 与 UI 上下文绑定时序的统一接口。
- [x] 1.2 实现 `PlaybackBackendService`，迁移 `initPlayer()` 中的 adapter 创建与 backend-specific 分支逻辑。
- [x] 1.3 迁移 unsupported format fallback、native fallback 与 SMB 代理重启逻辑到 backend service。
- [x] 1.4 保持 `VideoPlayerController` 公开的 backend 状态、reloadSource 能力与现有 fallback 结果不变。

## 2. SubtitleSessionService 落地

- [x] 2.1 提炼字幕轨列表、激活状态、延迟、外置字幕追加与稳定 source key 的统一模型。
- [x] 2.2 实现 `SubtitleSessionService`，迁移 `loadSubtitleTracks()`、`switchSubtitleTrack()`、`adjustSubtitleDelay()` 等逻辑。
- [x] 2.3 保持现有字幕优先级裁决、用户绑定与缓存字幕恢复语义不变。
- [x] 2.4 验证内嵌字幕、外置字幕、下载字幕与关闭字幕路径未回归。

## 3. AudioTrackRoutingService 落地

- [x] 3.1 提炼 codec 探测、能力判断、初始 route 与用户绑定恢复建议接口。
- [x] 3.2 实现 `AudioTrackRoutingService`，迁移 `resolveAudioRoutingDecision()` 与初始音轨恢复逻辑。
- [x] 3.3 保持 `switchAudioTrack()` 的 UI 语义与用户绑定持久化行为不变。
- [x] 3.4 验证 AVPlayer / IJKPlayer 在预置音轨与 `getTrackInfos()` 两条路径上的初始选轨结果一致。

## 4. Controller façade 收口

- [x] 4.1 让 `VideoPlayerController` 改为持有新 runtime service，并把状态投影回现有 `@Trace` 字段。
- [x] 4.2 清理 controller 中已迁移完成的 backend/session/routing 逻辑，保留 façade 和必要兼容层。
- [x] 4.3 回归播放启动、seek、fallback、轨道切换、切集与释放主路径。
