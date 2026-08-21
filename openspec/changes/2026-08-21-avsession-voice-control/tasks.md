## 1. AVSession 服务封装

- [x] 1.1 新增 `services/avSession/AvSessionService.ets`：`init()` 创建并激活 AVSession（`createAVSession(context, 'VidAll TV', 'video')` + `activate()`）
- [x] 1.2 注册固定播放控制命令监听：`play` / `pause` / `stop` / `seek` / `setSpeed`，通过 `onCommand(cmd, args?)` 回调透出
- [x] 1.3 实现状态同步：1s 定时器调用 `setAVPlaybackState`（播放/暂停/缓冲状态 + `PlaybackPosition{elapsedTime, updateTime}` + 倍速），标题/时长变化时调用 `setAVMetadata`
- [x] 1.4 实现状态去重：`state|position|speed` 与 `title|duration` 键不变时不发起 IPC 写
- [x] 1.5 实现 `setLaunchAbility`：通过 `wantAgent` 配置点击播控卡片拉起 `EntryAbility`（bundleName 取自 `context.applicationInfo.name`）
- [x] 1.6 实现 `destroy()`：`off` 全部命令监听并 `destroy()` 会话，静默失败不抛异常

## 2. PlayerPage 集成

- [x] 2.1 `pages/player/index.ets` 新增 `avSessionService` 字段，`aboutToAppear` 调用 `initAvSession()` 创建服务
- [x] 2.2 `initAvSession()` 注入 `onCommand` 回调：`play` → `controller.play()`、`pause`/`stop` → `controller.pause()`、`seek` → `controller.seek(args, 'avsession_seek')`、`setSpeed` → `controller.setPlaybackSpeed(args)`
- [x] 2.3 `initAvSession()` 注入 `getState` 快照：从 controller 读取标题/`isPlaying`/`isLoading`/`currentTime`/`duration`/`playbackSpeed`
- [x] 2.4 `aboutToDisappear` 调用 `avSessionService.destroy()` 并置空
- [x] 2.5 切集（`applyPlayerPageParam`）后调用 `refreshMetadata()` 立即刷新元数据

## 3. 构建与真机验证

- [x] 3.1 `hvigorw assembleHap` 编译通过（BUILD SUCCESSFUL，无新增 ArkTS 警告）
- [x] 3.2 hdc 安装到华为智慧屏 MateTV Pro（EDIS-790A，API 24）并启动应用
- [x] 3.3 真机语音验证：播放视频后对小艺说「暂停」「播放/继续播放」，确认播放器响应
- [ ] 3.4 真机验证遥控器播放/暂停键与系统媒体中心显示（标题、进度）与拖动
- [ ] 3.5 抓取 hilog 确认 `AVSession command: play/pause` 命令链路日志

## 4. 媒体封面同步

- [x] 4.1 `AvSessionSyncState` 新增 `mediaImage`（PixelMap | file:// URI），`syncMetadataNow` 写入 `AVMetadata.mediaImage`
- [x] 4.2 元数据去重键扩展为 `title|duration|mediaImage`（PixelMap 用固定标记 + 宿主强制刷新）
- [x] 4.3 `PlayerPageParam` 新增 `posterLocalPath` / `posterUrl` / `backdropLocalPath` / `backdropUrl` 可选字段
- [x] 4.4 `PlayerPage` 实现 `loadMediaImageForAvSession`：本地路径 → file:// URI；网络 URL → http 下载 + ImageSource 解码为 480×270 PixelMap；无封面优雅降级
- [x] 4.5 切集 param（`buildMediaLibraryEpisodeSwitchParam` / `buildFileExplorerEpisodeSwitchParam`）透传封面字段
- [x] 4.6 各播放入口透传封面：ContinueWatchCard / MovieDetailPage / SeriesDetailPage / SeasonDetailPage / ServerMediaDetailPage / ServerSeasonDetailPage / MediaLibraryTab / PlayHistoryPage
- [ ] 4.7 真机验证：播放有海报的视频，确认系统媒体中心展示海报缩略图
