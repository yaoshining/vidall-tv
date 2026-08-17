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

---

### Requirement: MPV 后端在不兼容架构上 SHALL 安全失败
MPV 播放后端依赖包含目标架构原生库的播放器包。系统 MUST 在运行环境与 MPV 原生库不兼容时阻止加载 MPV，并进入统一播放错误处理，不得回退到已移除的播放内核。

#### Scenario: 不兼容架构触发统一播放错误
- **WHEN** AVPlayer 无法播放当前媒体
- **AND** 当前运行架构无法加载 MPV 原生库
- **THEN** 系统 SHALL 显示统一播放错误

#### Scenario: ARM 真机上 MPV 后端正常可用
- **WHEN** 应用运行在 MPV 原生库支持的 ARM 真机
- **THEN** MPV 后端 SHALL 正常工作
- **AND** AVPlayer 失败后 SHALL 能够回退到 MPV

---

### Requirement: HDR 视频 SHALL NOT 启用 VPE 画质增强

系统 SHALL 在播放 HDR 视频（HDR10 / HLG / Dolby Vision）时跳过 VPE（AI 画质增强）管线建立，走 AVPlayer 原生渲染；SDR 视频维持现有 VPE 行为。

#### Scenario: HDR10 视频跳过 VPE
- **WHEN** ffprobe 探测到视频 `color_transfer` 为 SMPTE ST 2084 / PQ（HDR10）
- **THEN** 系统 SHALL NOT 建立 VPE 增强管线
- **AND** 播放器使用原始显示 surface 走 AVPlayer 原生渲染

#### Scenario: HLG 视频跳过 VPE
- **WHEN** ffprobe 探测到视频 `color_transfer` 为 ARIB STD-B67（HLG）
- **THEN** 系统 SHALL NOT 建立 VPE 增强管线
- **AND** 播放器使用原始显示 surface 走 AVPlayer 原生渲染

#### Scenario: Dolby Vision 视频跳过 VPE
- **WHEN** ffprobe 探测到视频为 Dolby Vision（有 DV profile 或 profile 字符串含 "Dolby Vision"）
- **THEN** 系统 SHALL NOT 建立 VPE 增强管线

#### Scenario: SDR 视频正常启用 VPE
- **WHEN** 视频为 SDR 且运行时支持 VPE、用户开启画质增强
- **THEN** 系统 SHALL 按现有流程建立 VPE 增强管线

#### Scenario: 探测失败按 SDR 降级
- **WHEN** ffprobe 探测失败或未返回 HDR 类型
- **THEN** 系统 SHALL 将视频视为 SDR/未知处理
- **AND** VPE 启用逻辑 SHALL 保持现有降级行为（不因无法判定而阻断）

#### Scenario: HDR 视频隐藏画质增强设置
- **WHEN** 当前播放视频为 HDR
- **THEN** 播放器设置页 SHALL NOT 展示可操作的「画质增强」选项

#### Scenario: SDR 切换到 HDR 时销毁残留 VPE
- **WHEN** 播放源从 SDR 切换到 HDR
- **AND** 之前 SDR 会话已建立 VPE 增强管线
- **THEN** 系统 SHALL 销毁旧的 VPE 实例后再跳过新会话的 VPE 创建
- **AND** 新会话使用原始显示 surface 走 AVPlayer 原生渲染

---

### Requirement: ffprobe 探测结果 SHALL 输出视频色彩元数据

native ffprobe 探测 SHALL 在视频流中输出色彩元数据字段，供上层判定 HDR 类型与色彩空间。

#### Scenario: 视频流输出色彩元数据
- **WHEN** ffprobe 探测一个包含视频流的媒体
- **THEN** 探测结果的视频流 SHALL 包含 `color_transfer`（含 SMPTE ST 2084 / ARIB STD-B67 对应的数值）与 `color_primaries` / `color_space` / `color_range` / `pix_fmt` 等字段
- **AND** 上层 SHALL 可依据这些字段判定 HDR10 / HLG / SDR

#### Scenario: Dolby Vision 视频流输出 DOVI 配置
- **WHEN** ffprobe 探测到包含 Dolby Vision 配置（`AV_PKT_DATA_DOVI_CONF`）的视频流
- **THEN** 探测结果 SHALL 包含 `dv_profile` / `dv_level` / `dv_bl_signal_compatibility_id` 字段
- **AND** 上层 SHALL 可依据 `dv_profile` 判定 Dolby Vision
