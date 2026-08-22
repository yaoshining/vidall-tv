## MODIFIED Requirements

### Requirement: Audio routing decisions SHALL be centralized
音频 codec 探测、声道能力判断、初始 backend route 与 fallback 建议，系统 MUST 由统一的 audio track routing service 计算。

#### Scenario: Determine backend route from audio probe
- **WHEN** 新播放会话提供 ffprobe 结果、预置音轨提示或其他音频探测输入
- **THEN** audio track routing service SHALL 返回推荐 backend、fallback 建议与目标声道策略

### Requirement: Backend route SHALL be driven by device decoding capability
系统 MUST 在创建或 prepare AVPlayer 之前，依据当前设备的真实音频解码能力（codec 支持 + 最大声道数）选择后端；不得仅依赖全局写死的 codec 黑名单作为兼容性真值。

#### Scenario: 存在兼容音轨时选择 AVPlayer 并预选最佳轨
- **WHEN** 整组音轨中存在至少一条设备能力兼容（codec 支持且声道数不超设备上限）的音轨
- **THEN** audio track routing service SHALL 返回 `preferredBackend='avplayer'`
- **AND** 返回预选的兼容性最高且符合语言偏好的音轨索引

#### Scenario: 无兼容音轨时直接选择 MPV
- **WHEN** 设备不支持整组音轨中的任意一条（codec 不支持或声道数全部超上限）
- **THEN** audio track routing service SHALL 返回 `preferredBackend='mpv'`
- **AND** 系统 SHALL NOT 先创建或 prepare AVPlayer 再降级

#### Scenario: 能力查询异常时保守选择 MPV
- **WHEN** 设备解码能力查询异常或能力未知
- **THEN** audio track routing service SHALL 保守返回 `preferredBackend='mpv'`
- **AND** 查询异常不得阻塞播放流程

#### Scenario: 能力查询按归一化 codec 去重
- **WHEN** 整组音轨存在多条相同编码的音轨
- **THEN** 系统 SHALL 按归一化 codec 去重后查询设备能力
- **AND** N 种唯一 codec 最多查询 N 次，不逐音轨启动播放器试播

### Requirement: Initial audio selection SHALL remain deterministic
系统 MUST 由 audio track routing service 统一计算初始音轨恢复建议，覆盖预置音轨与运行时轨道枚举两条路径。

#### Scenario: Restore user audio preference on session start
- **WHEN** 当前视频存在用户历史音轨绑定且当前会话音轨列表已就绪
- **THEN** audio track routing service SHALL 返回与该绑定一致的恢复建议
- **AND** 系统 SHALL 在当前会话中选择对应音轨

### Requirement: Initial audio selection SHALL respect device capability
系统 SHALL 在选择初始音轨时，将 codec 支持与声道数上限纳入兼容性判定；codec 支持但声道数超过设备能力上限的音轨不得判为可用。

#### Scenario: codec 支持但声道超上限时不选中该轨
- **WHEN** 某音轨的 codec 被设备支持
- **AND** 该音轨声道数超过设备该 codec 的最大声道能力
- **THEN** 系统 SHALL 不将该音轨判为可用
- **AND** 若存在其他兼容音轨 SHALL 优先选择兼容轨

#### Scenario: 无能力信息时回退现有选轨策略
- **WHEN** 当前音轨列表缺少可用的设备能力信息（如 MPV 运行时轨道无声道数据）
- **THEN** 系统 SHALL 回退到现有 codec 排名与语言偏好的确定性选轨策略
