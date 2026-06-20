## MODIFIED Requirements

### Requirement: 播放器 SHALL 在重新进入同一媒体时恢复上次进度
系统 MUST 在用户重新进入同一视频时读取该媒体对应的已保存进度；当进度存在且未达到完播阈值时，系统 MUST 在播放器准备完成后恢复到该位置，而不是从 0 开始播放；当进度已达到完播阈值时，系统 MUST 清除续播状态并从头开始播放。该续播决策 MUST 由统一的 playback progress service 计算，但对现有页面参数契约、续播弹窗条件与 prepared 后的用户可见行为保持兼容。

#### Scenario: 重新进入视频时恢复已保存进度
- **WHEN** 用户重新进入同一视频
- **AND** 系统读到该视频存在有效续播进度
- **AND** 该进度未达到完播阈值
- **THEN** 系统在播放器准备完成后 seek 到该进度
- **AND** 系统按该播放会话的恢复决策继续播放

#### Scenario: 已接近完播时不恢复旧进度
- **WHEN** 用户重新进入同一视频
- **AND** 系统读到的续播进度已达到完播阈值
- **THEN** 系统清除该媒体的续播状态
- **AND** 系统从头开始播放

#### Scenario: 续播决策由独立 progress service 统一计算
- **WHEN** 页面层需要基于 `play_progress` 或 `media_progress` 解析续播行为
- **THEN** 系统 SHALL 通过统一的 playback progress service 决定是直接播放、直接 seek、弹出续播确认，还是清理 near-end 进度
- **AND** 该决策结果对用户表现与现有播放器流程保持一致
