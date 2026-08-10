## Why

VidAll_TV 当前在生产环境可用的播放内核只有 HarmonyOS 系统 `AVPlayer` 与 `ijkplayer`，前者不支持 AC-3/DTS 等常见音频编码，后者虽然能软解但已停止维护、性能与功能受限。VidAll_Player 仓库基于 libmpv 的 `@vidall/player` HAR 候选 `003-libmpv-player-har` 已于 2026-08-07 通过 G1/G2/G3 门禁，获得 Go 签发，具备接入 VidAll_TV 的条件。本变更将 mpv 内核引入 VidAll_TV 作为可选播放后端，与 ijkplayer 并列作为 AVPlayer 不支持时的回退选项，同时为后续逐步替换 ijkplayer 铺路。

## What Changes

- **新增 `mpv` 播放后端**：在 `PlaybackBackendService` 现有后端枚举（`'avplayer' | 'ijkplayer' | 'ffmpeg' | 'native'`）基础上新增 `'mpv'`，通过新增的 `MpvPlayerAdapter`（实现 `IPlayer` 接口）桥接到 `@vidall/player` HAR 的 `VidAllPlayer` 契约。
- **新增 XComponent 挂载分支**：`VideoPlayer.ets` 在现有 avplayer（`XComponentController` 模式）与 ijkplayer（`libraryname` 模式）两条 XComponent 分支之外，新增第三条 mpv 分支，使用 `XComponentController` + `XComponentSurfaceAdapter` 模式接入 `attachSurface/resizeSurface/detachSurface` 生命周期。
- **新增"播放内核回退"全局设置**：`Settings` 页新增分组，允许用户在 `ijkplayer` 与 `mpv` 之间选择 AVPlayer 不支持时的默认回退内核；选择持久化到 `AppPreferences`。AVPlayer 永远作为首选，此项仅控制回退目标，不是三选一。
- **新增播放中"内核切换"菜单项**：`VideoControls` 播放中菜单新增"内核切换"按钮，允许用户在当前播放过程中强制切换 `ijkplayer ↔ mpv`（不依赖 AVPlayer 探测结果），切换后保持当前播放位置。
- **新增内核失败兜底 UX**：当用户当前选中的回退内核（ijkplayer 或 mpv）也播放失败时，不直接报错退出，而是弹出确认对话框询问"是否尝试使用另一内核播放？"，确认后自动切换并重试。
- **字幕渲染策略**：mpv 后端的字幕默认仍由 TV 端 `SubtitleBridgeAdapter` + `SubtitleRenderer` 绘制（保持与 ijk/avplayer 一致的 UI 体验），通过 `subtitleText` 事件桥接到 `onEmbeddedTimedText` 等价路径；仅当遇到 PGS/VobSub 图形字幕（`subtitleText` 无法给出文本）时，才启用 mpv 内嵌字幕合成作为兜底。
- **新增依赖**：`entry/oh-package.json5` 增加 `"@vidall/player": "file:../libs/vidall_player.har"` 本地 HAR 依赖；HAR 产物由 VidAll_Player 仓库构建并通过受控分发提供。
- **VidAll_Player 侧前置工作（阻塞性，不在本仓库实施）**：本变更依赖 VidAll_Player 侧补齐 `time-pos` / `duration` 属性观察并新增 `'position'` PlayerEvent 类型，否则 TV 端无法驱动进度条与续播。该工作作为 Phase 0 前置任务，需在 TV 侧实施开始前完成。

## Capabilities

### New Capabilities

- `mpv-player-backend`: mpv 播放内核的接入与适配，包括 `MpvPlayerAdapter` 的 `IPlayer` 接口实现、`@vidall/player` 事件到 `IPlayer` 回调的映射、XComponent Surface 生命周期绑定，以及与 `PlaybackBackendService` 的集成。
- `player-fallback-preference`: 播放内核回退偏好的存储、读取与设置 UI，包括 AVPlayer 失败时的回退目标选择、播放中强制切换内核的入口、内核切换时的播放位置保持，以及双内核失败时的兜底确认 UX。

### Modified Capabilities

- `playback-backend-service`: `PlayerBackend` 枚举扩展 `'mpv'` 值；`chooseBackend()` 决策逻辑改为"avplayer 优先，失败时读用户偏好在 ijkplayer/mpv 中选择回退目标"；适配器工厂新增 `MpvPlayerAdapter` 分支；XComponent 上下文绑定时序新增 mpv 分支（与 ijkplayer 的 `setIjkContext` 平行，新增 `setMpvSurface` 类入口）。

## Impact

- **新增代码**：
  - `entry/src/main/ets/components/core/player/MpvPlayerAdapter.ets`（新增，~500 行）
  - `entry/src/main/ets/components/core/player/MpvSubtitleBridgeAdapter.ets`（新增，或在现有 `SubtitleBridgeAdapter` 体系中新增 mpv 子类）
  - `entry/libs/vidall_player.har`（新增二进制依赖，由 VidAll_Player 仓库受控分发）
- **修改代码**：
  - `entry/src/main/ets/services/playback/PlaybackBackendTypes.ets`：`PlayerBackend` 类型加 `'mpv'`
  - `entry/src/main/ets/services/playback/PlaybackBackendService.ets`：决策逻辑与工厂分支
  - `entry/src/main/ets/components/core/player/VideoPlayerController.ets`：新增 `setMpvSurface()` 入口、状态投影、内核切换编排
  - `entry/src/main/ets/components/core/player/VideoPlayer.ets`：新增 mpv XComponent 分支
  - `entry/src/main/ets/components/core/player/VideoControls.ets`：播放中菜单加"内核切换"按钮
  - `entry/src/main/ets/utils/AppPreferences.ets`：新增 `PLAYER_FALLBACK` Key
  - `entry/src/main/ets/pages/settings/`：新增"播放内核回退"设置分组
  - `entry/oh-package.json5`：新增 `@vidall/player` 依赖
- **构建/分发**：`entry/build-profile.json5` 需确认 ABI filter 包含 `arm64-v8a`（libmpv.so 仅提供 ARM64 真实产物，x86_64 模拟器为占位不可用真实播放）。
- **跨仓库依赖**：阻塞性依赖 VidAll_Player 仓库补齐 `position` 事件（`time-pos` / `duration` 属性观察）并产出正式 `vidall_player.har`。
- **不影响**：现有 `avplayer` / `ijkplayer` 路径行为完全保持不变；`VidAllPlayerAdapter`（基于 `libvidall_core_player_napi.so` 的旧骨架）继续保留为参考代码，不删除。
- **许可证**：`@vidall/player` 采用 GPL-3.0-or-later，引入后 VidAll_TV 整体分发需符合 GPL-3.0-or-later；SBOM 与 NOTICE 已在 VidAll_Player 侧就绪，TV 侧分发时需一并打包。
