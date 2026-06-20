# unit-tests-videodata

## Purpose

验证 `VideoData`、`PresetAudioTrack`、`SubtitleTrack` 数据模型的字段完整性与默认值行为，确保核心字段可正确设置与读取。

## Requirements

### Requirement: VideoData 数据模型字段完整性
`VideoData` 对象 SHALL 支持设置和读取 url、title、duration、audioTracks、subtitleTracks 等核心字段，且字段默认值符合预期（空数组 / undefined）。

#### Scenario: 默认构造后轨道列表为空数组
- **WHEN** 创建 `VideoData` 实例且未设置音频/字幕轨道
- **THEN** `audioTracks` 和 `subtitleTracks` 为空数组或 undefined（不崩溃）

### Requirement: PresetAudioTrack displayName 字段
`PresetAudioTrack.displayName` SHALL 为非空字符串，用于在 UI 中展示音轨名称。

#### Scenario: 构造带 displayName 的音频轨
- **WHEN** 创建 `PresetAudioTrack` 并赋值 `displayName: 'English DTS'`
- **THEN** 读取 `displayName` 返回 `'English DTS'`

### Requirement: SubtitleTrack displayName 字段
`SubtitleTrack.displayName` SHALL 为非空字符串，用于在 UI 中展示字幕轨名称。

#### Scenario: 构造带 displayName 的字幕轨
- **WHEN** 创建 `SubtitleTrack` 并赋值 `displayName: '简体中文'`
- **THEN** 读取 `displayName` 返回 `'简体中文'`
