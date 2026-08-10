## Context

VidAll_TV 当前已具备多后端播放器架构（`avplayer` / `ijkplayer` / `ffmpeg` / `native`），通过 `PlaybackBackendService` 统一编排后端选择、适配器生命周期与 fallback 编排，`VideoPlayerController` 退化为 façade。`VideoPlayer.ets` 已存在两条 XComponent 分支：avplayer 用 `XComponentController` 模式拿 `surfaceId`，ijkplayer 用 `libraryname='ijkplayer_napi'` 模式由 native hook 接管。

VidAll_Player 仓库的 `@vidall/player` HAR（候选 `003-libmpv-player-har`）已通过 G1/G2/G3 门禁（2026-08-07 Go），公开入口为 `createPlayer()` + `VidAllPlayer` 接口，配套 `XComponentSurfaceAdapter` 处理 XComponent 生命周期。底层 mpv 通过 `mpv_observe_property` 观察了 `pause` / `track-list` / `sub-text` / `video-params` / `audio-params` / `video-bitrate` / `audio-bitrate` / `hwdec-current` / `dwidth` / `dheight` 等属性，但**未观察 `time-pos` / `duration`**，导致 PlayerSession 无法 emit `'position'` 事件，TV 端无法驱动进度条。

## Goals / Non-Goals

**Goals:**

- 在 `PlaybackBackendService` 中新增 `'mpv'` 后端，与 `ijkplayer` 并列作为 AVPlayer 失败时的回退选项。
- `MpvPlayerAdapter` 完整实现 `IPlayer` 接口，将 `@vidall/player` 事件流映射为 `IPlayer` 回调。
- `VideoPlayer.ets` 新增 mpv XComponent 分支，使用 `XComponentController` + `XComponentSurfaceAdapter` 模式。
- 用户可在设置中选择回退内核（ijkplayer / mpv），选择持久化。
- 播放中可通过菜单强制切换 ijkplayer ↔ mpv，切换时保持播放位置。
- 字幕默认由 TV 端 `SubtitleBridgeAdapter` 绘制，mpv 仅通过 `subtitleText` 事件提供纯文本；PGS/VobSub 图形字幕由 mpv 内嵌合成兜底。
- 双内核失败时提供用户可确认的兜底 UX，不直接报错退出。

**Non-Goals:**

- 不删除或修改现有 `avplayer` / `ijkplayer` 路径的任何行为。
- 不删除 `VidAllPlayerAdapter`（旧 `libvidall_core_player_napi.so` 骨架），保留为参考。
- 不在本仓库修改 VidAll_Player 侧代码；`position` 事件补齐是 VidAll_Player 侧的前置任务。
- 不实现 mpv 的截图、缓存、AI 画质增强等高级功能（这些在 `@vidall/player` 当前版本中标记为 `FEATURE_UNSUPPORTED`）。
- 不处理 x86_64 模拟器上的真实播放（libmpv.so 仅 ARM64 真实可用）。

## Decisions

### D1: XComponent 绑定模式 — `XComponentController` 而非 `libraryname`

**决策**：mpv 分支使用 `XComponentController` 模式（与 avplayer 相同），而非 ijkplayer 的 `libraryname` 模式。

**理由**：
- `@vidall/player` 的 `XComponentSurfaceAdapter` 设计为接收 `componentId` + `generation` + `width` + `height`，由 SDK 内部通过 `attachSurface` 管理 NativeWindow 生命周期。这与 `XComponentController.getXComponentSurfaceId()` 的模式天然匹配。
- `libraryname` 模式是 ijkplayer 的遗留设计（native 层直接 hook XComponent），mpv 不需要。
- `XComponentController` 模式支持 `onClick` / `gesture` 透传，不需要像 ijkplayer 那样叠加透明触摸拦截层。

**替代方案**：复用 ijkplayer 的 `libraryname` 模式 → 不可行，`@vidall/player` 的 native bridge 不通过 `libraryname` hook XComponent。

### D2: 字幕渲染 — TV 端主导 + mpv 图形字幕兜底

**决策**：mpv 后端的字幕默认由 TV 端 `SubtitleBridgeAdapter` 绘制，mpv 仅作为文本提供者（`subtitleText` 事件）；PGS/VobSub 图形字幕由 mpv 内嵌合成兜底。

**理由**：
- TV 端已有完整的字幕设置 UI（字体、大小、颜色、延迟、语言偏好、OpenSubtitles 下载），全部围绕 `SubtitleRenderer` 设计。
- `subtitleText` 事件已就绪（mpv `sub-text` 属性观察），文本已剥除 ASS/SRT 标签，可直接复用现有 `IjkSubtitleBridgeAdapter.onEmbeddedTimedText()` 路径。
- PGS/VobSub 是图形字幕，`subtitleText` 无法提供文本，必须让 mpv 合成到视频帧。

**实现**：`MpvPlayerAdapter` 在 `load()` 时默认不选中任何字幕轨（`selectTrack('subtitle', null)`），仅监听 `subtitleText` 事件；当检测到 `track.kind === 'subtitle'` 且 `codec` 为 `hdmv_pgs_subtitle` 或 `vobsub` 时，自动选中该轨道让 mpv 合成。

### D3: 轨道 ID 映射 — 绕过 ffprobe preset，直接使用 SDK 枚举

**决策**：`MpvPlayerAdapter.getTrackInfos()` 返回的 `TrackInfo.trackIndex` 使用 `@vidall/player` 的 `PlayerTrack.id`（SDK 内部 ID），而非 ffprobe 流索引。

**理由**：
- `@vidall/player` 的 `selectTrack(kind, id)` 要求使用 SDK 内部 `PlayerTrack.id`，该 ID 由 SDK 在 `tracks` 事件中分配，与 ffprobe 流索引无对应关系。
- 现有 `IjkPlayerAdapter` 使用 ffprobe preset 是因为 ijkplayer 的 `selectTrack` 需要流索引；mpv 不需要。
- 简化映射：Adapter 内部缓存最近一次 `tracks` 事件的 `PlayerTrack[]`，`getTrackInfos()` 直接转换，`selectTrack` 直接透传。

**影响**：`VideoPlayerController` 中基于 ffprobe preset 的音轨/字幕轨预置逻辑（`presetAudioTracks` / `presetSubtitleTracks`）在 mpv 后端下不再使用，改为完全依赖 SDK 的 `tracks` 事件。

### D4: 位置轮询 — 依赖 Player 侧补 `position` 事件，TV 侧不 hack

**决策**：`MpvPlayerAdapter` 的 `onTimeUpdate` 完全由 `@vidall/player` 的 `'position'` 事件驱动，TV 侧不实现任何轮询 hack。

**理由**：
- `seekRelative(0)` 有副作用（触发 seek 操作），`getFrameData()` 是截图不是位置，均不可行。
- 正确做法是在 VidAll_Player 侧补 `mpv_observe_property("time-pos")` + `mpv_observe_property("duration")`，映射为 `'position'` PlayerEvent。
- 该改动在 Player 侧约 20 行 C++ + 10 行 ArkTS，是 Phase 0 的阻塞性前置任务。

### D5: 后端选择逻辑 — avplayer 优先，回退目标由用户偏好决定

**决策**：`PlaybackBackendService.chooseBackend()` 的决策逻辑改为：

```
if (avplayer 能播) → 'avplayer'
else if (AppPreferences.PLAYER_FALLBACK === 'mpv') → 'mpv'
else → 'ijkplayer'
```

**理由**：
- 保持 AVPlayer 作为系统级首选不变（硬解兼容性最好）。
- 用户设置仅控制"AVPlayer 不行时，用 ijkplayer 还是 mpv"。
- `UnsupportedFormatFallback` 类型扩展为 `'ijkplayer' | 'mpv'`。

### D6: 内核切换 — 播放中强制切换，保持位置

**决策**：`VideoControls` 播放中菜单新增"内核切换"按钮，点击后强制在当前 `ijkplayer ↔ mpv` 之间切换，切换时记录当前位置并在新内核 prepare 后 seek 回原位置。

**实现**：
- `VideoPlayerController.switchBackend(targetBackend: 'ijkplayer' | 'mpv')` 方法：保存 `currentTime`，调用 `release()`，更新 `backend`，重新 `initPlayer()`，在新内核 `onReady` 后 `seek(savedTime)`。
- 切换过程中 UI 显示 loading 状态，禁用所有控制按钮。

### D7: 双内核失败兜底 — 用户确认后切换

**决策**：当当前回退内核（如 mpv）也播放失败时，不直接报错退出，而是弹出确认对话框：

```
"当前内核无法播放此视频，是否尝试使用 [ijkplayer/mpv] 播放？"
[确认] → 强制切换到另一内核重试
[取消] → 退出播放页
```

**理由**：给用户最后一次机会，避免直接退出导致的不良体验。

### D8: HAR 依赖方式 — `file:` 本地依赖，不上 OHPM

**决策**：`entry/oh-package.json5` 使用 `"@vidall/player": "file:../libs/vidall_player.har"` 本地文件依赖。

**理由**：
- VidAll_Player 明确禁止上传 OHPM 直至跨设备复现基线建立。
- `file:` 依赖是 HarmonyOS 标准做法，与现有 `libvidall_core_player_napi.so` 的引入方式一致。
- HAR 由 VidAll_Player 仓库构建后通过受控分发（git submodule / 手动拷贝 / CI artifact）提供。

## Risks / Trade-offs

| 风险 | 缓解措施 |
|------|----------|
| `@vidall/player` 未 emit `position` 事件，TV 侧进度条不工作 | Phase 0 阻塞性前置：VidAll_Player 侧补 `time-pos` / `duration` 观察并 emit `'position'` 事件；未补齐前不启动 TV 侧实施 |
| mpv 的 `selectTrack` 使用 SDK 内部 ID，与现有 `presetAudioTracks` / `presetSubtitleTracks` 体系不兼容 | `MpvPlayerAdapter` 完全绕过 preset 体系，直接消费 `tracks` 事件；`VideoPlayerController` 在 mpv 后端下跳过 preset 注入逻辑 |
| mpv 字幕默认不渲染（TV 端绘制），但用户可能期望 mpv 内嵌字幕"开箱即用" | 在设置中增加说明文案；PGS/VobSub 自动切换到 mpv 合成，无需用户干预 |
| 内核切换时位置保持可能因新内核 prepare 时间差异导致偏移 | 切换前记录 `currentTime`，新内核 `onReady` 后 `seek(savedTime)`；接受 ±1s 内的偏差 |
| `vidall_player.har` 体积 ~22MB，增加包体积 | 接受；libmpv.so 本身 ~53MB，已做 strip；后续可考虑动态下发 |
| GPL-3.0-or-later 许可证对 VidAll_TV 分发的影响 | VidAll_Player 侧已提供完整 SBOM / NOTICE / 许可证审计；TV 侧分发时一并打包 `release/licenses/NOTICE` |
| x86_64 模拟器无法真实播放（`VIDALL_MPV_AVAILABLE=0`） | 在设置 UI 中标注"mpv 内核仅支持真机"；模拟器上选择 mpv 时提示并自动回退 ijkplayer |

## Migration Plan

1. **Phase 0（VidAll_Player 侧，阻塞性）**：补齐 `position` 事件，构建 `vidall_player.har`，通过受控分发提供。
2. **Phase 1（TV 侧基础接入）**：引入 HAR 依赖，实现 `MpvPlayerAdapter`，注册到 `PlaybackBackendService`。
3. **Phase 2（设置与菜单）**：新增设置项与播放中菜单入口。
4. **Phase 3（事件映射）**：完成 `IPlayer` 全回调映射。
5. **Phase 4（兜底 UX）**：实现双内核失败确认对话框。
6. **Phase 5（回归验证）**：真机全场景验证。

**回滚策略**：`AppPreferences.PLAYER_FALLBACK` 默认值为 `'ijkplayer'`，用户未主动切换时行为与现有版本完全一致；删除 HAR 依赖并回退代码即可完全回滚。

## Open Questions

- `MpvPlayerAdapter` 是否需要支持 `getFrameData()`（截图）？当前 `@vidall/player` 的 `getFrameData()` 仅在 SW 渲染路径下有效，GL 路径下返回 `null`。截图功能在 TV 端的使用场景待确认。
- mpv 的 `hardwareDecoding` 选项（`'auto' | 'disabled'`）是否需要在 TV 设置中暴露？当前决策使用默认 `'auto'`，后续可根据用户反馈增加设置项。
