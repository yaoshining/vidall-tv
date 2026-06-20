## ADDED Requirements

### Requirement: ijkplayer 后端保持视频原始宽高比（FIT 模式）
当 `AspectRatioMode` 为 `FIT` 时，ijkplayer 后端 SHALL 以保持视频原始宽高比的方式渲染画面，不足部分用黑色填充，与 AVPlayer 后端视觉效果一致。

DAR（Display Aspect Ratio）计算规则：
- 若 `sarNum > 0` 且 `sarDen > 0`：`DAR = (pixelWidth × sarNum) / (pixelHeight × sarDen)`
- 否则：`DAR = pixelWidth / pixelHeight`
- 若 DAR ≤ 0：退化为全屏显示（不应用宽高比约束）

#### Scenario: 宽屏视频在 FIT 模式下显示正确黑边
- **WHEN** ijkplayer 播放 16:9 以外的宽屏视频（如 2.39:1），`AspectRatioMode` 为 `FIT`
- **THEN** 视频画面保持原始比例，上下出现黑边，画面不拉伸

#### Scenario: 标准视频在 FIT 模式下显示无变形
- **WHEN** ijkplayer 播放 16:9 视频（与屏幕比例一致），`AspectRatioMode` 为 `FIT`
- **THEN** 视频画面填满全屏，无黑边，无拉伸

#### Scenario: SAR 非 1/1 时 DAR 正确修正
- **WHEN** 视频的 SAR（Sample Aspect Ratio）不为 1/1（如变形宽银幕格式）
- **THEN** 系统使用 `pixelWidth × sarNum / (pixelHeight × sarDen)` 计算 DAR，而非直接使用像素宽高比

#### Scenario: SAR 为 0/0 时 fallback 到像素比
- **WHEN** `onVideoSizeChanged` 返回 `sarNum = 0` 或 `sarDen = 0`
- **THEN** 系统 fallback 使用 `pixelWidth / pixelHeight` 作为 DAR，不崩溃

### Requirement: ijkplayer 后端支持 AspectRatioMode 切换
ijkplayer 后端 SHALL 响应 `AspectRatioMode` 的运行时切换，三种模式均正确生效。

#### Scenario: 切换到 FILL 模式
- **WHEN** 用户将 `AspectRatioMode` 切换为 `FILL`
- **THEN** ijkplayer 画面等比裁剪铺满全屏，不保留黑边

#### Scenario: 切换到 STRETCH 模式
- **WHEN** 用户将 `AspectRatioMode` 切换为 `STRETCH`
- **THEN** ijkplayer 画面拉伸填满全屏

#### Scenario: 切换回 FIT 模式
- **WHEN** 用户将 `AspectRatioMode` 切换回 `FIT`
- **THEN** 视频重新保持原始宽高比显示，黑边恢复

### Requirement: ijkVideoRatio 在每次播放初始化时重置
`VideoPlayerController.ijkVideoRatio` SHALL 在每次 `initPlayer()` 调用开始时重置为 `0`，避免上一个视频的 DAR 残留影响下一个视频首帧显示。

#### Scenario: 切换视频时比例重置
- **WHEN** 用户从一个视频切换到另一个视频（触发 `initPlayer()`）
- **THEN** 新视频的 XComponent 在收到 `onVideoSizeChanged` 之前保持全屏显示，不使用上一个视频的 DAR
