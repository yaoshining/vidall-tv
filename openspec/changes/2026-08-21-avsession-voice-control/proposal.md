## Why

华为智慧屏用户期望用语音（小艺）直接控制第三方视频应用的播放/暂停，而不是依赖遥控器按键。当前应用未接入系统媒体播控服务（AVSession），小艺语音、遥控器播放键、系统媒体中心均无法控制播放器，与主流 TV 视频应用的用户体验存在差距。

## What Changes

- 新增 `AvSessionService`：创建并激活 AVSession（类型 `video`），作为系统媒体播控的 Provider
- 注册固定播放控制命令监听：`play` / `pause` / `stop` / `seek` / `setSpeed`，将系统下发的命令桥接到 `VideoPlayerController`
- 周期性同步播放状态（`AVPlaybackState`：播放/暂停/缓冲 + 进度位置）与媒体元数据（`AVMetadata`：标题、时长）到系统播控，供小艺/媒体中心展示
- 通过 `setLaunchAbility` 配置点击系统播控卡片时拉起应用
- 会话生命周期跟随 `PlayerPage`（进入创建、退出销毁），切集时刷新元数据
- 适配 API 22 的 `PlaybackPosition { elapsedTime, updateTime }` 结构

## Capabilities

### New Capabilities
- `avsession-media-control`: 应用作为系统媒体播控（AVSession）Provider，接收小艺语音/遥控器/媒体中心下发的播放控制命令并同步播放状态与元数据

### Modified Capabilities
<!-- 无既有能力的行为变化：本变更仅新增媒体播控接入，不改变现有播放内核、路由、续播等能力的行为。 -->

## Impact

- 新增代码：`entry/src/main/ets/services/avSession/AvSessionService.ets`
- 修改代码：`entry/src/main/ets/pages/player/index.ets`（PlayerPage 集成，命令桥接 + 生命周期管理）
- 依赖：`@kit.AVSessionKit`（API 12+，本项目 compatibleSdkVersion 19 支持）、`@kit.AbilityKit`（wantAgent）
- 权限：无需新增权限声明
- 行为影响：应用播放时成为系统可感知的媒体会话；播放器页面可见时，系统播控可下发控制命令
