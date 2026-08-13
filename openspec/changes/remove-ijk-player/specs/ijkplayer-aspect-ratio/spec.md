## REMOVED Requirements

### Requirement: ijkplayer 后端保持视频原始宽高比（FIT 模式）
**Reason**: IJKPlayer 后端及其 XComponent 将被完整移除，不再存在 IJK 专属显示比例行为。
**Migration**: AVPlayer 与 MPV 继续使用各自现有的通用 `AspectRatioMode` 映射。

### Requirement: ijkplayer 后端支持 AspectRatioMode 切换
**Reason**: IJKPlayer 后端及其运行时布局切换能力不再存在。
**Migration**: 用户继续通过 AVPlayer 或 MPV 使用 FIT、FILL、STRETCH 模式。

### Requirement: ijkVideoRatio 在每次播放初始化时重置
**Reason**: IJKPlayer 专属 DAR 状态随该后端一并删除。
**Migration**: 无需迁移；保留后端不读取该状态。
