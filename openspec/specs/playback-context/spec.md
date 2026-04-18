# Playback Context

## Purpose

定义播放器的上下文抽象契约，使播放器能够在不同内容来源下获得统一的导航能力，并为剧集列表、上下集切换、已看状态展示以及未来第三方媒体源扩展提供稳定边界。

## Requirements

### Requirement: 播放器支持统一的 PlaybackContext 抽象

播放器 SHALL 接受一个可选的 `PlaybackContext` 作为播放会话上下文。该抽象负责向播放器提供当前内容所在集合、可导航目标以及上下文类型信息，而不是让播放器直接耦合具体页面或数据源。

#### Scenario: 从媒体库进入播放器时携带上下文
- **WHEN** 用户从剧集详情页或季详情页进入播放器
- **THEN** 播放器收到一个 `MediaLibraryContext`
- **AND** 播放器可基于该上下文识别当前剧集、所属季和可切换的剧集列表

#### Scenario: 从无上下文入口进入播放器时保持单文件播放
- **WHEN** 调用方未传入 `PlaybackContext`
- **THEN** 播放器仍可执行基础播放能力
- **AND** 所有依赖上下文的导航或列表能力默认关闭

---

### Requirement: PlaybackContext 类型体系清晰可扩展

系统 SHALL 采用 `PlaybackContext` 抽象基类，并定义以下上下文类型边界：

- `MediaLibraryContext`：用于媒体库入口，负责提供剧集列表、季号、当前集和已看标记等剧集导航信息
- `FileExplorerContext`：用于文件浏览器入口，负责按文件夹/文件组织播放上下文
- `JellyfinContext`：当前阶段不实现，但 SHALL 作为未来扩展预留类型

#### Scenario: 媒体库上下文提供剧集导航信息
- **WHEN** 当前上下文为 `MediaLibraryContext`
- **THEN** 播放器可获取按季/集组织的内容集合
- **AND** UI 可读取当前集、已看状态和跳转目标

#### Scenario: 文件浏览器上下文不要求提供剧集元数据
- **WHEN** 当前上下文为 `FileExplorerContext`
- **THEN** 系统仅要求提供文件来源下的导航语义
- **AND** 不强制要求提供剧集季集元数据

---

### Requirement: 调用方在进入播放器前预创建上下文

播放上下文 SHALL 由调用方在进入播放器前预创建并注入，当前采用“选项 A：调用方预创建”方案。播放器不负责在进入后再反向查询页面状态或远程组装上下文。

#### Scenario: SeasonDetailPage 在跳转前构建上下文
- **WHEN** 用户在 `SeasonDetailPage` 或 `SeriesDetailPage` 选择某一集进入播放器
- **THEN** 页面在跳转前完成 `PlaybackContext` 构建
- **AND** 播放器打开后可立即使用上下文渲染相关 UI，而无需二次等待

---

### Requirement: VideoPlayerController 以可选字段承载上下文

`VideoPlayerController` SHALL 新增可选字段 `playbackContext?: PlaybackContext`。当该字段存在时，播放器使用它驱动上下文相关能力；当该字段不存在时，播放器保持兼容当前的单文件播放模式。

#### Scenario: 控制器收到上下文后启用导航能力
- **WHEN** `VideoPlayerController` 初始化时包含 `playbackContext`
- **THEN** 播放器可启用上下集判断、剧集列表读取等能力

#### Scenario: 控制器未收到上下文时保持兼容
- **WHEN** `VideoPlayerController` 初始化时未包含 `playbackContext`
- **THEN** 播放器不得因缺少上下文而报错
- **AND** 原有播放流程保持可用

---

### Requirement: PlayerSettingsDialog 按 contextType 决定是否展示剧集列表面板

`PlayerSettingsDialog` SHALL 根据 `contextType` 决定是否展示剧集列表面板。当前阶段，只有 `MediaLibraryContext` 需要展示剧集列表面板；`FileExplorerContext` 不展示该面板，但保留未来扩展空间。

#### Scenario: 媒体库上下文显示剧集列表
- **WHEN** 当前 `contextType` 为 `MediaLibraryContext`
- **THEN** 设置面板显示剧集列表区域
- **AND** 列表中可展示当前集高亮、剧集顺序和已看状态

#### Scenario: 文件浏览器上下文隐藏剧集列表
- **WHEN** 当前 `contextType` 为 `FileExplorerContext`
- **THEN** 设置面板不显示剧集列表区域
- **AND** 播放器仅展示适用于文件播放的通用设置
