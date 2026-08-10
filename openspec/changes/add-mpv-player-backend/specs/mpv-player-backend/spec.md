## Purpose

Define the behavior contract for integrating the mpv-based `@vidall/player` backend into VidAll_TV as a selectable fallback player kernel, including the `MpvPlayerAdapter` implementation, XComponent surface binding, and event mapping to the existing `IPlayer` interface.

## ADDED Requirements

### Requirement: MPV backend SHALL be registered as a selectable playback backend
系统 MUST 在 `PlaybackBackendService` 的后端枚举中注册 `'mpv'` 作为可选播放后端，与现有 `'avplayer'` / `'ijkplayer'` 并列，且不影响现有后端的任何行为。

#### Scenario: Backend enumeration includes mpv
- **WHEN** 系统初始化播放后端选择逻辑
- **THEN** `'mpv'` SHALL 作为有效的 `PlayerBackend` 值存在
- **AND** 现有 `'avplayer'` / `'ijkplayer'` 后端行为 SHALL 保持不变

#### Scenario: mpv adapter creation
- **WHEN** 后端决策结果为 `'mpv'`
- **THEN** `PlaybackBackendService` SHALL 创建 `MpvPlayerAdapter` 实例
- **AND** 该实例 SHALL 实现 `IPlayer` 接口的全部方法与回调注册

### Requirement: MPV backend SHALL use XComponentController surface binding mode
系统 MUST 使用 `XComponentController` 模式（而非 `libraryname` 模式）为 mpv 后端绑定 XComponent Surface，与 avplayer 分支的绑定方式一致。

#### Scenario: mpv XComponent branch in player UI
- **WHEN** 当前后端为 `'mpv'` 且播放页 UI 构建 XComponent
- **THEN** UI SHALL 使用 `XComponentController` 模式创建 XComponent
- **AND** UI SHALL NOT 使用 `libraryname` 属性
- **AND** UI SHALL 在 `onLoad` 回调中通过 `XComponentSurfaceAdapter` 触发 `attachSurface`

#### Scenario: Surface lifecycle events forwarded to SDK
- **WHEN** XComponent 触发 `onLoad` / `onAreaChange` / `onDestroy`
- **THEN** `XComponentSurfaceAdapter` SHALL 分别调用 `attachSurface` / `resizeSurface` / `detachSurface`
- **AND** `generation` 参数 SHALL 随每次 `onLoad` 递增

### Requirement: MpvPlayerAdapter SHALL map SDK events to IPlayer callbacks
`MpvPlayerAdapter` MUST 将 `@vidall/player` 的 `PlayerEvent` 事件流完整映射为 `IPlayer` 接口的回调，确保 `VideoPlayerController` 无需感知后端差异。

#### Scenario: State events mapped to lifecycle callbacks
- **WHEN** `@vidall/player` emit `state` 事件且 `state` 为 `'prepared'` / `'playing'` / `'paused'` / `'completed'` / `'idle'`（stop 后）/ `'error'`
- **THEN** `MpvPlayerAdapter` SHALL 分别触发 `onReady` / `onPlay` / `onPaused` / `onCompleted` / `onStopped` / `onError`

#### Scenario: Position events mapped to time update callback
- **WHEN** `@vidall/player` emit `'position'` 事件（依赖 Player 侧补齐 `time-pos` 观察）
- **THEN** `MpvPlayerAdapter` SHALL 触发 `onTimeUpdate(currentTime)`
- **AND** `currentTime` SHALL 为毫秒单位

#### Scenario: Subtitle text events mapped to subtitle update callback
- **WHEN** `@vidall/player` emit `'subtitleText'` 事件
- **THEN** `MpvPlayerAdapter` SHALL 将文本内容转发到 `onEmbeddedTimedText` 等价路径
- **AND** 最终由 `SubtitleBridgeAdapter` 驱动 `SubtitleRenderer` 绘制

#### Scenario: Buffering events mapped to buffering callback
- **WHEN** `@vidall/player` emit `'buffering'` 事件
- **THEN** `MpvPlayerAdapter` SHALL 触发 `onBuffering(isBuffering)`
- **AND** `isBuffering` SHALL 与 `event.paused` 字段语义一致（`paused=true` 表示缓冲中）

#### Scenario: Seek completion mapped to seek done callback
- **WHEN** `seekRelative()` 或 `seekPercent()` 的 Promise resolve
- **THEN** `MpvPlayerAdapter` SHALL 触发 `onSeekDone()`

#### Scenario: Error events mapped to error callback
- **WHEN** `@vidall/player` emit `'error'` 事件
- **THEN** `MpvPlayerAdapter` SHALL 将 `PlayerError` 转换为 `Error` 并触发 `onError(error)`
- **AND** 当 `error.domain === 'media'` 且错误码表明格式不支持时，SHALL 同时触发 `onUnsupportedFormat()`

### Requirement: MpvPlayerAdapter SHALL use SDK-internal track IDs for track selection
`MpvPlayerAdapter` MUST 使用 `@vidall/player` 的 `PlayerTrack.id` 作为 `getTrackInfos()` 返回的 `trackIndex`，而非 ffprobe 流索引；`selectTrack` 调用 MUST 直接透传该 ID。

#### Scenario: Track enumeration from SDK tracks event
- **WHEN** `@vidall/player` emit `'tracks'` 事件
- **THEN** `MpvPlayerAdapter` SHALL 缓存 `PlayerTrack[]` 快照
- **AND** `getTrackInfos()` SHALL 返回转换后的 `TrackInfo[]`，其中 `trackIndex` 等于 `PlayerTrack.id`

#### Scenario: Track selection passthrough
- **WHEN** 调用 `selectTrack(trackIndex)`
- **THEN** `MpvPlayerAdapter` SHALL 将 `trackIndex` 直接作为 `PlayerTrack.id` 调用 `selectTrack(kind, id)`
- **AND** 当 `trackIndex === -1` 时 SHALL 调用 `selectTrack(kind, null)` 关闭该类型轨道

### Requirement: MPV backend SHALL support external subtitle and audio passthrough
`MpvPlayerAdapter` MUST 支持通过 `MediaSource.externalSubtitles` 和 `MediaSource.externalAudio` 在 `load()` 时一次性传入外挂字幕与音频，与 `addExternalSubtitle()` / `addExternalAudio()` 独立 API 行为一致。

#### Scenario: Load with external subtitles
- **WHEN** `load()` 的 `MediaSource` 包含 `externalSubtitles` 数组
- **THEN** `MpvPlayerAdapter` SHALL 在 `load()` 成功后自动将每个外挂字幕推送到原生层
- **AND** 推送顺序 SHALL 与数组顺序一致

#### Scenario: Load with external audio
- **WHEN** `load()` 的 `MediaSource` 包含 `externalAudio` 数组
- **THEN** `MpvPlayerAdapter` SHALL 在 `load()` 成功后自动将每个外挂音频推送到原生层

### Requirement: MPV backend SHALL default to TV-side subtitle rendering
`MpvPlayerAdapter` MUST 默认不选中任何 mpv 内嵌字幕轨（`sub-visibility=no` 等效行为），仅依赖 `subtitleText` 事件提供文本；PGS/VobSub 图形字幕除外。

#### Scenario: Text subtitle rendered by TV
- **WHEN** 当前字幕轨为 SRT/ASS/SSA/VTT 文本字幕
- **THEN** `MpvPlayerAdapter` SHALL NOT 选中该轨道让 mpv 合成
- **AND** `subtitleText` 事件 SHALL 持续驱动 TV 端 `SubtitleRenderer`

#### Scenario: Graphic subtitle rendered by mpv
- **WHEN** 当前字幕轨为 PGS 或 VobSub 图形字幕
- **THEN** `MpvPlayerAdapter` SHALL 自动选中该轨道让 mpv 内嵌合成
- **AND** `subtitleText` 事件 SHALL 为空字符串
