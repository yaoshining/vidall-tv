# history-playback-track-preset Specification

## Purpose
TBD - created by syncing change fix-history-audio-tracks. Update Purpose after archive.

## Requirements
### Requirement: 播放历史入口传递预设音轨
系统 SHALL 在 `PlayHistoryPage` 跳转播放器前，查询数据库中该视频的 `audioTracksJson`，若存在且非空，将其转换为 `PresetAudioTrack[]` 并填入 `PlayerPageParam.presetAudioTracks`。

#### Scenario: 数据库存在 audioTracksJson 时填入预设音轨
- **WHEN** 用户从播放历史或首页「继续观看」入口打开视频
- **AND** 数据库中该视频的 `audioTracksJson` 存在且长度大于 0
- **THEN** 系统将 `audioTracksJson` 解析为 `FfprobeTrack[]`，通过 `FfprobeUtil.toPresetAudioTracks()` 转换后填入 `PlayerPageParam.presetAudioTracks`

#### Scenario: 数据库无 audioTracksJson 时 presetAudioTracks 为空
- **WHEN** 用户从播放历史入口打开视频
- **AND** 数据库中该视频的 `audioTracksJson` 为 null 或 undefined
- **THEN** `PlayerPageParam.presetAudioTracks` 为 undefined，播放器使用 AVPlayer fallback 逻辑

#### Scenario: 数据库读取失败时不阻断播放
- **WHEN** 用户从播放历史入口打开视频
- **AND** 数据库查询 `getVideoByPath()` 抛出异常
- **THEN** 系统捕获异常并静默忽略，继续跳转播放器，`PlayerPageParam.presetAudioTracks` 为 undefined

### Requirement: 播放历史入口传递预设字幕轨
系统 SHALL 在 `PlayHistoryPage` 跳转播放器前，查询数据库中该视频的 `subtitleTracksJson`，若存在且非空，将其转换为 `PresetSubtitleTrack[]` 并填入 `PlayerPageParam.presetSubtitleTracks`。

#### Scenario: 数据库存在 subtitleTracksJson 时填入预设字幕轨
- **WHEN** 用户从播放历史入口打开视频
- **AND** 数据库中该视频的 `subtitleTracksJson` 存在且长度大于 0
- **THEN** 系统将 `subtitleTracksJson` 解析为 `FfprobeTrack[]`，通过 `FfprobeUtil.toPresetSubtitleTracks()` 转换后填入 `PlayerPageParam.presetSubtitleTracks`

#### Scenario: 数据库无 subtitleTracksJson 时 presetSubtitleTracks 为空
- **WHEN** 用户从播放历史入口打开视频
- **AND** 数据库中该视频的 `subtitleTracksJson` 为 null 或 undefined
- **THEN** `PlayerPageParam.presetSubtitleTracks` 为 undefined

### Requirement: 播放历史入口传递时长提示
系统 SHALL 在 `PlayHistoryPage` 跳转播放器前，若数据库中该视频的 `durationMs` 大于 0，则将其填入 `PlayerPageParam.durationHintMs`。

#### Scenario: 数据库存在 durationMs 时填入时长提示
- **WHEN** 用户从播放历史入口打开视频
- **AND** 数据库中该视频的 `durationMs` 存在且大于 0
- **THEN** `PlayerPageParam.durationHintMs` 被赋值为该 `durationMs`

#### Scenario: 各入口音轨列表保持一致
- **WHEN** 同一视频分别从系列详情页和播放历史入口打开
- **AND** 该视频数据库中存在 `audioTracksJson`
- **THEN** 两个入口传入播放器的 `presetAudioTracks` 内容完全一致
