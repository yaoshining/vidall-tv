## Why

`VideoPlayerController`（2553 行、93 个方法、30+ 状态字段）用大量分散的布尔/数值/可空字段隐式表达播放器状态机，其中「续播（resume）」子状态机用 6 个字段表达一个决策、用 7+ 个字段表达一次 seek。这种结构导致 `initPlayer` 里散落 20+ 行「重置 pending 字段」语句、三套竞态令牌并存，是播放器核心维护成本高、切集/回退类 bug 反复出现的根因。现在收敛状态机，可降低后续改动与回归风险。

## What Changes

- 引入显式播放状态枚举（`IDLE/ROUTING/PREPARING/PREPARED/PLAYING/PAUSED/SEEKING/ERROR/RELEASING`），替代 `isReady/isPlaying/isSeeking/isLoading/hasPrepared` 的分散组合。
- 将「续播」状态（`PendingResumeState` + 自动播放决策三层 + resume seek 字段）收敛为单一 `ResumeSession` 对象。
- 将「源重载」状态（`pendingReloadToken` 等 5 个字段）收敛为单一 `ReloadSession` 对象。
- 将分散在 `initPlayer/onPlayerReady/fallbackAvPlayerToMpv/seek/pause/release` 中的状态转换逻辑收敛为显式状态转换。
- **纯重构，行为不变**：不改变播放、AVPlayer→MPV 回退、续播定位、续播自动播放决策、竞态防护（`playbackSessionId` / `consumedReadyResumeToken` / `reloadToken`）等任何可观察行为。

## Capabilities

### New Capabilities

（无。本变更为纯重构，不引入新的 spec 级能力。）

### Modified Capabilities

（无。本变更不改变任何现有 spec 描述的行为；已通过 `.openspec.yaml` 的 `skip_specs: true` 声明。）

## Impact

- **代码**：`entry/src/main/ets/components/core/player/VideoPlayerController.ets`（主要），以及可能新增的状态/会话值对象文件（如 `PlaybackState`、`ResumeSession`、`ReloadSession`）。
- **测试**：`entry/src/test/VideoPlayerController.test.ets`（48 个用例）需保持通过；可能新增状态机转换的单测。
- **依赖**：无新增外部依赖。
- **系统**：无协议/数据库/schema 变更。
- **风险**：播放器核心，需真机回归验证「AVPlayer 播放、MPV 回退、切集续播、seek 恢复播放、自动下一集」等入口。
