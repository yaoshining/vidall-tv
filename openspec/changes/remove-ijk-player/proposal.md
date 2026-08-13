## Why

IJKPlayer 与 MPV 共用外部 FFmpeg 动态库，但项目仍维护 IJK 独立依赖、后端适配、UI surface、字幕桥接、设置入口和双向回退逻辑，增加包体、维护成本及播放状态复杂度。现有 MPV 已具备软解兜底能力，应将播放链路收敛为 AVPlayer 主播放、MPV 唯一回退。

## What Changes

- **BREAKING** 删除 IJKPlayer HAR、ArkTS adapter、XComponent、字幕桥接、硬解能力查询及相关原生接口。
- **BREAKING** 删除 IJK/MPV 回退内核偏好设置与播放中手动内核切换入口；AVPlayer 不支持或初始化失败时固定回退 MPV。
- MPV 播放失败后进入统一播放错误处理，不再尝试切换 IJK。
- 历史 `native` / `ffmpeg` 后端标识暂时保留兼容，但其旧 IJK 映射改为 MPV。
- 删除 IJK 专属测试、文档和宽高比规格，更新通用后端、续播、来源适配及 VPE 契约。
- 保留 MPV HAR、项目自有 FFmpeg 动态库、通用预置音轨/字幕数据，以及 ffprobe/字幕读取仍使用的 SMB 代理能力。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `ijkplayer-aspect-ratio`: 移除 IJK XComponent 显示宽高比计算与布局要求。
- `player-fallback-preference`: 移除可配置回退内核，改为 MPV 唯一回退及最终错误行为。
- `playback-backend-service`: 后端集合和生命周期管理移除 IJK，并将兼容兜底收敛到 MPV。
- `mpv-player-backend`: MPV 从可选回退后端变为 AVPlayer 的唯一回退后端。
- `playback-source-adapter-service`: 来源解析结果和后端选择不再包含 IJK 路径。
- `playback-resume-recovery`: 回退续播恢复场景由 IJK/MPV 双后端收敛为 MPV。
- `vpe-runtime-compatibility`: VPE 非 AVPlayer 路径描述移除 IJK，仅覆盖 MPV 等保留后端。

## Impact

- 依赖与资产：`oh-package.json5`、根锁文件、`package/ijkplayer.har`。
- 播放核心：backend types/service、`VideoPlayerController`、IJK adapter、字幕桥接、布局和设备能力工具。
- UI 与偏好：播放器 XComponent、控制菜单、设置页、`PLAYER_FALLBACK` 偏好键。
- 原生接口：仅为 IJK 接管 SMB 代理或硬解决策服务的 NAPI/C++ 导出；通用代理 URL 能力继续保留。
- 测试与文档：播放器单测注册、IJK 专属用例、README、IJK 使用文档和相关 OpenSpec 主规格。
