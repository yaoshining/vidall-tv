# 设置目录选择器

## Purpose

定义文件源设置中的目录选择、协议适配和保存事件契约，保持 WebDAV 与 SMB 的交互及配置兼容。

## Requirements

### Requirement: 设置弹层目录选择浏览器提供统一的目录导航体验
系统 SHALL 为 WebDAV 与 SMB 文件源设置弹层提供同一套目录选择浏览器容器，统一面包屑、返回上级、加载态、空态、错误态与底部确认区的交互语义。

#### Scenario: WebDAV 与 SMB 在设置弹层中共享一致的导航与返回规则
- **WHEN** 用户分别在 WebDAV 与 SMB 的设置弹层目录选择器中进入多级目录后点击返回按钮或遥控器返回键
- **THEN** 系统都先返回上一级目录
- **AND** 仅在根目录时才关闭当前设置弹层或交还上层处理

#### Scenario: 设置弹层目录加载结果以统一方式反馈
- **WHEN** 任一协议适配器返回空目录或目录加载失败
- **THEN** 系统展示统一的空态或错误态反馈
- **AND** 用户仍可执行返回、重试或取消等恢复操作

### Requirement: 统一目录选择状态机保留现有多选与别名语义
系统 SHALL 在共享目录选择状态机中保留当前设置流程的多选目录、自定义别名、取消勾选后恢复别名草稿以及“全部文件夹”选择语义。

#### Scenario: 勾选目录时继续支持自定义别名
- **WHEN** 用户在设置弹层中勾选某个目录
- **THEN** 系统继续进入别名输入流程并保存目录路径与自定义名称
- **AND** 用户取消勾选后再次勾选同一路径时，系统恢复上次暂存的别名内容

#### Scenario: 选择全部文件夹时继续使用 root 标记
- **WHEN** 用户在设置弹层中选择“全部文件夹”
- **THEN** 系统仅使用 `"/"` 作为唯一 root 标记保存当前选择
- **AND** 普通目录勾选入口在“全部文件夹”选中期间保持禁用或等价不可编辑状态

#### Scenario: 保存目录选择时保持当前配置数据兼容
- **WHEN** 用户点击完成保存目录选择
- **THEN** 系统继续按现有规则写入 `file_source_directories`
- **AND** 已有 WebDAV / SMB 设置数据都能在统一后的目录选择器中正确回显

### Requirement: 设置目录选择通过协议适配层隔离 WebDAV 与 SMB 差异
系统 SHALL 通过设置目录选择协议适配层加载目录资源，而不是让共享 UI 容器直接依赖 `WebDAVClient` 或 `SMBClient`。

#### Scenario: WebDAV 设置目录选择通过适配器提供目录项
- **WHEN** WebDAV 设置目录选择器加载某一级目录
- **THEN** WebDAV 适配器把 `WebDAVResource` 转换为统一目录项模型
- **AND** 适配器继续过滤 PROPFIND 返回中的当前目录自引用项

#### Scenario: SMB 设置目录选择通过适配器提供目录项
- **WHEN** SMB 设置目录选择器加载共享列表或某一级目录
- **THEN** SMB 适配器把 `SmbFileInfo` 转换为统一目录项模型
- **AND** 适配器继续保持当前 SMB 设置流程使用的路径格式与根级文案兼容

### Requirement: 统一能力仅覆盖设置弹层的目录选择场景
系统 SHALL 将该统一能力限定在设置弹层目录选择场景，只展示目录级选择操作，不承担文件浏览、播放或图片预览行为。

#### Scenario: 设置目录选择器只展示目录型交互
- **WHEN** 用户在统一后的设置目录选择器中浏览某一级路径
- **THEN** 系统仅展示可进入或可勾选的目录项
- **AND** 不在该能力内提供文件打开、视频播放或图片预览动作

### Requirement: settings-directory-selector Capability Update

The capability `settings-directory-selector` SHALL document the DirectorySelectorContainer naming, removal of builder classes, and standardized DirectoryProvider adapter pattern.

#### Scenario: Component naming reflects responsibility
- **WHEN** settings-directory-selector spec is read
- **THEN** it documents DirectorySelectorContainer (not DirectorySelectorAdapter) as the UI component

#### Scenario: Route parameter format documented
- **WHEN** developer integrates a new protocol
- **THEN** spec shows the route parameter format: protocol/sourceId/basePath

#### Scenario: Provider factory pattern documented
- **WHEN** new protocol needs integration
- **THEN** spec explains how route handler instantiates provider based on protocol parameter

### Requirement: 目录保存成功后发出异步事件
系统 SHALL 在文件源目录保存事务成功完成后，发出携带文件源标识和新增规范化目录路径列表的异步事件，供下游自动刮削能力观测并触发定向任务。

#### Scenario: 保存含新增目录时发出事件
- **WHEN** 用户在文件源设置中保存目录选择且本次存在新增的规范化目录路径
- **THEN** 系统在保存事务完成后发出事件，包含 sourceId、fileSourceType 和新增目录规范化路径列表

#### Scenario: 无新增目录时不发出事件
- **WHEN** 用户保存目录选择但所有路径均在既有配置中已存在
- **THEN** 系统不发出自动刮削触发事件

#### Scenario: 事件在事务完成后异步发出
- **WHEN** 目录保存事务提交成功
- **THEN** 事件在事务提交后立即异步发出，不阻塞保存 UI 的响应；事件发出 MUST NOT 依赖孤儿元数据清理或文件源缓存刷新完成，后续清理/刷新失败不吞掉已发出的保存结果

#### Scenario: 事件仅包含路径差集
- **WHEN** 保存前已有 `/movie` 且用户新增 `/tv`
- **THEN** 事件中新增目录路径列表仅包含 `/tv`，不包含 `/movie`

#### Scenario: 事件不包含别名变化
- **WHEN** 用户仅修改已有目录的别名而未增删目录路径
- **THEN** 事件中新增目录路径列表为空，系统不发出自动刮削触发事件
