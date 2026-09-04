## 1. 保存结果与路径差集

- [x] 1.1 定义 `DirectoriesSavedEvent` 接口（`ScopedScrapeTypes.ets`），包含 `sourceId: number`、`fileSourceType: FileSourceType`、`addedDirectoryPaths: string[]`（已规范化）。验证：`arkts_check` 通过且接口字段与 design D11 一致
- [x] 1.2 在 `DirectorySelectorState.buildSaveEntries()` 或 `FileSourceModel.saveDirectoriesWithCleanup()` 调用点，保存前读取 `FileSourceDao.getDirectoriesForSource(sourceId)` 获取 `beforePaths`，保存后从 `FileSourceDirectory[]` 提取 `afterPaths`，对两者调用 `normalizeScrapeDirectoryPath()` 规范化后计算 `addedPaths = afterNormalized - beforeNormalized`。验证：纯新增/部分新增/无变化/尾斜杠规范化四种场景返回正确差集
- [x] 1.3 别名变化不纳入 `addedPaths`——仅路径集合差集，`customName` 变更不影响结果。验证：仅修改别名时 `addedPaths.size === 0`

## 2. 数据库/Adapter 首次插入结果契约

- [x] 2.1 定义 `VideoUpsertResult` 接口（`MediaEntity.ets` 或 `VideoDao.ets`），包含 `id: number`、`wasNewlyInserted: boolean`。验证：`arkts_check` 通过且字段与 design D3 一致
- [x] 2.2 在 `VideoDao` 中新增 `upsertVideoWithResult(entity): Promise<VideoUpsertResult>` 方法，复用现有 `getVideoByPath()` + INSERT/UPDATE 逻辑，UPDATE 时 `wasNewlyInserted=false`，INSERT 时 `wasNewlyInserted=true`。原 `upsertVideo()` 保持不变，内部调用 `upsertVideoWithResult()` 并返回 `result.id`。验证：arkts_check 通过；已抽取 `VideoPersistencePort` 接口 + `InMemoryVideoPersistencePort` test double，测试通过编译检查；INSERT 使用 `store.insert(table, bucket, ConflictResolution.ON_CONFLICT_IGNORE)` 代替 `INSERT OR IGNORE` SQL + `lastInsertedRowId` 比较，避免连接级 last_insert_rowid 误判；ON_CONFLICT_IGNORE 冲突时返回 -1，rowId ≥ 0 表示真正插入。
- [x] 2.3 定义 `FailedDirectory` 接口（`ScopedScrapeTypes.ets` 或 `VideoScannerTypes.ets`），包含 `directoryPath: string`、`error: ErrorInfo`。验证：`arkts_check` 通过
- [x] 2.4 定义 `DirectedScanResult` 接口，包含 `succeededDirectories: string[]`、`failedDirectories: FailedDirectory[]`、`newlyInsertedVideoIds: number[]`、`totalFilesScanned: number`。验证：`arkts_check` 通过且字段与 design D5 一致

## 3. 定向扫描及失败模型

- [x] 3.1 在 `VideoScannerUtil.ets` 新增 `scanDirectories(context, sourceId, directoryPaths, options)` 方法：仅加载指定 sourceId 的 FileSource 及 adapter，对每个 directoryPath 调用 `adapter.scan(path, scanOptions)`，聚合结果按 `filePath` 去重（`Map<string, number>`），不调用 `resetVideoUpdatedFlags()`/`deleteGhostVideosForSources()`/`cleanupOrphanedScrapeInfo()`。验证：仅扫描指定 sourceId 的指定目录，不触全库逻辑
- [x] 3.2 定向扫描中为每个视频调用 `db.upsertVideoWithResult(videoEntity)`，收集 `wasNewlyInserted=true` 的 ID 到 `newlyInsertedVideoIds`。验证：首次入库视频纳入、已有记录视频不纳入、不以元数据缺失纳入
- [x] 3.3 单目录扫描异常时将其路径和错误归入 `failedDirectories`，其余目录继续扫描。验证：部分目录失败时 `succeededDirectories` 和 `failedDirectories` 各自正确
- [x] 3.4 父子目录同时新增时（如 `/media` 和 `/media/movies`），两者均纳入扫描范围，但同视频仅首次 upsert 时 `wasNewlyInserted=true`，后续因 filePath 去重返回 `wasNewlyInserted=false`。验证：同一视频 ID 仅出现一次于 `newlyInsertedVideoIds`

## 4. 队列 Runner/Context/专用 Retry

- [x] 4.1 扩展 `FolderScrapeScope` 增加 `autoTriggered?: true` 可选字段（`ScopedScrapeTypes.ets`），使 `scrapeScopeId()` 对 `autoTriggered=true` 的 scope 生成含 `auto:` 前缀的 key 以区分手动/自动任务。验证：`arkts_check` 通过且自动/手动 folder scope 产生不同 scopeId
- [x] 4.2 定义 `DirectedScanRetryContext` 接口（`ScopedScrapeTypes.ets`），包含 `sourceId: number`、`originalDirectoryPaths: string[]`、`failedDirectoryPaths: string[]`。验证：`arkts_check` 通过且字段与 design D6 一致
- [x] 4.3 在 `ScrapeTaskSnapshot.result` 或新增字段中存储 `directedScanContext?: DirectedScanRetryContext`，部分失败/全部失败时写入。验证：`arkts_check` 通过（实现：`ScrapeResult` 新增可选字段 `directedScanContext`，按 D6 存入 result；`markTaskReady`/`markTaskFailed` 接受可选上下文参数写入；`handleOutcome`/`fail` 继承旧 result 上下文避免被刮削结果覆盖；扫描存在失败目录且刮削全部成功时终态为 `partial-failure` 以保留重试入口）
- [x] 4.4 修改 `ScrapeTaskQueue.enqueue()` 使 `ScrapeEnqueueOptions.phase` 支持 folder scope 的 `'scanning'` 值（当前仅 global scope 使用 scanning 阶段）。验证：folder scope + `{ phase: 'scanning' }` 入队后任务 `phase='scanning'` 且 `status='waiting'`（验证结论：`enqueue` 已透传 `options.phase`，folder scope + scanning 行为成立；schedule 跳过 scanning、`updateScanProgress`/`markTaskReady`/`markTaskFailed`/`cancel` 均按 waiting+scanning 正确工作；已补充 `ScrapeEnqueueOptions.phase` 契约注释）
- [x] 4.5 `ScopedScrapeService.execute()` 处理 `autoTriggered=true` 的 folder scope 时，若 `request.videoIds` 存在则跳过 `ScrapeModeFilter` 筛选，直接使用 `videoIds`（复用已有 retry 快速路径）。验证：自动任务仅刮削 `videoIds` 中的视频，不额外筛选（补充：`ScrapeScopeResolver.resolveFolderScope()` 支持逗号拼接多目录路径解析——自动任务 scope 的 directoryPath 为 `paths.join(',')`，单路径语义不变，多路径合并后由 `stableUnique` 去重；无此扩展 resolver 对自动 scope 恒解析为空，端到端流程不成立）
- [x] 4.6 新增 `AutoScrapeRetryExecutor` 单例类（`services/scrape/AutoScrapeRetryExecutor.ets`）：从失败/部分失败任务的 `result.directedScanRetryContext` 提取上下文，构建新 `ScopedScrapeRequest { scope: AutoScrapeFolderScope, mode: 'incremental', candidateStrategy: 'automatic' }`，入队 `{ phase: 'scanning' }`，启动 `scanDirectories()`，全流程与 `AutoScrapeTrigger` 一致。验证：`arkts_check` 通过（实现：重试编排复用 `AutoScrapeTrigger.startScanTask()`（D12 编排唯一来源），执行器负责上下文提取、重试目录计算与委托；扫描异常路径由触发器统一写上下文并 `markTaskFailed`，保证重试入口不丢失；context 经 `pages/home/index.ets` 注入 `AutoScrapeTrigger.setContext()`，与 ScrapeFailureLogStore 同一模式）
- [x] 4.7 `AutoScrapeRetryExecutor.retry(taskId)` 全部失败时 `failedDirectoryPaths === originalDirectoryPaths`，重试扫描全部原始目录；部分失败时 `failedDirectoryPaths` 仅为失败目录。验证：重试任务 scope 的 directoryPath 仅包含需重试的路径（实现：`resolveRetryPaths` 按失败目录数 ≥ 原始目录数判定全部失败，重扫 originalDirectoryPaths；否则仅 failedDirectoryPaths）
- [x] 4.8 修改 `ScrapeTaskIndicator` 重试按钮逻辑：当任务 `result.directedScanContext` 存在时调用 `AutoScrapeRetryExecutor.retry(taskId)` 而非 `Queue.retry(taskId)`。验证：自动刮削失败任务的重试走专用 executor（无上下文的扫描阶段失败任务仍仅提供清除入口，普通任务重试行为不变）
- [x] 4.9 定向扫描 `onScanProgress` 回调中增加 `task.status === 'cancelled'` 前置检查，已取消时丢弃进度更新且不调用 `markTaskReady()`。验证：scanning 阶段取消后扫描回调不再更新任务状态（实现：`AutoScrapeTrigger.handleScanProgress` 与 `handleScanComplete`/`markScanError` 均含 `isTaskCancelled` 前置检查；队列 `updateScanProgress`/`markTaskReady`/`markTaskFailed` 的非 waiting 防御保持兜底；队列新增 `setScanVideoIds` 用于扫描完成后写入首次入库 videoIds，仅 waiting+scanning 生效）

## 5. 目录保存异步触发

- [ ] 5.1 新增 `AutoScrapeTrigger` 单例类（`services/scrape/AutoScrapeTrigger.ets`），暴露 `onDirectoriesSaved(event: DirectoriesSavedEvent)` 异步方法：构建 `AutoScrapeFolderScope { sourceId, directoryPath: paths.join(','), autoTriggered: true, displayName }` → 构建 `ScopedScrapeRequest { scope, mode: 'incremental', candidateStrategy: 'automatic' }` → `queue.enqueue(request, { phase: 'scanning' })` → 启动 `scanDirectories()` → 扫描完成调用 `handleScanComplete(taskId, result)`。验证：`arkts_check` 通过
- [ ] 5.2 `AutoScrapeTrigger.handleScanComplete(taskId, result)` 实现三路判定：无失败 → `markTaskReady(taskId)` 且 `request.videoIds = newlyInsertedVideoIds`；部分失败 → 存 `DirectedScanRetryContext` 到 task.result → `markTaskReady(taskId)` 且 `request.videoIds = newlyInsertedVideoIds`；全部失败 → 存 `DirectedScanRetryContext` → `markTaskFailed(taskId)`。验证：三种终态路径正确
- [ ] 5.3 `handleScanComplete` 中 `newlyInsertedVideoIds.length === 0` 且无失败时，仍调用 `markTaskReady(taskId)`，`ScopedScrapeService.execute()` 解析零目标后自然 completed（D8）。验证：零目标任务正常 completed 而非 failed
- [ ] 5.4 在 `FileSourceModel.saveDirectoriesWithCleanup()` 完成后（差集计算后），若 `addedPaths.size > 0` 则调用 `AutoScrapeTrigger.getInstance().onDirectoriesSaved({ sourceId, fileSourceType, addedDirectoryPaths: [...addedPaths] })`。验证：保存含新增目录后 `AutoScrapeTrigger` 被调用；无新增目录时不调用；保存 UI 不被阻塞
- [ ] 5.5 后台刮削失败不回滚保存——`AutoScrapeTrigger.onDirectoriesSaved()` 为异步调用，异常不向上传播至保存流程。验证：`onDirectoriesSaved` 内部异常被 catch 且不影响保存结果

## 6. 单元测试

- [ ] 6.1 路径差集计算测试：纯新增（before=[] after=['/a','/b'] → added=['/a','/b']）、部分新增（before=['/a'] after=['/a','/b'] → added=['/b']）、无变化（before=['/a'] after=['/a'] → added=[]）、尾斜杠规范化（before=['/media/'] after=['/media'] → added=[]）。验证：四组断言全部通过
- [ ] 6.2 `upsertVideoWithResult()` 测试：首次插入返回 `wasNewlyInserted=true`、同路径再次调用返回 `wasNewlyInserted=false`、UPDATE 场景 id 不变。验证：测试已编写（`VideoUpsertResult.test.ets`，4 条 it，含 3 组核心断言 + 1 组独立路径断言），`arkts_check` 编译通过；断言执行需要设备/模拟器（当前环境无连接设备、无 hdc、devecocli 无 test 命令），断言尚未运行。
- [ ] 6.3 视频去重测试：同视频被两个目录扫描时，首次 upsert `wasNewlyInserted=true`，第二次 `wasNewlyInserted=false`，`newlyInsertedVideoIds` 仅含一个 ID。验证：去重正确
- [ ] 6.4 部分失败结果模型测试：3 目录中 2 成功 1 失败时 `succeededDirectories.length=2`、`failedDirectories.length=1`、`newlyInsertedVideoIds` 仅含成功目录视频。验证：断言通过
- [ ] 6.5 别名变化不触发测试：仅修改 customName 时 `addedPaths.size=0`。验证：断言通过

## 7. 集成测试

- [ ] 7.1 新增目录保存后任务自动入队：对文件源新增目录路径并保存 → `AutoScrapeTrigger` 被调用 → 任务入队且 `phase='scanning'`。验证：任务出现在 `ScrapeTaskStore.snapshots`
- [ ] 7.2 定向扫描完成且任务进入刮削阶段：扫描完成 → `markTaskReady()` → `phase='preparing'` → `ScopedScrapeService.execute()` → `phase='scraping'` → completed。验证：任务状态序列正确
- [ ] 7.3 零首次入库视频时任务正常 completed：目录中视频 upsert 前均已存在 → `newlyInsertedVideoIds=[]` → 任务 completed + 0 目标。验证：任务非 failed
- [ ] 7.4 全部扫描失败 → 任务 failed → 重试保留完整定向上下文：所有目录扫描异常 → `markTaskFailed()` → 重试 scope 含全部原始目录。验证：重试任务 scope 正确
- [ ] 7.5 部分目录扫描失败 → partial-failure → 重试仅扫描失败目录：部分成功部分失败 → 任务 partial-failure → 重试 scope 仅含失败目录。验证：重试任务 scope 正确
- [ ] 7.6 别名变化不触发自动刮削：仅修改别名保存 → 无任务入队。验证：`ScrapeTaskStore.snapshots` 无新增
- [ ] 7.7 集成测试可通过 `SKIP_SCAN_TESTS=true` 跳过，遵循现有 `scan-flow-integration-tests` 模式。验证：参数生效时不执行

## 8. 仓库验证与 OpenSpec 校验

- [ ] 8.1 对所有修改的 `.ets` 文件运行 `arkts_check`，确认无 ArkTS 严格模式违规。验证：检查结果全部通过
- [ ] 8.2 运行 `build_project` 确保 HarmonyOS 项目编译成功。验证：构建 SUCCESS
- [ ] 8.3 运行 `openspec validate --changes auto-scrape-new-directory-files` 确认变更验证通过。验证：输出 ✓
- [ ] 8.4 运行 `openspec verify-change auto-scrape-new-directory-files` 确认实现与 spec 一致。验证：输出通过
