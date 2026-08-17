# Design: vpe-auto-quality-by-scaling

## Context

VPE 画质增强（Detail Enhancer）目前由用户在设置菜单手动选择「低/中/高」档位，`VideoPlayerController.aiEnhanceQuality` 默认 `medium`。官方《视频缩放》文档给出档位与「缩放」的强关联：

| 档位 | 输入分辨率要求 | 效果 |
| --- | --- | --- |
| NONE | 宽高 (32,2000] | 仅缩放，无清晰度增强 |
| LOW（默认） | 宽高 (32,2000] | 仅缩放场景；等比缩放时无清晰度增强 |
| MEDIUM | 宽高 (32,2000] | 仅缩放场景；等比缩放时无清晰度增强 |
| HIGH | 宽高 [512,2000] | 缩放+清晰度增强；等比缩放时也能清晰度增强 |

本变更把档位选择自动化，用户只保留总开关。

## Goals / Non-Goals

**Goals:**
- 移除「低/中/高」手动档位，用户只保留「开/关」总开关。
- **用户开启开关后必启用 VPE（至少 LOW 档）**：缩放比例只决定档位高低，不决定是否启用，保证开启后用户能看到增强已生效的反馈。
- 档位按「缩放比例」自动选择：放大越多档位越高；1:1/缩小/数据缺失用最低档 LOW。
- 显示尺寸来源灵活适配（多级 fallback），适配不同型号 TV。
- 自动选档逻辑为纯函数，可单测。
- 源视频宽高与显示尺寸两条数据链打通到 `tryCreateVpeEnhancer`。

**Non-Goals:**
- 不改 native VPE 层与 C API。
- 不改 HDR 门控（`isHdrVideo` 跳过 VPE 的语义保持）。
- 不引入码率/片源质量等更复杂的自动开关策略。
- 不做真机阈值调优（阈值作为初始建议值）。

## Decisions

### 1. 自动选档核心信号：缩放比例 scale = max(dispW/srcW, dispH/srcH)

- **为什么**：Detail Enhancer 的收益来自「把低分辨率内容放大到高分辨率输出」。取宽高放大量的较大值，代表「覆盖显示区域所需的最小放大倍数」，对 FIT/FILL 都偏保守且可解释。
- **不取面积比/对角线比**：宽高各自比例的最大值更直观，且便于与「1.5」「2.0」阈值对齐。

### 2. 档位映射规则（纯函数 `resolveVpeQualityByScaling`）

```
resolveVpeQualityByScaling(srcW, srcH, dispW, dispH): VpeQualityLevel | null
```

返回值语义：`null` 仅表示「无法启用」（超出 Detail Enhancer 输入硬约束）；其余情况都返回一个档位，**最低为 low**。

1. 源宽高**已知且** `srcW > 2000 || srcH > 2000` → `null`（超出 Detail Enhancer 输入上限；如 4K 源 3840/2160 无法作为输入）。
2. 源宽高**已知且** `srcW < 32 || srcH < 32` → `null`（低于输入下限）。
3. 源宽高或显示尺寸缺失/≤0 → `'low'`（数据不足无法算比例，用最低档保证「开启即生效」）。
4. `scale = max(dispW/srcW, dispH/srcH)`。
5. `scale < 1.5` → `'low'`（含 1:1 与缩小）。
6. `1.5 <= scale < 2.0` → `'medium'`。
7. `scale >= 2.0`：若 `srcW >= 512 && srcH >= 512` → `'high'`（HIGH 档要求输入 [512,2000]）；否则 → `'medium'`（源 <512 时 HIGH 不可用）。

- **「开启即启用（至少 low）」是产品决策**：即使 1:1/缩小场景 LOW 档按官方文档无清晰度增强效果，仍建立 VPE 管线，让用户看到增强已生效（有启动/处理反馈）。纯技术「无收益则关闭」被产品诉求覆盖。
- **阈值 1.5 / 2.0 为初始建议值**，在常量集中定义，便于后续真机调优。

### 3. 源视频分辨率沿 `videoHdrType` 同链路透传

`probe.videoTracks[0].width/height` 已在 ffprobe 结果中。沿 `AudioRoutingInput.probeVideoWidth/probeVideoHeight` → `AudioRoutingDecision.videoWidth/videoHeight` → `PlaybackBackendDecision.videoWidth/videoHeight` → `VideoData.videoWidth/videoHeight` → controller。

- **为什么**：与 `videoHdrType` 同源同生命周期，避免各播放入口重复探测。
- **降级**：ffprobe 失败时宽高为 `undefined`，`resolveVpeQualityByScaling` 返回 `'low'` → 仍启用 VPE（满足「开启即生效」）。但注意：宽高缺失也意味着无法做 4K 上限判断，存在「4K 源误启用」的残余风险（见 Risks）。

### 4. 显示尺寸多级 fallback（灵活适配不同型号 TV）

显示目标尺寸按以下优先级获取，取第一个可用值：

1. **XComponent `onAreaChange` 上报的物理像素**（`vp2px(vpW/vpH)`）：最贴合播放器实际显示区域，不依赖额外系统能力。avplayer 分支补 `onAreaChange`（mpv 分支已有），上报到 controller 缓存。
2. **`@ohos.display.getDefaultDisplaySync()` 屏幕物理像素**：兜底，TV 全屏播放器时屏幕 ≈ 显示区域。
3. **两者都拿不到**：`dispW/dispH` 视为缺失 → `resolveVpeQualityByScaling` 返回 `'low'`，不阻断启用。

- **为什么**：`@ohos.display` 在不同型号 TV 的可用性不确定，不能作为唯一数据源；XComponent 是播放器必然拥有的组件，其 `onAreaChange` 最可靠。
- **时序**：`tryCreateVpeEnhancer` 发生在 `onLoad → initPlayer`；`onAreaChange` 可能在 `onLoad` 之后才回调。因此先按「当时可用的显示尺寸」建 VPE（缺尺寸时用 low），拿到新尺寸后重算档位，档位变化则 `VpeEnhancerUtil.updateQuality()`（已支持运行中换档、不重建管线）。

### 5. 门控整合在 `tryCreateVpeEnhancer`

在现有守卫（runtimeSupported / aiEnhanceEnabled / backend==='avplayer' / isHdrVideo）之后，调用 `resolveVpeQualityByScaling`：

- 返回 `null`（源分辨率超硬约束）→ 跳过 VPE，返回原始 `displaySurfaceId`（记日志）。
- 返回档位 → 以该档位调用 `VpeEnhancerUtil.createEnhancer(displaySurfaceId, resolvedQuality)`，替代 `this.aiEnhanceQuality`。

- **为什么**：`currentVideoData` 在 `initPlayer` 内已同步赋值，门控点单一，覆盖所有 avplayer 入口。
- **`aiEnhanceEnabled` 语义不变**：用户全局开关；开启即启用（至少 low），自动选档只决定档位。

### 6. `aiEnhanceQuality` 从「用户偏好」变为「派生值」

- `setAiEnhance(quality)` 改为 `setAiEnhance()`（不接收档位），开启时不再写入固定档位。
- `tryCreateVpeEnhancer` 每次用 `resolveVpeQualityByScaling` 的返回值；`aiEnhanceQuality` 字段保留为「当前已解析档位」用于 UI 展示/日志，但不再由用户直接设置。

### 7. UI：只保留「关闭 / 开启」

`PlayerSettingsDialog` 画质增强区移除「低/中/高」三个 chip，改为「关闭 / 开启」两个 chip；开启后由系统自动选档。`@State aiEnhanceQuality` 与相关档位样式分支一并删除。

## Risks / Trade-offs

- **「开启即启用」在 1:1/缩小场景可能只有「心理反馈」而无实际清晰度增益**：LOW 档按官方文档在等比缩放时无清晰度增强效果。这是产品明确接受的取舍（用户要求保证开启后有生效反馈）。
- **宽高缺失时无法做 4K 上限判断**：ffprobe 失败会导致 `srcW/srcH` 为 undefined，此时无法排除 4K 源，可能建立超限输入（VPE 可能报错，参考 issue-255 的 `29210006` 同类风险）。缓解：HDR 门控已独立于宽高生效；SDR 4K 源是主要残余场景，若真机复现再在 ffprobe 失败时补充保守策略。
- **显示尺寸多级 fallback 的时序**：`onAreaChange` 晚于 `initPlayer` 时先用 low 建 VPE，后 `updateQuality` 换档；换档是运行中参数更新，风险低但需验证不引起画面闪烁。
- **阈值未经真机调优**：1.5 / 2.0 是经验值，留作后续调优。
- **屏幕尺寸 ≠ 视频实际显示尺寸**：FIT 黑边/旋转会导致估算偏差；对 TV 横屏全屏场景影响可忽略。
- **行为变化感知**：4K 原盘 1:1 播放从「默认 MEDIUM」变为「low」，档位下降但管线仍建立；需在发布说明说明「自动档位」语义。
