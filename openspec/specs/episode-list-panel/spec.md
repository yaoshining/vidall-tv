# Episode List Panel

## Purpose

定义播放器设置面板中的“选集”区块当前实现行为，包括渲染结构、分页规则与遥控器交互方式。

## Requirements

### Requirement: EpisodeListPanel 以当前实现渲染媒体库剧集卡片

系统 SHALL 提供 `EpisodeListPanel` 组件，并在 `PlayerSettingsDialog` 中接收 `MediaLibraryContext` 与 `onSelect(item)` 回调。

`EpisodeListPanel` SHALL：
- 显示区块标题“选集”
- 使用 `List` + `ForEach` 渲染当前页条目
- 为每个条目显示剧集缩略图；当 `thumbnailUrl` 缺失时回退为 `app.media.empty_folder`
- 为每个条目显示 `第N集` 文本，其中 `N` 优先取 `episodeNumber`，否则取 `index + 1`
- 对当前播放项使用当前态背景/字体样式，并显示波形图标
- 在条目点击时调用 `onSelect(item)`

#### Scenario: 当前页条目显示为上图下字卡片
- **WHEN** `EpisodeListPanel` 渲染一组当前页剧集
- **THEN** 每个条目显示缩略图区域和 `第N集` 文本

#### Scenario: 当前播放项显示波形图标
- **WHEN** 某个条目的 `item.index === context.currentIndex`
- **THEN** 该条目显示当前播放波形图标并使用当前态样式

#### Scenario: 点击条目触发 onSelect
- **WHEN** 用户点击某个剧集卡片
- **THEN** `onSelect` 以该 `PlaybackContextItem` 为参数被调用

---

### Requirement: EpisodeListPanel 使用固定两段式分页规则

`EpisodeListPanel` SHALL 使用当前实现中的固定分页规则，而不是滚动式每页 6 集分页。

分页规则 SHALL：
- 当总集数 `<= 6` 时，仅生成一组 `1-6`（按实际终点裁剪）
- 当总集数 `> 6` 时，仅生成两组：`1-6` 与 `7-最后一集`
- 在组件出现时，根据 `context.currentIndex` 自动计算 `currentPage` 与页内聚焦索引

#### Scenario: 15 集时第二组为 7-15
- **WHEN** 总集数为 `15`
- **THEN** 分页范围为 `1-6` 与 `7-15`
- **AND** 第二组返回第 7 集到第 15 集条目

#### Scenario: 总集数不超过 6 时不显示第二组
- **WHEN** 总集数为 `6`
- **THEN** 仅生成一组分页标签 `1-6`

---

### Requirement: EpisodeListPanel 支持当前已实现的遥控器与分页条交互

`EpisodeListPanel` SHALL 支持当前代码中已实现的横向卡片导航与分页条焦点切换。

#### Scenario: 在页尾按右键切到下一组
- **WHEN** 焦点位于当前页最后一个卡片，且用户按下右方向键
- **THEN** 组件切换到下一页

#### Scenario: 在页首按左键切到上一组
- **WHEN** 焦点位于当前页第一个卡片，且用户按下左方向键
- **THEN** 组件切换到上一页

#### Scenario: 从卡片列表向下进入分页条
- **WHEN** 焦点位于卡片列表，且用户按下下方向键
- **THEN** 焦点切换到分页范围条

#### Scenario: 分页条通过点击或确认键切页
- **WHEN** 用户点击某个分页标签，或在分页标签上按下确认键
- **THEN** 组件切换到对应页

#### Scenario: 分页条按上键返回卡片区
- **WHEN** 焦点位于分页条，且用户按下上方向键
- **THEN** 组件退出分页条焦点态
