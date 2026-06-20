## MODIFIED Requirements

### Requirement: AVPlayer codec fallback SHALL 保留并恢复当前续播位置
当 AVPlayer 因 PREPARED 阶段 codec 检测或 error 回调判定当前媒体不受支持并触发 fallback 时，系统 MUST 在释放旧播放器实例前捕获当前可用播放位置与恢复决策，并将该恢复决策透传给接手的后端；该 fallback 编排 MUST 由统一的 playback backend service 执行，但恢复位置、自动播放意图与当前用户可见行为保持兼容。

#### Scenario: PREPARED 阶段主动 fallback 时保留续播位置
- **WHEN** AVPlayer 在 PREPARED 状态检测到所有音频轨道均为不支持 codec
- **AND** 系统准备切换到 fallback 后端
- **THEN** 系统在释放 AVPlayer 前保存当前可用播放位置与当前恢复决策
- **AND** fallback 后端 ready 后按该恢复决策恢复位置与播放语义

#### Scenario: error 回调 fallback 时保留续播位置
- **WHEN** AVPlayer 因格式不支持错误触发 `_onUnsupportedFormatCb`
- **AND** 播放会话在切换前已有已知播放位置
- **THEN** 系统将该位置与自动播放决策透传到 fallback 后端
- **AND** fallback 完成后继续按原决策恢复播放

#### Scenario: fallback 编排由 backend service 统一执行
- **WHEN** 当前播放会话进入 unsupported format fallback 路径
- **THEN** 系统 SHALL 通过统一的 playback backend service 执行 backend 切换、旧实例释放与新实例恢复
- **AND** `VideoPlayerController` 对 UI 暴露的 fallback 结果保持不变
