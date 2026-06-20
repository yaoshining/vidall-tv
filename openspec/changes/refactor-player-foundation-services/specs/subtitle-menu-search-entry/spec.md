## MODIFIED Requirements

### Requirement: 系统 SHALL 在字幕搜索抽屉下载成功后记录最后使用的字幕
用户在 `SubtitleSelectorDrawerDialog` 中选择并下载一条字幕，下载成功且挂载到播放器后，系统 SHALL 调用统一的 subtitle acquisition service 协调下载结果落盘、最近使用字幕记录更新与当前播放会话回灌；该流程对用户仍表现为下载完成后自动追加并切换字幕。

#### Scenario: 下载成功后通过统一获取流程记录最后使用字幕
- **WHEN** 用户在字幕搜索结果中选中一条字幕并触发下载
- **AND** 下载成功且文件已写入本地
- **AND** `addExternalSubtitle` 挂载成功
- **THEN** 系统通过统一的 subtitle acquisition service 更新对应 `metadata.json` 的 `lastUsed`
- **AND** 当前播放会话自动追加并切换到该字幕

#### Scenario: 最近使用字幕记录失败不影响当前字幕显示
- **WHEN** 统一字幕获取流程在更新最近使用字幕记录时发生异常
- **THEN** 异常不会改变当前下载字幕已经成功挂载的结果
- **AND** 用户仍看到与当前版本一致的字幕显示行为
