# subtitle-menu-search-entry

## Purpose

定义播放中快速切轨弹出菜单与字幕搜索抽屉之间的入口衔接能力，包含字幕按钮可见性策略、双层菜单架构以及搜索面板内的焦点与返回键行为。

## Requirements

### Requirement: 快速切轨菜单 SHALL 提供入口跳转至全功能字幕搜索抽屉

播放中快速切轨弹出菜单（`SubtitleMenu`）的底部 SHALL 始终显示"🔍 更多字幕配置"条目。用户选中该条目后，系统 SHALL 关闭弹出菜单并打开 `SubtitleSelectorDrawerDialog`。

#### Scenario: 用户通过快速切轨菜单进入字幕搜索抽屉
- **WHEN** 用户打开快速切轨弹出菜单
- **AND** 用户选中"更多字幕配置"条目
- **THEN** 快速切轨弹出菜单关闭
- **AND** `SubtitleSelectorDrawerDialog` 打开
- **AND** 视频继续播放不中断

#### Scenario: 无可用字幕轨道时"更多字幕配置"依然可访问
- **WHEN** 当前视频没有任何字幕轨道（`allSubtitleTracks.length === 0`）
- **AND** 用户打开快速切轨弹出菜单
- **THEN** "更多字幕配置"条目依然显示
- **AND** 选中后正常打开 `SubtitleSelectorDrawerDialog`

### Requirement: 字幕按钮 SHALL 在播放控制条中始终可见

播放控制条顶栏中的字幕按钮 SHALL 不依赖已加载字幕轨道数量而始终显示。无字幕轨道时按钮标签显示"字幕"（灰色样式），有已激活轨道时显示当前轨道名称（白色样式）。

#### Scenario: 无字幕轨道时字幕按钮仍可见
- **WHEN** 当前视频不含任何字幕轨道
- **AND** 用户唤起播放控制条
- **THEN** 字幕按钮显示在顶栏
- **AND** 按钮标签文本为"字幕"
- **AND** 点击后打开快速切轨菜单

#### Scenario: 有已激活字幕轨道时按钮显示当前轨道名
- **WHEN** 当前已激活某字幕轨道
- **AND** 用户唤起播放控制条
- **THEN** 字幕按钮标签文本为当前轨道的 `displayName`

### Requirement: 系统 SHALL 在字幕搜索抽屉下载成功后记录最后使用的字幕

用户在 `SubtitleSelectorDrawerDialog` 中选择并下载一条字幕，下载成功且挂载到播放器后，系统 SHALL 调用 `SubtitleCacheManager.setLastUsedSubtitle()` 更新该视频目录下 `metadata.json` 的 `lastUsed` 字段及对应条目的 `lastAccessedAt`。

#### Scenario: 下载成功后 setLastUsedSubtitle 被调用
- **WHEN** 用户在字幕搜索结果中选中一条字幕并触发下载
- **AND** 下载成功且文件已写入本地
- **AND** `addExternalSubtitle` 挂载成功
- **THEN** `SubtitleCacheManager.setLastUsedSubtitle(filesDir, sourceType, sourceId, videoPath, fileName)` 被调用
- **AND** 对应 `metadata.json` 的 `lastUsed` 更新为本次下载的文件名

#### Scenario: setLastUsedSubtitle 调用失败不影响播放和 UI
- **WHEN** `setLastUsedSubtitle` 内部发生异常（如文件系统错误）
- **THEN** 异常被静默捕获，不向上抛出
- **AND** 字幕仍然正常显示
- **AND** UI 不展示错误提示

### Requirement: 字幕搜索结果面板 SHALL 在打开时将焦点置于第一条结果

`SubtitleSelectorDrawerDialog` 切换至搜索结果视图（`showSearchResults === true`，搜索完成且有结果）时，第一条搜索结果 SHALL 获得默认焦点，以便遥控器上下键立即可用于导航。

#### Scenario: 搜索结果展示后遥控器可立即导航
- **WHEN** 字幕搜索完成并返回至少 1 条结果
- **THEN** 结果列表第一条获得焦点
- **AND** 遥控器下键可移动到第二条结果

#### Scenario: 无搜索结果时焦点规则不适用
- **WHEN** 字幕搜索完成但返回 0 条结果
- **THEN** 显示"未找到字幕"占位文本
- **AND** 不尝试将焦点设置到结果列表

### Requirement: 遥控器返回键 SHALL 在搜索结果视图中退回字幕轨道列表视图

当 `SubtitleSelectorDrawerDialog` 处于搜索结果视图（`showSearchResults === true`）时，遥控器物理返回键 SHALL 将视图切回字幕轨道列表（`showSearchResults = false`），而不关闭整个抽屉面板。

#### Scenario: 搜索结果视图按返回键退回轨道列表
- **WHEN** 用户在 `SubtitleSelectorDrawerDialog` 的搜索结果视图中
- **AND** 按下遥控器物理返回键
- **THEN** 视图切回字幕轨道列表
- **AND** 抽屉面板保持打开

#### Scenario: 轨道列表视图按返回键关闭整个抽屉
- **WHEN** 用户在 `SubtitleSelectorDrawerDialog` 的轨道列表视图（`showSearchResults === false`）中
- **AND** 按下遥控器物理返回键
- **THEN** 抽屉面板关闭（由 `onWillDismiss` 处理，现有行为不变）