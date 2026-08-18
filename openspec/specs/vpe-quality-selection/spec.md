# vpe-quality-selection Specification

## Purpose

定义 VPE（Detail Enhancer）画质增强档位的自动选择策略：按源视频与显示分辨率的缩放比例自动选择档位（LOW/MEDIUM，最高 MEDIUM），取代用户手动选择档位；用户仅保留「关闭/开启」开关。最高档为 MEDIUM 是为了保留鸿鹄画质芯片的启动动画反馈（HIGH 档无该动画且肉眼增益难辨，用户感受优先）。
## Requirements
### Requirement: 用户开启画质增强 SHALL 必启用 VPE（至少低档）

当用户开启画质增强且运行时条件满足时，系统 SHALL 建立 VPE 增强管线（最低 LOW 档），缩放比例只决定档位高低，不决定是否启用。

#### Scenario: 开启后必启用
- **WHEN** 用户开启画质增强，且运行时支持 VPE、backend 为 avplayer、视频非 HDR
- **THEN** 系统 SHALL 建立 VPE 增强管线
- **AND** 档位 SHALL 至少为 LOW

#### Scenario: 1:1 或缩小也启用低档
- **WHEN** 缩放比例 ≤ 1.0（1:1 播放或缩小）
- **THEN** 系统 SHALL 以 LOW 档建立 VPE 增强管线（不因无缩放增益而关闭）

#### Scenario: 分辨率数据缺失时以低档启用
- **WHEN** 源视频宽高或显示尺寸缺失/非法（≤0），且用户已开启画质增强
- **THEN** 系统 SHALL 以 LOW 档建立 VPE 增强管线

#### Scenario: 源分辨率超出输入上限时不启用
- **WHEN** 源视频宽或高已知且 > 2000（如 4K 源）
- **THEN** 系统 SHALL NOT 建立 VPE 增强管线
- **AND** 播放器使用原始显示 surface 渲染

#### Scenario: 源分辨率低于输入下限时不启用
- **WHEN** 源视频宽或高已知且 < 32
- **THEN** 系统 SHALL NOT 建立 VPE 增强管线

### Requirement: 画质增强档位 SHALL 按缩放比例自动选择

系统 SHALL 根据源视频分辨率与显示分辨率计算缩放比例，自动选择画质增强档位（LOW/MEDIUM，最高 MEDIUM），取代用户手动选择档位。

#### Scenario: 达到缩放阈值选择中质量档
- **WHEN** 源视频宽高在 (32,2000] 内，且缩放比例 ≥ 1.5
- **THEN** 系统 SHALL 使用 MEDIUM 档建立 VPE 增强管线

#### Scenario: 未达到缩放阈值选择低质量档
- **WHEN** 源视频宽高在 (32,2000] 内，且缩放比例 < 1.5（含 1:1 与缩小）
- **THEN** 系统 SHALL 使用 LOW 档建立 VPE 增强管线

#### Scenario: 自动选档与 HDR 门控叠加
- **WHEN** 当前视频为 HDR（HDR10/HLG/DV）
- **THEN** 系统 SHALL NOT 建立 VPE 增强管线（无论缩放比例如何）

### Requirement: 显示尺寸 SHALL 灵活适配多数据源

系统 SHALL 按优先级获取显示目标尺寸：优先 XComponent 显示区域物理像素，其次屏幕物理像素；两者都不可用时以「数据缺失」处理（档位退化为低档），不阻断启用。

#### Scenario: XComponent 区域尺寸可用时优先采用
- **WHEN** XComponent `onAreaChange` 已上报有效显示区域尺寸（物理像素）
- **THEN** 系统 SHALL 使用该尺寸计算缩放比例

#### Scenario: XComponent 尺寸缺失时回退屏幕尺寸
- **WHEN** XComponent 显示区域尺寸尚未上报或不可用，且 `@ohos.display` 可返回屏幕物理像素
- **THEN** 系统 SHALL 使用屏幕物理像素计算缩放比例

#### Scenario: 显示尺寸全部不可用时退化低档
- **WHEN** XComponent 与屏幕尺寸均不可用
- **THEN** 系统 SHALL 按数据缺失处理
- **AND** 自动选档 SHALL 返回 LOW（不阻断启用）

#### Scenario: 显示尺寸后到则运行中换档
- **WHEN** VPE 已以某档位运行，随后显示尺寸上报并重算出不同档位
- **THEN** 系统 SHALL 更新档位（运行中换档，不重建管线）

### Requirement: 设置菜单 SHALL NOT 提供手动档位选择

播放器设置页 SHALL 只提供画质增强「关闭 / 开启」开关，不提供「低/中/高」档位选择；档位由系统按缩放比例自动决定。

#### Scenario: 设置页只展示开关
- **WHEN** 画质增强可用（运行时支持 VPE、backend 为 avplayer、非 HDR 视频）
- **THEN** 设置页 SHALL 展示「关闭 / 开启」两个选项
- **AND** 设置页 SHALL NOT 展示「低 / 中 / 高」档位选项

#### Scenario: 开启后档位自动生效
- **WHEN** 用户开启画质增强
- **THEN** 系统 SHALL 按当前视频与显示的缩放比例自动选择档位
- **AND** 用户无需（也无法）手动指定档位

### Requirement: 源视频分辨率 SHALL 透传到画质增强门控

ffprobe 探测出的源视频宽高 SHALL 沿 routing decision 链路透传到播放器控制器，供自动选档使用。

#### Scenario: 视频流宽高透传
- **WHEN** ffprobe 探测一个包含视频流的媒体
- **THEN** 探测结果的视频流 SHALL 携带 `width` / `height`
- **AND** 播放器控制器 SHALL 可读取到当前视频的源宽高（`videoWidth` / `videoHeight`）

#### Scenario: 探测失败时宽高缺失
- **WHEN** ffprobe 探测失败或未返回宽高
- **THEN** 控制器中的源宽高 SHALL 为缺失（undefined）
- **AND** 自动选档 SHALL 返回 LOW（以低档启用，保证开关生效）

