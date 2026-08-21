# avsession-media-control Specification

## Purpose
应用作为系统媒体播控（AVSession Kit）的 Provider 接入，使小艺语音、智慧屏遥控器播放键与系统媒体中心能够控制本应用的播放/暂停等操作，并把当前媒体信息同步到系统侧展示。

## ADDED Requirements

### Requirement: 播放器页面 SHALL 创建并激活媒体会话
系统 SHALL 在播放器页面出现时创建一个类型为 video 的 AVSession 并激活，作为系统媒体播控的 Provider；一个 UIAbility 生命周期内仅维护一个会话。

#### Scenario: 进入播放器页面
- **WHEN** 用户进入播放器页面
- **THEN** 系统 SHALL 创建并激活 AVSession
- **AND** 会话失败创建或激活 SHALL 不影响播放器正常播放

#### Scenario: 退出播放器页面
- **WHEN** 用户退出播放器页面
- **THEN** 系统 SHALL 注销命令监听并销毁 AVSession

### Requirement: 系统播控命令 SHALL 控制播放器
系统 SHALL 监听系统下发的固定播放控制命令，并将其映射到播放器控制：`play` → 播放、`pause` 与 `stop` → 暂停、`seek` → 跳转进度、`setSpeed` → 设置倍速。

#### Scenario: 小艺语音暂停
- **WHEN** 视频播放中，用户对小艺说「暂停」
- **THEN** 系统 SHALL 收到 `pause` 命令并暂停当前视频

#### Scenario: 小艺语音恢复播放
- **WHEN** 视频处于暂停态，用户对小艺说「播放」或「继续播放」
- **THEN** 系统 SHALL 收到 `play` 命令并恢复播放

#### Scenario: 进度跳转
- **WHEN** 系统下发 `seek` 命令且携带合法的毫秒进度值
- **THEN** 系统 SHALL 将播放进度跳转到对应位置

#### Scenario: 倍速设置
- **WHEN** 系统下发 `setSpeed` 命令且携带合法的正数倍速
- **THEN** 系统 SHALL 应用该倍速，不支持的值按播放器既有规则归一化

### Requirement: 播放状态与元数据 SHALL 同步到系统播控
系统 SHALL 周期性向 AVSession 同步播放状态（播放/暂停/缓冲、进度位置、倍速）与媒体元数据（标题、时长），使系统播控与媒体中心展示的信息保持准确。

#### Scenario: 周期同步播放状态
- **WHEN** 播放进行中
- **THEN** 系统 SHALL 以不超过 1 秒的周期上报当前播放状态与进度位置

#### Scenario: 切换媒体后更新元数据
- **WHEN** 播放器切换到新的媒体（标题或时长变化）
- **THEN** 系统 SHALL 更新 AVSession 元数据中的标题与时长

### Requirement: 播控卡片 SHALL 可拉起应用
系统 SHALL 为 AVSession 配置启动能力，使用户点击系统播控中的媒体卡片时拉起本应用。

#### Scenario: 点击播控卡片
- **WHEN** 用户在系统播控界面点击本应用的媒体卡片
- **THEN** 系统 SHALL 启动本应用的 EntryAbility
