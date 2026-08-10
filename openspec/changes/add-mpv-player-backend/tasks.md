## Phase 0: VidAll_Player 侧前置工作（阻塞性，在 VidAll_Player 仓库执行）

- [x] 0.1 在 `packages/vidall-player/src/main/cpp/napi_init.cpp` 中增加 `mpv_observe_property(player_.get(), 0, "time-pos", MPV_FORMAT_DOUBLE)` 和 `mpv_observe_property(player_.get(), 0, "duration", MPV_FORMAT_DOUBLE)`
- [x] 0.2 在 `packages/vidall-player/src/internal/playerSession.ets` 中把 `time-pos` / `duration` 属性变化映射为 `'position'` PlayerEvent（包含 `positionMs` 和 `durationMs` 字段）并 emit
- [x] 0.3 在 `packages/vidall-player/src/public/types.ets` 的 `PlayerEventType` 中确认 `'position'` 已存在（已存在，只需确保 emit）
- [x] 0.4 构建 `vidall_player.har`：`devecocli build --module vidall_player`
- [x] 0.5 验证 HAR 产物包含 `libs/arm64-v8a/libmpv.so`、`libvidall_player_native.so`、`libc++_shared.so`
- [x] 0.6 将 `vidall_player.har` 通过受控分发提供（拷贝到 VidAll_TV `entry/libs/` 或作为 CI artifact）

## Phase 1: VidAll_TV 基础接入

- [x] 1.1 将 `vidall_player.har` 拷贝到 `entry/libs/vidall_player.har`
- [x] 1.2 在 `entry/oh-package.json5` 的 `dependencies` 中增加 `"@vidall/player": "file:../libs/vidall_player.har"`
- [x] 1.3 确认 `entry/build-profile.json5` 的 `abiFilters` 包含 `arm64-v8a`（libmpv.so 仅 ARM64 真实可用）
- [x] 1.4 新增 `entry/src/main/ets/components/core/player/MpvPlayerAdapter.ets`，实现 `IPlayer` 接口
  - 内部持有 `VidAllPlayer` 实例（通过 `createPlayer()` 创建）
  - 内部持有 `XComponentSurfaceAdapter` 实例
  - 实现 `init()`：`createPlayer()` + `attachSurface()` + `load()`
  - 实现 `play()` / `pause()` / `toggle()` / `release()` / `stop()`
  - 实现 `seek(timeMs)`：转换为 `seekPercent()` 或 `seekRelative()`
  - 实现 `forward(ms)` / `backward(ms)`：转换为 `seekRelative(+sec/-sec)`
  - 实现 `setPlaybackSpeed(speed)`：转换为 `setRate(speed)`
  - 实现 `setSubtitleDelay(delayMs)`：直接透传
  - 实现 `getTrackInfos()`：返回缓存的 `PlayerTrack[]` 转换结果
  - 实现 `selectTrack(trackIndex)`：直接透传 SDK 内部 ID
  - 实现全部回调注册方法（`onReady` / `onPlay` / `onPaused` / `onCompleted` / `onStopped` / `onTimeUpdate` / `onError` / `onUnsupportedFormat` / `onSeekDone` / `onSubtitleUpdate` / `onBuffering`）
  - 实现 `subscribe()` 事件监听，将 `PlayerEvent` 映射为上述回调
- [x] 1.5 在 `PlaybackBackendTypes.ets` 的 `ServicePlayerBackend` 类型中增加 `'mpv'`
- [x] 1.6 在 `PlaybackBackendService.ets` 的适配器工厂中增加 `MpvPlayerAdapter` 分支
- [x] 1.7 在 `VideoPlayerController.ets` 中新增 `setMpvSurface(surfaceId: string)` 入口方法（与 `setIjkContext` / `setNativeContext` 平行）

## Phase 2: XComponent UI 分支

- [x] 2.1 在 `VideoPlayer.ets` 中新增 `backendMode === 'mpv'` 的 XComponent 分支
  - 使用 `XComponentController` 模式（非 `libraryname`）
  - `id: 'mpvPlayerXComponent'`
  - `onLoad` 回调中调用 `controller.setMpvSurface(surfaceId)`
  - 支持 `onAreaChange` 转发到 `XComponentSurfaceAdapter.onSizeChange()`
  - 支持 `onDestroy` 转发到 `XComponentSurfaceAdapter.onDestroy()`
- [x] 2.2 确保 mpv 分支的 XComponent 支持 `renderFit`（复用现有 `toRenderFit` 逻辑）
- [x] 2.3 确保 mpv 分支的触摸/手势事件正常透传（`XComponentController` 模式天然支持，无需透明拦截层）

## Phase 3: 事件映射与状态管理

- [x] 3.1 在 `MpvPlayerAdapter` 中实现 `state` 事件到生命周期回调的映射
  - `'prepared'` → `onReady()`
  - `'playing'` → `onPlay()`
  - `'paused'` → `onPaused()`
  - `'completed'` → `onCompleted()`
  - `'idle'`（stop 后）→ `onStopped()`
  - `'error'` → `onError(error)`
- [x] 3.2 在 `MpvPlayerAdapter` 中实现 `'position'` 事件到 `onTimeUpdate` 的映射
- [x] 3.3 在 `MpvPlayerAdapter` 中实现 `'subtitleText'` 事件到字幕更新路径的映射
  - 调用 `onEmbeddedTimedText` 等价路径（通过 `VideoPlayerController` 注入的回调）
  - 最终驱动 `SubtitleBridgeAdapter` → `SubtitleRenderer`
- [x] 3.4 在 `MpvPlayerAdapter` 中实现 `'buffering'` 事件到 `onBuffering` 的映射
- [x] 3.5 在 `MpvPlayerAdapter` 中实现 seek Promise resolve 到 `onSeekDone` 的映射
- [x] 3.6 在 `MpvPlayerAdapter` 中实现 `'tracks'` 事件缓存与 `getTrackInfos()` 转换
- [x] 3.7 在 `MpvPlayerAdapter` 中实现 PGS/VobSub 图形字幕自动检测与 mpv 内嵌合成切换
- [x] 3.8 在 `MpvPlayerAdapter` 中实现错误分类：`domain === 'media'` 且格式不支持时触发 `onUnsupportedFormat()`

## Phase 4: 用户偏好与设置 UI

- [x] 4.1 在 `AppPreferences.ets` 的 `PrefKey` 中新增 `PLAYER_FALLBACK = 'player_fallback'`
- [x] 4.2 在 `Settings` 页新增"播放内核回退"分组
  - 单选选项：`ijkplayer`（默认）/ `mpv`
  - `mpv` 选项标注"仅支持真机"
  - 选择变更立即持久化到 `AppPreferences`
- [x] 4.3 在 `PlaybackBackendService.chooseBackend()` 中读取 `AppPreferences.PLAYER_FALLBACK` 决定回退目标
- [x] 4.4 在 x86_64 模拟器上选择 `mpv` 时提示"当前设备不支持 mpv 内核，已自动回退到 ijkplayer"

## Phase 5: 播放中菜单与内核切换

- [x] 5.1 在 `VideoControls.ets` 播放中菜单新增"内核切换"按钮
  - 按钮文案显示当前内核名称（"内核：ijkplayer" / "内核：mpv"）
  - 仅在当前后端为 `'ijkplayer'` 或 `'mpv'` 时显示
- [x] 5.2 在 `VideoPlayerController.ets` 中实现 `switchBackend(targetBackend: 'ijkplayer' | 'mpv')` 方法
  - 保存当前 `currentTime` 和 `isPlaying` 状态
  - 调用 `release()` 释放当前内核
  - 更新 `backend` 字段
  - 调用 `initPlayer()` 初始化目标内核
  - 在目标内核 `onReady` 后 `seek(savedTime)` 恢复位置
  - 恢复播放状态（播放/暂停）
- [x] 5.3 切换过程中 UI 显示 loading 状态并禁用所有控制按钮

## Phase 6: 双内核失败兜底 UX

- [x] 6.1 在 `VideoPlayerController.ets` 中实现双内核失败检测逻辑
  - 记录当前失败的内核类型
  - 当 `onError` / `onUnsupportedFormat` 触发且当前后端为回退内核时，进入兜底流程
- [x] 6.2 实现兜底确认对话框
  - 文案："当前内核无法播放此视频，是否尝试使用 [另一内核名称] 播放？"
  - 选项："确认" / "取消"
- [x] 6.3 "确认"分支：强制切换到另一内核，保持当前位置重新加载
- [x] 6.4 "取消"分支：退出播放页，不自动重试

## Phase 7: 回归验证

- [x] 7.1 真机验证：WebDAV 视频播放（H.264 / HEVC / AC-3 / DTS 样本）
- [x] 7.2 真机验证：SMB 视频播放（direct `smb://` 路径）
- [x] 7.3 真机验证：本地文件播放
- [x] 7.4 真机验证：HLS / DASH 流媒体播放
- [x] 7.5 真机验证：4K HEVC 硬解激活（`hardwareDecoding === 'active'`）
- [x] 7.6 真机验证：字幕（SRT 内嵌 / ASS 内嵌 / 外挂 SRT / PGS 图形字幕）
- [x] 7.7 真机验证：音轨切换、倍速、seek、进度条拖动
- [x] 7.8 真机验证：内核切换前后播放位置保持
- [x] 7.9 真机验证：双内核失败兜底流程
- [x] 7.10 回归验证：现有 avplayer / ijkplayer 路径行为不变
