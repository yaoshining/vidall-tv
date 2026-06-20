## ADDED Requirements

### Requirement: UmamiAnalyticsService 上报 app_launch 事件

系统 SHALL 在 `EntryAbility.onCreate()` 完成 `UmamiAnalyticsService` 初始化后，立即发送 `app_launch` 事件，携带 `version` 和 `os_version` 字段。

#### Scenario: App 启动时发送 app_launch
- **WHEN** `EntryAbility.onCreate()` 执行，`UmamiAnalyticsService` 初始化完成
- **THEN** 系统发送 `name = app_launch` 的事件，`data` 中包含 `version`（App 版本号）和 `os_version`（HarmonyOS 系统版本）

### Requirement: VideoScannerUtil 扫描完成时上报 scan_completed 事件

系统 SHALL 在每次扫描流程结束时，通过 `UmamiAnalyticsService` 发送 `scan_completed` 事件，携带 `total_files` 和 `duration_ms` 字段。

#### Scenario: 扫描正常完成时上报
- **WHEN** `VideoScannerUtil` 扫描流程结束（无论成功还是部分失败）
- **THEN** 系统发送 `name = scan_completed` 的事件，`data.total_files` 为本次扫描文件数，`data.duration_ms` 为扫描耗时

### Requirement: 文件源连接成功/失败时上报对应事件

系统 SHALL 在文件源连接调用方（Store 层）完成连接尝试后，通过 `UmamiAnalyticsService` 上报结果事件，携带 `source_type` 字段；失败时额外携带 `error_code`。**不得**在 `WebDAVClient` / `SMBClient` 等底层 Client 中直接调用 analytics。

#### Scenario: 文件源连接成功时上报 source_connected
- **WHEN** 文件源连接调用成功返回
- **THEN** 系统发送 `name = source_connected` 的事件，`data.source_type` 为协议类型（如 `webdav`、`smb`）

#### Scenario: 文件源连接失败时上报 source_connect_failed
- **WHEN** 文件源连接调用失败（异常或返回错误）
- **THEN** 系统发送 `name = source_connect_failed` 的事件，`data.source_type` 为协议类型，`data.error_code` 为错误标识

### Requirement: 播放器错误时上报 playback_error 事件

系统 SHALL 在 `VidAllPlayerAdapter` 的 error 回调触发时，通过 `UmamiAnalyticsService` 发送 `playback_error` 事件，携带 `backend` 和 `error_code` 字段。

#### Scenario: 播放器进入 error 状态时上报
- **WHEN** AVPlayer 触发 error 状态回调
- **THEN** 系统发送 `name = playback_error` 的事件，`data.backend` 为播放后端标识（如 `avplayer`），`data.error_code` 为具体错误码

### Requirement: 设置项修改时上报 settings_changed 事件

系统 SHALL 在 `SettingsController` 保存每个设置项时，通过 `UmamiAnalyticsService` 发送 `settings_changed` 事件，携带 `setting_key` 和 `new_value`。`new_value` MUST 只包含值类型数据（布尔/枚举字符串），**禁止**传入路径、用户名、密码等敏感字段。

#### Scenario: 修改播放器设置时上报
- **WHEN** 用户在设置页修改播放器相关设置并保存
- **THEN** 系统发送 `name = settings_changed` 的事件，`data.setting_key` 为设置枚举常量，`data.new_value` 为新设置值（仅值类型）

#### Scenario: 不得上报路径或用户名等敏感字段
- **WHEN** 任意 `settings_changed` 事件构建时
- **THEN** `data.new_value` 中不包含文件路径、主机地址、用户名或密码等敏感信息
