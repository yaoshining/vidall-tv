## ADDED Requirements

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
