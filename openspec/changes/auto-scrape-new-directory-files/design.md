## Context

See proposal.md — Why / What Changes. 当前目录保存流程（`FileSourceModel.saveDirectoriesWithCleanup()`）仅写入配置并刷新 UI，不触发扫描或刮削。全局刮削通过 `MediaLibraryTab.runScan()` 以 UI 驱动方式调用 `VideoScannerUtil.scan()` 扫描所有文件源的所有目录，再由 `ScrapeTaskQueue` 执行刮削。文件夹局部刮削跳过扫描阶段，直接从数据库解析已有视频。两者均不满足"目录保存后仅对新增目录定向扫描+仅刮削首次入库视频"的需求。

现有基础设施：
- `ScrapeTaskQueue`：支持 `scanning`/`preparing`/`scraping` 三阶段，但 `scanning` 仅全局任务使用且由 UI 驱动
- `VideoScannerUtil.scan()`：扫描所有文件源，无单源单目录 API
- `WebDAVAdapter.scan(path, opts)` / `SMBAdapter.scan(path, opts)`：已支持按目录路径枚举
- `VideoDao.upsertVideo()`：先 `getVideoByPath()` 判存否再 INSERT/UPDATE，但不返回 insert-vs-update 区分
- `normalizeScrapeDirectoryPath()`：统一路径规范化
- `ScrapeTaskSnapshot`：`@ObservedV2` 任务模型，含 `phase`/`scanContext`/`request`/`result`
- `@ObservedV2`/`@Trace` 模式为项目标准响应式数据传播方式

## Goals / Non-Goals

**Goals:**
- 目录保存后自动触发定向扫描+刮削，严格限定范围
- 复用现有 queue/adapter/scan 基础设施，最小化新增代码路径
- 首次入库判据以 upsert 前 DB 记录是否存在为准，与元数据状态解耦

**Non-Goals:**
- 不修改全局扫描流程
- 不新增 UI 组件（设置开关、进度页等）
- 不实现跨进程恢复
- 不修改 `ScrapeModeFilter` 的 incremental/fix-missing/overwrite 语义——自动刮削使用独立的 videoIds 筛选路径

## Decisions

### D1: 保存前后规范化路径差集的契约

**选择**：在 `DirectorySelectorState.buildSaveEntries()` 构建结果时，同步计算 `addedPaths: Set<string>` 和 `removedPaths: Set<string>`，作为 `DirectoriesSavedEvent` 的字段随保存调用传入。

**计算方式**：
1. 保存前：从 `FileSourceDao.getDirectoriesForSource(sourceId)` 读取已有目录路径集合 `beforePaths`
2. 保存后：从 `buildSaveEntries()` 返回的 `FileSourceDirectory[]` 提取路径集合 `afterPaths`
3. 对两个集合所有路径调用 `normalizeScrapeDirectoryPath()` 规范化
4. `addedPaths = afterNormalized - beforeNormalized`；`removedPaths = beforeNormalized - afterNormalized`
5. 仅当 `addedPaths.size > 0` 时发出事件

**理由**：差集计算在保存调用点最可靠——此时 before/after 数据均可用，且与保存事务在同一调用链，避免异步竞态。规范化复用现有 `normalizeScrapeDirectoryPath()` 保证与 queue 的 scopeId 一致。

**替代方案**：在 `FileSourceDao.saveDirectoriesForSource()` 内部计算差集——需改动 DAO 层职责，且 DAO 无文件源类型信息；放弃。

### D2: 定向 Scanner API 与全库 scan 隔离

**选择**：新增 `VideoScannerUtil.scanDirectories(context, sourceId, directoryPaths, options)` 方法，严格限定为单个 sourceId + 指定目录列表。

**设计**：
```
scanDirectories(context, sourceId, directoryPaths, options):
  1. 加载 sourceId 对应的 FileSource 及其 adapter（WebDAV/SMB）
  2. 对 directoryPaths 中每个路径调用 adapter.scan(path, scanOptions)
  3. 聚合结果，按 filePath 去重
  4. 不调用 resetVideoUpdatedFlags()（全局扫描专用）
  5. 不调用 deleteGhostVideosForSources()（不做全库 ghost cleanup）
  6. 不调用 cleanupOrphanedScrapeInfo()
  7. 返回 ScanResult
```

**隔离保证**：
- 不遍历所有文件源，仅加载指定 sourceId
- 不运行任何全局清理逻辑（ghost cleanup / orphan cleanup）
- adapter.scan() 仅枚举给定目录及其子目录，不扩展

**理由**：复用 adapter 的单目录扫描能力（已支持），避免修改现有 `scan()` 全局方法。新方法职责单一，无法误触全库逻辑。

**替代方案**：在 `scan()` 中加 filter 参数——增加全局扫描复杂度且有误用风险；放弃。

### D3: upsert 前可靠判定 DB 不存在并汇总 newlyInsertedVideoIds

**选择**：修改 `VideoDao.upsertVideo()` 返回 `VideoUpsertResult { id: number, wasNewlyInserted: boolean }`，在 `getVideoByPath()` 查询阶段即确定 insert-vs-update。

**实现**：
```
upsertVideo(entity):
  existing = getVideoByPath(entity.filePath)
  if existing:
    store.update(...)
    return { id: existing.id, wasNewlyInserted: false }
  else:
    INSERT OR IGNORE
    newId = query back
    return { id: newId, wasNewlyInserted: true }
```

定向扫描流程在扫描回调中收集 `newlyInsertedVideoIds: number[]`：
```
for each directory in directoryPaths:
  try:
    result = adapter.scan(path, scanOptions)
    for each videoFile in result.videos:
      upsertResult = db.upsertVideo(videoEntity)
      if upsertResult.wasNewlyInserted:
        newlyInsertedVideoIds.push(upsertResult.id)
    succeededDirectories.push(path)
  catch:
    failedDirectories.push({ path, error })
```

**理由**：upsert 内部已有 `getVideoByPath()` 判存否，仅在返回值中暴露 insert/update 区分，零额外查询开销。这是首次入库判据的唯一可信来源——不依赖刮削关联、wasProcessed、元数据完整度。

**替代方案**：
- 在扫描前批量预查所有路径——无法覆盖扫描过程中并发变更的场景，且增加查询量；放弃
- 使用 `updatedInLastScan` 标记——这是全局扫描专用的字段，定向扫描不重置该字段；放弃

### D4: 父子目录/视频去重

**选择**：两层去重——目录级保留全部新增路径（不裁剪父子关系），视频级按 filePath 去重。

**目录级**：`addedPaths` 中 `/media` 和 `/media/movies` 同时存在时均纳入扫描范围，因为两者可能对应不同用户选择语义。adapter 各自枚举，子目录文件可能被父目录扫描覆盖。

**视频级**：聚合时以 `Map<string, number>(filePath → videoId)` 去重，同一视频仅首次 upsert 时 `wasNewlyInserted=true`，后续 upsert 返回 `wasNewlyInserted=false`，自然不会重复纳入 `newlyInsertedVideoIds`。

**理由**：adapter 的递归扫描会自动遍历子目录，但不同目录的扫描结果通过 filePath 去重保证视频唯一。不裁剪目录路径是因为用户可能仅选择子目录而不选父目录。

### D5: 部分目录失败结果模型

**选择**：扩展 `ScrapeScanResult` 为包含成功/失败目录明细的结构：

```
interface DirectedScanResult {
  succeededDirectories: string[]          // 扫描成功的目录路径
  failedDirectories: FailedDirectory[]    // 扫描失败的目录
  newlyInsertedVideoIds: number[]         // 所有成功目录中首次入库的 videoId
  totalFilesScanned: number
}

interface FailedDirectory {
  directoryPath: string
  error: ErrorInfo
}
```

**任务终态判定**：
- `failedDirectories.length === 0` → scanning 完成，`markTaskReady(taskId)` 进入 preparing
- `failedDirectories.length > 0 && succeededDirectories.length > 0` → 成功目录的 videoIds 继续刮削，失败目录记入 `task.result.failedDirectories`，最终 partial-failure
- `failedDirectories.length > 0 && succeededDirectories.length === 0` → 直接 `markTaskFailed(taskId)`

**理由**：部分失败是定向扫描的常见场景（某目录网络故障），需精确记录哪些目录失败以支持专用重试。成功目录不应被失败目录阻塞。

### D6: scanning 任务携带可重试上下文

**选择**：在 `ScrapeTaskSnapshot` 的 `request.scope` 中使用扩展的 `FolderScrapeScope`，并在 `result` 中新增 `directedScanContext` 字段存储重试所需信息。

```
// 扩展 FolderScrapeScope，增加触发来源标记
interface AutoScrapeFolderScope extends FolderScrapeScope {
  kind: 'folder'
  sourceId: number
  directoryPath: string        // 逗号拼接的多目录路径（规范化后）
  displayName: string
  autoTriggered: true          // 标识自动触发
}

// 重试上下文，存入 task.result
interface DirectedScanRetryContext {
  sourceId: number
  originalDirectoryPaths: string[]   // 原始全部新增目录
  failedDirectoryPaths: string[]     // 重试时仅需这些目录
}
```

**理由**：复用 `FolderScrapeScope` 使 queue 和 TopBar 无需区分自动/手动任务。`autoTriggered` 标记供重试执行器区分重试逻辑。重试上下文存入 `result` 而非 `scope`，因为重试范围取决于运行时失败结果。

**替代方案**：新增 `ScrapeScopeKind` 类型 `'auto-directory'`——需改动 `scrapeScopeId()`/`ScrapeScopeResolver` 等多处，侵入性过大；放弃。

### D7: 失败/部分失败重试执行器归属

**选择**：新增 `AutoScrapeRetryExecutor`，独立于 `ScrapeTaskQueue.retry()` 的通用重试路径。

**设计**：
```
AutoScrapeRetryExecutor.retry(taskId):
  1. 从原 task.result 中提取 DirectedScanRetryContext
  2. 构建新的 ScopedScrapeRequest:
     - scope: AutoScrapeFolderScope { sourceId, directoryPath: retryPaths.join(','), autoTriggered: true }
     - mode: 'incremental'
     - candidateStrategy: 'automatic'
     - videoIds: undefined (重新扫描获取)
  3. 调用 queue.enqueue(request, { phase: 'scanning' })
  4. 启动定向扫描: scanDirectories(context, sourceId, retryPaths, ...)
  5. 扫描回调更新新任务进度
  6. 扫描完成/失败更新新任务状态
```

**关键区别于 `Queue.retry()`**：
- `Queue.retry()` 仅构造新 request 入队，不执行扫描——它假定视频已在 DB 中，直接从 DB 解析后刮削
- `AutoScrapeRetryExecutor` 需要先执行定向扫描再入队——因为失败目录的视频可能尚未入库
- `Queue.retry()` 的 partial-failure 重试仅包含 `failedVideoIds`——不适用于扫描失败场景（无 videoIds 可重试）

**理由**：扫描失败的重试本质是"重新执行定向扫描+刮削"，而非"重新刮削已知视频"。这要求独立的执行器管理扫描-入队-进度更新全流程，不能简单放开 `Queue.retry()` 的禁止判断。

**替代方案**：扩展 `Queue.retry()` 支持 scanning 阶段重试——需修改 queue 核心逻辑，且重试语义与现有 retry（已知 videoIds 重刮）完全不同，增加复杂度；放弃。

### D8: 零目标完成

**选择**：定向扫描完成后，若 `newlyInsertedVideoIds.length === 0`：
1. `markTaskReady(taskId)` 进入 preparing
2. `ScopedScrapeService.execute()` 解析 scope 得到 0 个目标
3. 直接标记为 `completed`，`progress = { completed: 0, total: 0, succeeded: 0, failed: 0, cancelled: 0 }`

**理由**：复用现有 `ScopedScrapeService` 的零目标处理路径——当 resolve + filter 后 targets 为空时，任务自然完成。无需特殊逻辑，仅需确保扫描阶段正确转入 preparing。

### D9: 取消语义

**选择**：复用 queue 现有取消机制。

- **scanning 阶段取消**：用户取消时 `task.status = 'cancelled'`；扫描回调检查 `task.status`，若已取消则丢弃后续进度更新且不调用 `markTaskReady()`；不执行任何目标写入
- **preparing/scraping 阶段取消**：与现有手动任务一致——仅等待中任务可取消，进行中任务不提供强制中断

**实现**：定向扫描的 `onScanProgress` 回调中增加 `task.status === 'cancelled'` 前置检查。

### D10: 内存态不跨进程恢复

**选择**：自动刮削的触发状态和定向扫描上下文均为内存态，不持久化。

- `DirectoriesSavedEvent` 不写入数据库
- `AutoScrapeRetryExecutor` 的重试上下文仅存于 `ScrapeTaskSnapshot.result`（`@ObservedV2` 内存对象）
- 应用重启后：未完成的 scanning 阶段任务因进程重建而丢失，不补跑
- 用户可通过手动刮削处理任何遗漏

**理由**：符合 spec 要求"不做跨进程恢复"。`ScrapeTaskStore` 的 `snapshots` 本身就是内存态，进程退出即丢失，无需额外清理。

### D11: 事件触发机制

**选择**：在 `FileSourceModel.saveDirectoriesWithCleanup()` 完成后，直接调用 `AutoScrapeTrigger.onDirectoriesSaved(event)`，不走 `emitter` 跨进程事件。

```
DirectoriesSavedEvent {
  sourceId: number
  fileSourceType: FileSourceType
  addedDirectoryPaths: string[]    // 已规范化
}
```

**调用点**：
```
FileSourceModel.saveDirectoriesWithCleanup():
  // ... existing save logic ...
  // 差集计算 (D1)
  if addedPaths.size > 0:
    AutoScrapeTrigger.onDirectoriesSaved({ sourceId, fileSourceType, addedDirectoryPaths: [...addedPaths] })
```

**理由**：保存与触发在同一进程同一线程，无需跨进程通信。`AutoScrapeTrigger` 异步执行不阻塞保存 UI。使用直接调用而非 `emitter` 避免 event ID 管理和反序列化开销。

**替代方案**：使用 `emitter.emit()` / `emitter.on()`——增加序列化复杂度且无跨进程需求；放弃。

### D12: 自动刮削任务编排流程（端到端）

```
1. 用户保存目录 → buildSaveEntries() 计算 addedPaths
2. saveDirectoriesWithCleanup() 完成
3. if addedPaths.size > 0:
   AutoScrapeTrigger.onDirectoriesSaved(event)
4. AutoScrapeTrigger (异步):
   a. 构建 AutoScrapeFolderScope { sourceId, directoryPath: paths.join(','), autoTriggered: true }
   b. 构建 ScopedScrapeRequest { scope, mode: 'incremental', candidateStrategy: 'automatic' }
   c. queue.enqueue(request, { phase: 'scanning' }) → 得到 taskId
   d. 调用 scanDirectories(context, sourceId, paths, {
        onScanProgress: (progress, scanCtx) => queue.updateScanProgress(taskId, progress, scanCtx),
        onScanComplete: (result: DirectedScanResult) => this.handleScanComplete(taskId, result),
        onScanError: (error) => queue.markTaskFailed(taskId)
      })
5. handleScanComplete(taskId, result):
   a. if result.failedDirectories.length === 0:
      queue.markTaskReady(taskId) → 进入 preparing → queue 调度 ScopedScrapeService.execute()
   b. if result.failedDirectories.length > 0 && result.succeededDirectories.length > 0:
      将 DirectedScanRetryContext 存入 task.result
      queue.markTaskReady(taskId) → 成功目录的 videoIds 由 ScopedScrapeService 刮削
      → 刮削完成后标记 partial-failure
   c. if result.failedDirectories.length > 0 && result.succeededDirectories.length === 0:
      将 DirectedScanRetryContext 存入 task.result
      queue.markTaskFailed(taskId)
6. ScopedScrapeService.execute(task):
   a. resolver.resolve(scope) → 仅获取首次入库视频
   b. 因 mode='incremental' + candidateStrategy='automatic'，自动采用最佳候选
   c. 但目标筛选不经过 ScrapeModeFilter——直接使用 task.request 中携带的 videoIds
```

**关键**：`ScopedScrapeService.execute()` 在处理自动刮削任务时，需识别 `autoTriggered=true` 的 scope，跳过 `ScrapeModeFilter` 筛选，直接使用扫描阶段收集的 `newlyInsertedVideoIds`。这通过在 request 上设置 `videoIds` 字段实现——service 已有 `videoIds` 快速路径（retry 使用），当 `videoIds` 存在时直接用这些 ID 而不走 filter。

### D13: ArkTS 严格类型约束

- 所有新增接口/类使用显式类型注解，不使用 `any`/`unknown`
- `VideoUpsertResult`、`DirectedScanResult`、`FailedDirectory`、`DirectedScanRetryContext`、`DirectoriesSavedEvent` 均定义为 `interface`（ArkTS struct 兼容）
- 不使用 `as` 类型断言；upsert 返回值通过接口字段区分
- 不使用动态属性访问；重试上下文通过 `result` 的显式字段获取
- 集合操作使用 `Set<string>` / `Map<string, number>` 而非对象字面量
- `AutoScrapeTrigger` 和 `AutoScrapeRetryExecutor` 为单例类，遵循项目现有手动 singleton 模式

### D14: 测试切入点

**单元测试**：
- 路径差集计算：`beforePaths`/`afterPaths` 各种组合（纯新增、部分新增、无变化、尾斜杠规范化）
- `VideoDao.upsertVideo()` 返回 `wasNewlyInserted` 区分：新增记录 `true`、更新记录 `false`
- 视频去重：同视频被两个目录扫描时仅纳入一次 `newlyInsertedVideoIds`
- 部分失败结果模型：`DirectedScanResult` 正确分类成功/失败目录

**集成测试**：
- 新增目录保存 → 任务自动入队 → scanning 阶段 → preparing → scraping → completed
- 零首次入库视频 → 任务正常完成
- 部分目录扫描失败 → partial-failure → 重试仅扫描失败目录
- 全部扫描失败 → failed → 重试保留完整上下文
- 别名变化不触发
- 取消 scanning 阶段任务

**测试钩子**：
- `AutoScrapeTrigger.onDirectoriesSaved()` 可直接调用，无需 UI 交互
- `scanDirectories()` 可 mock adapter 返回指定结果
- `AutoScrapeRetryExecutor.retry()` 可通过 taskId 调用

## Risks / Trade-offs

**[Risk] upsertVideo 返回值变更影响现有调用方** → 将 `upsertVideo()` 返回类型从 `Promise<number>` 改为 `Promise<VideoUpsertResult>` 是 breaking change。缓解：提供 `upsertVideoId()` 包装方法返回 `result.id`，逐步迁移调用方；或在 `upsertVideo()` 中新增 `upsertVideoWithResult()` 方法，原方法保持兼容。推荐后者。

**[Risk] 定向扫描期间目录被删除** → 扫描开始后用户可能删除刚保存的目录。缓解：adapter.scan() 会返回错误，归入 `failedDirectories`；目录配置变更不会中断进行中的扫描。取消操作在 scanning 阶段支持。

**[Risk] 大量目录同时新增导致扫描时间过长** → 用户一次选择大量目录时定向扫描耗时可能较长。缓解：scanning 阶段展示进度和当前扫描路径；用户可取消；并发上限（2）限制同时执行的任务数。

**[Risk] 父子目录重复枚举子目录** → `/media` 和 `/media/movies` 同时新增时，`/media/movies` 会被枚举两次。缓解：视频级去重（D4）保证同一视频仅 upsert 一次且仅首次标记 `wasNewlyInserted`；性能影响为重复网络请求，可接受。

**[Trade-off] 不持久化重试上下文** → 应用崩溃时 scanning 阶段的任务和重试上下文丢失。接受此 trade-off：用户可手动刮削补充，复杂度显著降低。符合 spec "不做跨进程恢复"。

**[Trade-off] 自动任务使用 folder scope 而非新 scope 类型** → TopBar 展示的目录路径为逗号拼接，可读性略差。接受此 trade-off：避免侵入 scope 类型体系；displayName 可优化为更友好的格式。
