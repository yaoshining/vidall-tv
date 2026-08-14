## 1. PlaybackState 枚举镜像迁移（D1）

- [x] 1.1 新增 `PlaybackState` 枚举（`IDLE/ROUTING/PREPARING/PREPARED/PLAYING/PAUSED/SEEKING/ERROR/RELEASING`）
- [x] 1.2 在 `VideoPlayerController` 新增 `state` 字段与 `transitionTo(state)` 私有方法
- [x] 1.3 在 `initPlayer` 的会话生命周期写入点镜像同步 `state`（进入 ROUTING/PREPARING 等）
- [x] 1.4 在 `onPlayerReady` 镜像同步 `state = PREPARED`
- [x] 1.5 在 `onPlay` / `onPause` 镜像同步 `state = PLAYING/PAUSED`
- [x] 1.6 在 `seek` 镜像同步 `state = SEEKING`（与 `isSeeking` 并存）
- [x] 1.7 在 `handleTerminalPlayerError` / `release` 镜像同步 `state = ERROR/IDLE`
- [x] 1.8 编译 `assembleHap` + 跑 `VideoPlayerController.test.ets`，确认镜像阶段行为不变

## 2. ReloadSession 收敛（D3，风险最低先行）

- [x] 2.1 新增 `ReloadSession` 类（含 token/timeout/resolve/reject）
- [x] 2.2 用 `reloadSession` 字段替换 5 个旧 reload 字段
- [x] 2.3 迁移 `reloadSource` / `resolvePendingReload` / `rejectPendingReload` / `clearPendingReloadState` 到 `ReloadSession`
- [x] 2.4 编译 + 单测，确认 reload 行为不变

## 3. ResumeSession 收敛（D2）

- [ ] 3.1 新增 `ResumeSession` 类（内部按 pending / decision / seek / result 分区）
- [ ] 3.2 迁移 `PendingResumeState` 核心数据（positionMs/shouldResumePlay/sourceKey/reason/captureBackend）与 capture/preserve/consume 生命周期
- [ ] 3.3 迁移自动播放决策 6 字段（pending/prepared × explicit/has/source）到 `ResumeSession.decision`
- [ ] 3.4 迁移 resume seek 7 字段 + 超时兜底 3 字段到 `ResumeSession.seek`
- [ ] 3.5 迁移 `pendingResumeAutoplayResultState` 到 `ResumeSession.result`
- [ ] 3.6 将 `initPlayer` 中 20+ 行续播重置语句收敛为 `resumeSession.reset()` / `resumeSession = null`
- [ ] 3.7 编译 + 单测，确认续播/回退/seek 恢复行为不变

## 4. 状态转换收口（D4）

- [ ] 4.1 把 `fallbackAvPlayerToMpv` 中的状态编排收口到 `transitionTo` + `ResumeSession.capture`
- [ ] 4.2 清理 `seek` / `onPlayerReady` 中散落的状态重置，改为调用对象方法
- [ ] 4.3 编译 + 单测，确认转换语义不变

## 5. 清理旧字段

- [ ] 5.1 确认所有读取方已迁移到 `state` / `resumeSession` / `reloadSession`
- [ ] 5.2 删除旧布尔字段 `isReady/isPlaying/isSeeking/isLoading/hasPrepared` 及已迁移的续播/reload 旧字段
- [ ] 5.3 编译 + 单测，确认无残留引用

## 6. 回归验证

- [ ] 6.1 `assembleHap`（product=default）编译通过
- [ ] 6.2 `UnitTestBuild` 全量单测通过（重点 `VideoPlayerController.test.ets` 48 用例）
- [ ] 6.3 真机回归：AVPlayer 播放、MPV 回退、切集续播、seek 恢复播放、自动下一集
