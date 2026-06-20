# VPE Runtime Compatibility

## Purpose

定义 VPE 运行时兼容策略，确保缺少 VPE 运行库时应用仍可完成主模块加载、按运行时能力安全降级，并且不暴露不可用的增强功能入口。

## Requirements

### Requirement: 缺少 VPE 运行库时应用仍可加载原生主模块

系统 SHALL 在缺少 `libvideo_processing.so` 或等效 VPE 运行依赖的环境中，仍然成功加载 `libvidall_core_player_napi.so`，不得因为 VPE 不可用而阻断应用启动、文件源能力或基础播放器能力。

#### Scenario: 模拟器缺少 VPE 运行库时主模块仍可加载
- **WHEN** 应用运行在未提供 `libvideo_processing.so` 的模拟器或设备环境
- **THEN** `libvidall_core_player_napi.so` 仍可被成功加载
- **AND** 应用首页与基础业务页面可以正常进入

#### Scenario: 无 VPE 环境下基础播放链路仍可用
- **WHEN** 当前环境无法启用 VPE
- **THEN** WebDAV、SMB、ffprobe、播放器初始化等依赖主 NAPI 的基础能力仍可正常调用
- **AND** 系统不得因为 VPE 缺失而让这些能力初始化失败

---

### Requirement: VPE 启用必须受运行时能力探测控制

系统 SHALL 仅在运行时确认 VPE 依赖与初始化条件满足时，才报告 VPE 可用；当任一条件不满足时，系统 MUST 将 VPE 视为不可用并进入降级路径。

#### Scenario: 运行时探测失败时判定为不支持
- **WHEN** 系统能力存在但 VPE 运行库缺失、加载失败或初始化失败
- **THEN** VPE 能力查询结果返回“不支持”
- **AND** 系统使用非 VPE 的标准播放链路继续运行

#### Scenario: 运行时探测成功时允许启用 VPE
- **WHEN** 当前设备具备 VPE 所需系统能力且运行时依赖完整可用
- **THEN** 系统返回“支持 VPE”
- **AND** 后续播放器增强逻辑可按现有流程启用 VPE

---

### Requirement: 无 VPE 能力时不暴露不可用功能

当 VPE 不可用时，系统 SHALL 隐藏或禁用所有 VPE 相关入口、设置项与增强控制逻辑，避免用户看到无法工作的画质增强功能。

#### Scenario: 设置页不显示不可用的 VPE 控件
- **WHEN** 当前环境的 VPE 能力探测结果为“不支持”
- **THEN** 播放器设置页不展示或不可操作 VPE 相关选项
- **AND** 用户不会因点击相关入口触发错误

#### Scenario: 历史状态要求开启 VPE 时自动回退
- **WHEN** 用户的历史配置或默认状态指向开启 VPE
- **AND** 当前运行环境不支持 VPE
- **THEN** 系统自动回退为关闭增强的播放状态
- **AND** 播放会话仍可正常开始
