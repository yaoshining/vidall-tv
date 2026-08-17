## Why

VPE 画质增强（Detail Enhancer）当前让用户在设置菜单手动选择「低/中/高」档位，但用户不理解档位含义，选择结果常与实际播放场景错配。官方《视频缩放》文档明确：LOW/MEDIUM 仅在缩放场景生效、等比缩放时无清晰度增强效果；HIGH 才支持等比清晰度增强且输入分辨率要求 [512,2000]。因此在 4K 原盘 1:1 播放时默认 MEDIUM 档实际无收益，白白消耗 GPU 与管线延迟。

改为按「缩放比例」自动选档：系统根据源视频分辨率与显示分辨率自动决定是否启用、用哪一档，用户只保留一个「开/关」总开关。

## What Changes

- 移除设置菜单「画质增强」区的「低/中/高」档位选择，只保留「关闭 / 开启」。
- 用户开启画质增强后必启用 VPE（至少 LOW 档）：缩放比例只决定档位高低，不决定是否启用。
- 新增纯函数 `resolveVpeQualityByScaling(srcW, srcH, dispW, dispH)`：按缩放比例返回档位，最低 LOW；仅当源分辨率超出 Detail Enhancer 输入硬约束（宽高已知且 >2000 或 <32）时返回 `null` 表示无法启用。
- `VideoData` 及 routing decision 透传源视频 `width/height`（沿既有 `videoHdrType` 同链路）。
- 显示目标尺寸多级 fallback：优先 XComponent 显示区域物理像素，其次 `@ohos.display` 屏幕物理像素，都不可用时按数据缺失退化为 LOW 档。
- `tryCreateVpeEnhancer` 用自动选档结果替代 `aiEnhanceQuality` 手动档位。
- `aiEnhanceQuality` 从「用户偏好」改为「当前播放按缩放比例计算的派生档位」，不再由用户直接设置。

## Capabilities

### New Capabilities

- `vpe-quality-selection`: 画质增强（VPE Detail Enhancer）档位的自动选择策略——按源视频与显示分辨率的缩放比例决定是否启用及档位，取代手动档位选择。

### Modified Capabilities

<!-- 无：本变更只新增档位选择策略，不改动 vpe-runtime-compatibility 的运行时探测/降级/HDR 门控语义。 -->

## Impact

- **修改代码**：
  - `entry/src/main/ets/components/core/player/VideoPlayerController.ets`（新增 `resolveVpeQualityByScaling` 纯函数、`tryCreateVpeEnhancer` 改用自动档位、`setAiEnhance` 语义调整）
  - `entry/src/main/ets/components/core/player/PlayerSettingsDialog.ets`（移除低/中/高档位 UI，保留开/关）
  - `entry/src/main/ets/components/core/player/VideoData.ets`（新增 `videoWidth?`/`videoHeight?`）
  - `entry/src/main/ets/services/audioRouting/AudioRoutingTypes.ets`、`AudioTrackRoutingService.ets`（透传源视频宽高）
  - `entry/src/main/ets/services/playback/PlaybackBackendTypes.ets`、`PlaybackBackendService.ets`（透传宽高）
- **修改测试**：`entry/src/test/VideoPlayerController.test.ets`（新增 `resolveVpeQualityByScaling` 用例）
- **不变**：后端路由（仍 avplayer/mpv）；HDR 门控（`isHdrVideo` 跳过 VPE）；`aiEnhanceEnabled` 仍为用户全局开关。
- **依赖**：显示尺寸优先用 XComponent `onAreaChange`（无额外系统能力依赖）；`@ohos.display` 仅作兜底，不可用时退化为 LOW 档（不阻断启用）。
- **存储迁移**：`aiEnhanceEnabled`/`aiEnhanceQuality` 当前为内存态（未见持久化），若实现时发现有持久化需一并迁移；`aiEnhanceQuality` 不再持久化。

## 延后（本次不做）

- 不引入「按码率/片源质量自动开关」等更复杂的画质策略。
- 不改动 VPE 的 C API 或 native 层（仅 TS 侧档位选择逻辑）。
- 阈值（1.5 / 2.0）作为初始建议值，真机效果调优留待后续。
