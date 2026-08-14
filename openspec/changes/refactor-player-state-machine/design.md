## Context

动机见 `proposal.md - Why`。这里只保留解释方案所需的现状与约束。

`VideoPlayerController` 当前是**隐式状态机**，用 30+ 个分散字段（布尔 + 数值 + 可空对象）组合表达逻辑状态，交织 4 个子状态机：

1. **播放会话生命周期**（主流程）：`IDLE → ROUTING → PREPARING → PREPARED → PLAYING ⇄ PAUSED`，含 `SEEKING`、`ERROR`、`RELEASING`。用 `isReady / isPlaying / isSeeking / isLoading / hasPrepared` 分散表达。
2. **播放后端**：`avplayer`（主）→ `mpv`（唯一回退），`forceMpvForNextInit` 一次性标记 + `capturePendingResumeForFallback` 保存进度。
3. **续播（resume）**：三层结构——① `PendingResumeState`（跨后端续播数据）② 自动播放决策 6 字段（pending/prepared × explicit/has/source）③ resume seek 7 字段（`pendingResumeSeek*` + `pendingReadyTrackInit*` + `suppressPlayAfterSeekOnce`）+ 超时兜底 3 字段。
4. **源重载（reload）**：`pendingReloadToken / activeReloadToken / reloadTimeoutId / pendingReloadResolve / pendingReloadReject` 5 字段。

**约束（重构红线）**：以下行为长期验证过，**必须逐字保留语义**，只做「字段收敛」不做「行为重写」：
- `playbackSessionId` 竞态令牌（每次 `initPlayer` 自增，异步回调先校验，忽略过期实例）。
- `consumedReadyResumeToken`（`session:backend`）防同一后端重复 ready 二次消费 resume。
- AVPlayer→MPV 回退语义与 `forceMpvForNextInit` 一次性消费。
- 续播自动播放决策的三种 origin 优先级（`explicit` > `transient` > `compat_override`）。
- resume seek 的超时兜底（`resumeSeekAutoplayFallbackTimer` 1.5s）。
- 已有 Module 4 服务拆分（`PlaybackBackendService` / `SubtitleSessionService` / `AudioTrackRoutingService`）保持不动。

## Goals / Non-Goals

**Goals:**
- 把隐式状态机收敛为显式、单一来源的状态表示，消除 `initPlayer` 里 20+ 行散落的「重置 pending 字段」语句。
- 让「续播」和「reload」各自成为可独立理解、可独立测试的对象。
- 保持 `VideoPlayerController` 对外 public API 与方法语义完全不变（调用方零改动）。

**Non-Goals:**
- 不重写播放/回退/续播的行为逻辑（只收敛状态表示，不改变转换语义）。
- 不拆分 `VideoPlayerController` 成多个文件（本次只做状态收敛；文件拆分是后续独立变更）。
- 不引入新的外部依赖，不改数据库/schema/协议。
- 不改变任何 spec 级行为（本 change 已 `skip_specs: true`）。

## Decisions

### D1：引入显式 `PlaybackState` 枚举（镜像迁移，非一次性替换）

**决策**：新增 `enum PlaybackState { IDLE, ROUTING, PREPARING, PREPARED, PLAYING, PAUSED, SEEKING, ERROR, RELEASING }`，用单一 `state` 字段替代 `isReady/isPlaying/isSeeking/isLoading/hasPrepared` 的组合判断。

**迁移策略（渐进，降低风险）**：先加 `state` 字段与旧字段**镜像同步**（每个旧字段的写入点同步更新 `state`），新代码读 `state`，旧代码暂读旧字段；待所有读取方迁移后，再删除旧字段。这样每一步都可编译、可回滚。

**备选**：一次性删除旧字段全部改用 `state` —— 被否决，因读取方众多（UI、播放器、测试），一次改动面过大、回归风险高。

### D2：收敛「续播」为 `ResumeSession` 对象

**决策**：新增 `ResumeSession` 类，把三层续播字段收敛为单一字段 `resumeSession: ResumeSession | null`。

**字段映射**：

| 现有字段 | 收敛为 |
|---|---|
| `PendingResumeState`（positionMs/shouldResumePlay/sourceKey/reason/captureBackend） | `ResumeSession.pending`（核心数据，保留 capture/preserve/consume 生命周期） |
| `pendingResumeAutoplayDecisionExplicit` + `has...` + `pendingResumeAutoplayDecisionSource` | `ResumeSession.decision.explicit / hasExplicit / source` |
| `preparedResumeAutoplayDecisionExplicit` + `has...` + `preparedResumeAutoplayDecisionSource` | `ResumeSession.decision.prepared / hasPrepared / preparedSource` |
| `preservePendingResumeAutoplayDecisionOnPaused` | `ResumeSession.decision.preserveOnPaused` |
| `pendingResumeSeekInFlight/Source/CaptureBackend/TargetMs/AutoPlay` | `ResumeSession.seek.inFlight/source/captureBackend/targetMs/autoPlay` |
| `pendingReadyTrackInitAfterSeek` + `pendingReadyTrackInitResumePlay` | `ResumeSession.seek.trackInitPending/trackInitResumePlay` |
| `suppressPlayAfterSeekOnce` | `ResumeSession.seek.suppressPlayAfterSeek` |
| `resumeSeekAutoplayFallbackTimer/SessionId/Triggered` | `ResumeSession.seek.fallbackTimer/sessionId/triggered` |
| `pendingResumeAutoplayResultState` | `ResumeSession.result`（观察上下文） |

**理由**：这些字段本质是「一次续播事务」的不同维度，收敛后可把 `initPlayer` 里 20+ 行重置简化为 `resumeSession = null` 或 `resumeSession.reset()`。

**备选**：保持分散字段 —— 被否决，正是本次要消除的技术债。

### D3：收敛「reload」为 `ReloadSession` 对象

**决策**：新增 `ReloadSession` 类，把 5 个 reload 字段（`pendingReloadToken/activeReloadToken/reloadTimeoutId/pendingReloadResolve/pendingReloadReject`）收敛为 `reloadSession: ReloadSession | null`。

**理由**：与 D2 同理，reload 是独立事务，收敛后生命周期清晰。

### D4：状态转换收敛到集中方法（不做独立转换表文件）

**决策**：把 `initPlayer/onPlayerReady/fallbackAvPlayerToMpv/seek/pause/release` 中的状态转换逻辑，收敛到 `ResumeSession` / `ReloadSession` 各自的「状态方法」（如 `capture/consume/preserve/reset`）与 `PlaybackState` 的集中转移函数（如 `transitionTo(state)`），**不引入额外的转换表 DSL**。

**理由**：ArkTS 里引入转换表 DSL 收益低、可读性差；集中到对象方法与单一 `transitionTo` 已能消除散落重置。**备选**（转换表/DSL）被否决。

### D5：竞态令牌保留语义，仅归位

**决策**：`playbackSessionId`、`consumedReadyResumeToken` 保留原语义与取值逻辑，仅在其写入点收口到 `transitionTo` / `ResumeSession` 内。`reloadToken` 移入 `ReloadSession`。

**理由**：这些令牌是异步竞态防护的已验证方案，改动只做「归位」不做「重写」。

## Risks / Trade-offs

- **[回归风险：续播/回退行为]** → 缓解：只收敛字段表示，不改变转换语义；每步镜像迁移可编译可回滚；用现有 `VideoPlayerController.test.ets`（48 用例）+ 真机回归「MPV 回退、切集续播、seek 恢复播放」兜底。
- **[镜像迁移期间字段冗余]** → 缓解：短期容忍 `state` 与旧字段并存；迁移完成（所有读取方切到 `state`）后立即删除旧字段，避免长期双源。
- **[ResumeSession 收敛引入新对象复杂度]** → 缓解：`ResumeSession` 内部按 pending/decision/seek/result 分区，保持与现有语义一一对应，不合并逻辑。
- **[行为不变难以静态证明]** → 缓解：以「逐字保留语义」为重构红线，任何可疑的语义差异都标注为 Open Question 或回退到保守写法。

## Migration Plan

1. **D1 镜像**：新增 `PlaybackState` 枚举与 `state` 字段；在 `initPlayer/onPlayerReady/onPlay/onPause/seek/release/fallback/handleTerminalPlayerError` 的现有写入点同步 `state`（与旧字段并存）。编译 + 全量单测通过。
2. **D3 先行（风险最低）**：收敛 `ReloadSession`，删 5 个旧字段。编译 + 单测。
3. **D2 收敛续播**：新增 `ResumeSession`，把三层续播字段迁移进去，`initPlayer` 的重置语句收敛为 `resumeSession.reset()`。编译 + 单测。
4. **D4 收口**：把状态转换集中到 `transitionTo` 与对象方法，清理散落重置。
5. **清理旧字段**：确认所有读取方迁移后，删除 `isReady/isPlaying/isSeeking/isLoading/hasPrepared` 等旧字段。
6. **回归**：`assembleHap` + `UnitTestBuild` + 真机验证「AVPlayer 播放 / MPV 回退 / 切集续播 / seek 恢复 / 自动下一集」。

**回滚**：每步独立 commit，任一步失败可单独 revert 该步，不影响已完成的步。

## Open Questions

（无。状态机梳理已完成，字段映射与迁移顺序已明确；不存会影响方案或任务拆分的未决问题。）
