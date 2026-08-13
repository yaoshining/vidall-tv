# mpv-player-backend Specification

## Purpose

Define the behavior contract for integrating the mpv-based `@vidall/player` backend into VidAll_TV as a selectable fallback player kernel, including the `MpvPlayerAdapter` implementation, XComponent surface binding, and event mapping to the existing `IPlayer` interface.

## Requirements

### Requirement: MPV 后端必须注册为回退播放后端
系统 MUST 注册 `'mpv'` 为 AVPlayer 的唯一回退播放后端，同时保留 MPV adapter 的既有播放能力。

#### Scenario: 后端枚举包含 MPV
- **WHEN** 系统初始化播放后端选择逻辑
- **THEN** `'mpv'` SHALL 作为有效后端值存在
- **AND** 活跃后端集合 SHALL 仅包含 AVPlayer 与 MPV

#### Scenario: AVPlayer 回退到 MPV
- **WHEN** AVPlayer 无法播放当前媒体
- **THEN** 系统 SHALL 创建 MPV adapter 接手播放
- **AND** 用户无需选择回退内核

#### Scenario: 创建 MPV adapter
- **WHEN** 后端决策结果为 `'mpv'`
- **THEN** playback backend service SHALL 创建 MPV adapter 实例
- **AND** 该实例 SHALL 实现统一播放器接口的全部方法与回调注册

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
- **AND** `generation` 递增由 `XComponentSurfaceAdapter` 内部自动管理，调用方无需手动维护

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

#### Scenario: Seek failure still triggers seek done
- **WHEN** `seekRelative()` 或 `seekPercent()` 的 Promise reject（命令入队失败或 mpv 内部异常）
- **THEN** `MpvPlayerAdapter` SHALL 仍然触发 `onSeekDone()` 以避免 UI 卡在 seeking 状态
- **AND** SHALL 在日志中记录 seek 失败原因

#### Scenario: Error events mapped to error callback
- **WHEN** `@vidall/player` emit `'error'` 事件
- **THEN** `MpvPlayerAdapter` SHALL 将 `PlayerError` 转换为 `Error` 并触发 `onError(error)`
- **AND** 当 `error.domain === 'media'` 且错误码指向格式不支持或解码失败（通过 `isUnsupportedFormatCode` 判断）时，SHALL 同时触发 `onUnsupportedFormat()`

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
- **NOTE** 当前实现中 `VideoData` 不携带外挂资源字段，此功能预留待后续版本启用

#### Scenario: Load with external audio
- **WHEN** `load()` 的 `MediaSource` 包含 `externalAudio` 数组
- **THEN** `MpvPlayerAdapter` SHALL 在 `load()` 成功后自动将每个外挂音频推送到原生层
- **NOTE** 当前实现中 `VideoData` 不携带外挂资源字段，此功能预留待后续版本启用

#### Scenario: External subtitle/audio load failure
- **WHEN** `load()` 的 `MediaSource` 包含 `externalSubtitles` 或 `externalAudio`，但推送失败
- **THEN** `MpvPlayerAdapter` SHALL 记录失败日志并继续播放
- **AND** SHALL NOT 因外挂资源推送失败而触发 `onError`

### Requirement: MPV backend SHALL default to TV-side subtitle rendering
`MpvPlayerAdapter` MUST 默认不选中任何 mpv 内嵌字幕轨（`sub-visibility=no` 等效行为），仅依赖 `subtitleText` 事件提供文本；PGS/VobSub 图形字幕除外。

#### Scenario: Text subtitle rendered by TV (default, no user selection)
- **WHEN** 当前字幕轨为 SRT/ASS/SSA/VTT 文本字幕，且未通过 `selectTrack` 选中
- **THEN** `MpvPlayerAdapter` SHALL 保持 `sub-visibility=no` 禁止 mpv 内嵌合成
- **AND** `subtitleText` 事件 SHALL 为空字符串（未选中时不输出文本）
- **AND** TV 端 `SubtitleRenderer` SHALL 不绘制（无字幕选中）

#### Scenario: Graphic subtitle rendered by mpv
- **WHEN** 用户通过 `selectTrack` 选中 PGS 或 VobSub 图形字幕轨
- **THEN** `MpvPlayerAdapter` SHALL 设置 `sub-visibility=yes` 让 mpv 内嵌合成到视频帧
- **AND** `subtitleText` 事件 SHALL 为空字符串（图形字幕无文本输出）
- **AND** TV 端 `SubtitleRenderer` SHALL 不绘制该轨道（由 mpv 内嵌渲染）

#### Scenario: Text subtitle rendered by TV when selected
- **WHEN** 用户通过 `selectTrack` 选中 SRT/ASS/SSA/VTT 文本字幕轨
- **THEN** `MpvPlayerAdapter` SHALL 设置 `sub-visibility=no` 禁止 mpv 内嵌渲染
- **AND** `subtitleText` 事件 SHALL 持续提供文本内容
- **AND** TV 端 `SubtitleRenderer` SHALL 负责绘制
