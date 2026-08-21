## Context

- 应用为 HarmonyOS TV 视频播放器（`deviceTypes: ["tv"]`），targetSdkVersion 22 / compatibleSdkVersion 19，完全支持 AVSession Kit（API 10+）。
- 播放内核统一由 `VideoPlayerController` 暴露 `play()/pause()/seek()/setPlaybackSpeed()` 等接口，不依赖具体 backend（AVPlayer/MPV）。
- 播放器页面 `PlayerPage`（`pages/player/index.ets`）持有唯一 `VideoPlayerController` 实例，生命周期明确（`aboutToAppear`/`aboutToDisappear`），是接入系统播控的天然宿主。
- 华为智慧屏小艺语音的「播放/暂停」等媒体控制指令，经系统媒体播控中心向当前激活的 AVSession 下发固定控制命令（`play`/`pause`/`stop`/`seek`/`setSpeed`），遥控器媒体键与手机媒体中心走同一通道。

## Goals / Non-Goals

**Goals:**
- 让小艺语音、智慧屏遥控器播放键、系统媒体中心能够控制播放器的播放/暂停/进度/倍速
- 将当前媒体标题、时长、播放状态与进度同步到系统播控侧展示
- 播放器页面退出时干净释放会话，不残留系统级状态
- 接入失败不阻塞播放（优雅降级）

**Non-Goals:**
- 不接入小艺技能开放平台（Skills）实现「播放《XXX》第3集」类自定义语义指令（属于独立路线，后续可扩展）
- 不实现 `playNext`/`playPrevious` 命令控制切集（依赖播放列表上下文，复杂度高，暂不注册）
- 不处理 HarmonyOS 手机端的投播（AVCastPicker）
- 不改动 `VideoPlayerController` 内部播放逻辑与后端路由

## Decisions

### 1. 独立服务类 `AvSessionService` 封装 AVSession，回调注入解耦

新建 `services/avSession/AvSessionService.ets`，通过构造函数注入 `context`、`onCommand` 回调与 `getState` 快照读取器，**不直接 import `VideoPlayerController`**，避免服务层与播放器控制器产生循环依赖，同时便于单元测试。

- 命令回调：`onCommand(cmd, args?)`，由宿主页面映射到 controller 方法
- 状态快照：`getState(): AvSessionSyncState`（标题/播放中/缓冲/进度/时长/倍速），由宿主页面从 controller 实时读取

### 2. 会话类型与命令集

- `createAVSession(context, 'VidAll TV', 'video')` + `activate()`
- 注册固定命令：`play`、`pause`、`stop`、`seek`、`setSpeed`。只注册支持的命令，保证 `getValidCommands()` 反映真实能力
- `stop` 在应用侧映射为 `pause()`（保持播放会话，不退出播放页）

### 3. 状态同步策略：1s 定时器 + 去重

- 会话激活后启动 1s 定时器，周期性调用 `setAVPlaybackState`（播放/暂停/缓冲 + `PlaybackPosition{elapsedTime, updateTime}` 进度）与 `setAVMetadata`（标题 + 时长）
- 用「状态键」去重（`state|position|speed` 与 `title|duration`），仅在变化时发起 IPC 写，避免无效系统调用
- 切集后宿主调用 `refreshMetadata()` 立即刷新元数据，不等下一个周期

### 4. 生命周期跟随 PlayerPage

- `aboutToAppear` → 创建服务并 `init()`（异步，失败仅记日志）
- `aboutToDisappear` → `destroy()`（`off` 全部命令监听 + `destroy()` 会话）
- 一个 UIAbility 仅允许一个 AVSession，本设计满足该约束

### 5. 播控卡片拉起应用

- 通过 `wantAgent` 配置 `setLaunchAbility`，bundleName 从 `context.applicationInfo.name` 动态获取，abilityName 为 `EntryAbility`
- 失败不阻塞会话创建，仅记录日志

### 备选方案

- **在 `VideoPlayerController` 内直接创建会话**：耦合控制器与系统服务，且 controller 被多处复用，生命周期边界模糊，否决
- **每帧同步播放状态**：IPC 开销大，1s 周期已满足媒体中心进度展示精度，否决

## Risks / Trade-offs

- **小艺指令路由依赖系统**：小艺把语音识别为媒体控制命令的前提是系统识别到「当前播放会话」；部分智慧屏版本或非标准场景下可能走「可见即可说」OCR 通道，行为不可控，属系统侧行为，应用侧无解
- **一个 UIAbility 一个会话**：若未来出现多播放实例（如悬浮窗），需重新设计会话归属
- **`setPlaybackState` 写频率**：1s 周期写对系统服务有一定 IPC 压力，已通过去重缓解
- **API 差异**：`AVPlaybackState.position` 在 API 12+ 为 `PlaybackPosition` 对象结构（旧版为 number），已按当前 SDK（API 22）适配
