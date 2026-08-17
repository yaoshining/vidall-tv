## ADDED Requirements

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

### Requirement: ffprobe 探测结果 SHALL 输出视频色彩元数据

native ffprobe 探测 SHALL 在视频流中输出色彩元数据字段，供上层判定 HDR 类型与色彩空间。

#### Scenario: 视频流输出色彩元数据
- **WHEN** ffprobe 探测一个包含视频流的媒体
- **THEN** 探测结果的视频流 SHALL 包含 `color_transfer`（含 SMPTE ST 2084 / ARIB STD-B67 对应的数值）与 `color_primaries` / `color_space` / `color_range` / `pix_fmt` 等字段
- **AND** 上层 SHALL 可依据这些字段判定 HDR10 / HLG / SDR
