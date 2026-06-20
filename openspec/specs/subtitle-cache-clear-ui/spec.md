## ADDED Requirements

### Requirement: 设置页 SHALL 在字幕分组提供清理字幕缓存入口

设置页"字幕"分组末尾 SHALL 展示"清理字幕缓存"条目，支持遥控器焦点聚焦与 OK 键触发。

#### Scenario: 遥控器可聚焦并触发清理入口
- **WHEN** 用户通过遥控器导航到设置页"字幕"分组
- **THEN** "清理字幕缓存"条目可获得焦点
- **AND** 按 OK 键触发确认流程

### Requirement: 系统 SHALL 在执行清理前展示确认弹窗

点击"清理字幕缓存"后，系统 SHALL 展示 AlertDialog 请求用户确认，防止误操作。

#### Scenario: 用户点击清理后弹出确认弹窗
- **WHEN** 用户触发"清理字幕缓存"条目
- **THEN** 系统展示包含"确认清理"和"取消"选项的 AlertDialog
- **AND** 弹窗文案说明将清除所有已下载字幕缓存

#### Scenario: 用户取消确认时不执行清理
- **WHEN** 用户在确认弹窗中选择"取消"
- **THEN** 弹窗关闭
- **AND** 字幕缓存不受任何影响

### Requirement: 系统 SHALL 在清理完成后通过 Toast 反馈结果

确认后，系统 SHALL 调用 `SubtitleCacheManager.clearAllSubtitleCaches(filesDir)` 并在 3 秒内通过 Toast 告知用户清理结果。

#### Scenario: 存在缓存时清理成功
- **WHEN** 用户确认清理
- **AND** `{filesDir}/subtitles/` 目录下存在字幕缓存文件
- **THEN** 系统完成清理
- **AND** 3 秒内展示 Toast"字幕缓存已清理"
- **AND** `{filesDir}/subtitles/` 目录下缓存占用降为 0

#### Scenario: 无缓存时给出明确提示
- **WHEN** 用户确认清理
- **AND** `{filesDir}/subtitles/` 目录不存在或为空
- **THEN** 系统展示 Toast"暂无字幕缓存"
- **AND** 不报错、不卡死

#### Scenario: 清理失败时展示错误提示
- **WHEN** 用户确认清理
- **AND** 清理过程中发生异常
- **THEN** 系统展示 Toast"清理失败，请重试"
- **AND** 不崩溃
