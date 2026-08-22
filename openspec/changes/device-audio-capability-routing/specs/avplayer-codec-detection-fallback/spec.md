## MODIFIED Requirements

### Requirement: AVPlayer 在 PREPARED 状态检测不支持的音频 codec 并主动触发 fallback

系统 SHALL 在创建或 prepare AVPlayer 之前，依据设备真实解码能力判定当前媒体是否存在兼容音轨；当不存在任何兼容音轨时，系统 SHALL 直接选择 MPV 后端，而不先 prepare AVPlayer。全局 codec 黑名单不再作为最终兼容性真值；仅在能力查询异常时作为临时兜底。

#### Scenario: 所有音频轨道均为 eac3 时触发 fallback
- **WHEN** 设备不支持媒体中的全部音频轨道（如全部为 eac3）
- **THEN** 系统 SHALL 在创建或 prepare AVPlayer 前选择 MPV
- **AND** 不进入 AVPlayer PREPARED 阶段的 fallback 判定

#### Scenario: 混合音轨场景（eac3 + AAC）不触发 fallback
- **WHEN** 音频轨道中至少有一条设备能力兼容的格式（如 AAC）
- **THEN** 系统 SHALL 选择 AVPlayer 并正常进入 ready，不触发 fallback

#### Scenario: 无音频轨道时不触发 fallback
- **WHEN** 文件中不存在任何音频轨道（type=0）
- **THEN** 系统 SHALL 选择 AVPlayer 并正常进入 ready，不触发 fallback

#### Scenario: API 19 行为不受影响
- **WHEN** 设备运行在 API 19 环境
- **AND** 不支持的音频文件在 `prepare()` 阶段触发 error 事件（5400106/5400103）
- **THEN** 原有 error handler 调用 `_onUnsupportedFormatCb` 触发动态降级
- **AND** 新增的启动前能力判定不参与此 error 路径

#### Scenario: 无兼容音轨时不进入 AVPlayer prepare
- **WHEN** 设备不支持媒体中的全部音频轨道
- **THEN** 系统 SHALL 在创建或 prepare AVPlayer 前选择 MPV
- **AND** 不触发 AVPlayer PREPARED 阶段的 fallback 判定

#### Scenario: 存在兼容音轨时进入 AVPlayer 并预选兼容轨
- **WHEN** 媒体中存在至少一条设备能力兼容的音轨
- **THEN** 系统 SHALL 选择 AVPlayer
- **AND** 系统 SHALL 预选兼容性最高且符合语言偏好的音轨

#### Scenario: 能力查询异常时黑名单仅作临时兜底
- **WHEN** 设备能力查询异常或能力未知
- **THEN** 系统 SHALL 保守选择 MPV
- **AND** 迁移期 SHALL 允许使用全局 codec 黑名单作为查询异常时的临时兜底，而非兼容性真值

### Requirement: AVPlayer codec fallback SHALL 保留并恢复当前续播位置

当 AVPlayer 因不支持当前媒体而触发 fallback 时，系统 MUST 在释放旧播放器实例前捕获当前可用播放位置与恢复决策，并将该恢复决策透传给接手的后端；恢复决策 MUST 同时包含恢复位置与是否自动播放，且当 fallback 发生在 seek 已完成、自动起播已决策但播放态回调尚未到达的窗口内时，系统 MUST 保留该"待自动播放"意图；新的后端 ready 后 MUST 按该决策恢复到对应位置并继续执行自动播放或暂停语义。该 fallback 编排 MUST 由统一的 playback backend service 执行。

#### Scenario: PREPARED 阶段主动 fallback 时保留续播位置
- **WHEN** AVPlayer 因不支持当前媒体触发 fallback
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

#### Scenario: seek 完成后的自动起播窗口内 fallback 仍保留自动播放意图
- **WHEN** 用户切换剧集后系统已对新媒体执行续播 seek
- **AND** seek 已完成且当前播放会话已决策继续自动播放
- **AND** AVPlayer 在播放态回调到达前触发 unsupported format fallback
- **THEN** 系统保存的恢复决策仍标记该会话需要自动播放
- **AND** fallback 后端 ready 后在恢复位置后自动开始播放

### Requirement: AVPlayer 明确播放失败时动态降级并记录纠偏

当 AVPlayer 对某音轨明确报告格式不支持（如错误码 5400106 / 5400103 或 unsupported format 事件）时，系统 MUST 动态降级到 MPV，并记录该 codec 的设备/固件纠偏结果以供后续会话复用。

#### Scenario: AVPlayer 明确失败触发动态降级
- **WHEN** AVPlayer 报告当前媒体格式不支持（5400106 / 5400103）
- **THEN** 系统 SHALL 触发 MPV fallback
- **AND** 记录该 codec 的纠偏结果（`forceUnsupported`）

#### Scenario: 纠偏结果在后续会话优先于系统声明
- **WHEN** 后续播放会话读取到针对当前设备与 codec 的纠偏结果
- **THEN** 系统 SHALL 优先采用纠偏结果判该 codec 不兼容
- **AND** 不再仅依赖系统声明的解码能力
