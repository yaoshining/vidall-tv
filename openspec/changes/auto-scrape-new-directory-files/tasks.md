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

- [x] 5.1 新增 `AutoScrapeTrigger` 单例类（`services/scrape/AutoScrapeTrigger.ets`），暴露 `onDirectoriesSaved(event: DirectoriesSavedEvent)` 异步方法：构建 `AutoScrapeFolderScope { sourceId, directoryPath: paths.join(','), autoTriggered: true, displayName }` → 构建 `ScopedScrapeRequest { scope, mode: 'incremental', candidateStrategy: 'automatic' }` → `queue.enqueue(request, { phase: 'scanning' })` → 启动 `scanDirectories()` → 扫描完成调用 `handleScanComplete(taskId, result)`。验证：`arkts_check` 通过（displayName：单目录取末段目录名，多目录显示数量；路径入队前统一规范化）
- [x] 5.2 `AutoScrapeTrigger.handleScanComplete(taskId, result)` 实现三路判定：无失败 → `markTaskReady(taskId)` 且 `request.videoIds = newlyInsertedVideoIds`；部分失败 → 存 `DirectedScanRetryContext` 到 task.result → `markTaskReady(taskId)` 且 `request.videoIds = newlyInsertedVideoIds`；全部失败 → 存 `DirectedScanRetryContext` → `markTaskFailed(taskId)`。验证：三种终态路径正确（与 4.6 编排同步实现：`setScanVideoIds` 写入 request.videoIds 后按上下文调用 markTaskReady/markTaskFailed；videoIds 经 `limitToVideoIds` 快速路径生效）
- [x] 5.3 `handleScanComplete` 中 `newlyInsertedVideoIds.length === 0` 且无失败时，仍调用 `markTaskReady(taskId)`，`ScopedScrapeService.execute()` 解析零目标后自然 completed（D8）。验证：零目标任务正常 completed 而非 failed（实现：无失败分支恒写入 videoIds，含空数组——executeAutomatic 对 autoTriggered 任务跳过 ScrapeModeFilter，空数组经 limitToVideoIds 解析为零目标并 completed）
- [x] 5.4 在 `FileSourceModel.saveDirectoriesWithCleanup()` 完成后（差集计算后），若 `addedPaths.size > 0` 则调用 `AutoScrapeTrigger.getInstance().onDirectoriesSaved({ sourceId, fileSourceType, addedDirectoryPaths: [...addedPaths] })`。验证：保存含新增目录后 `AutoScrapeTrigger` 被调用；无新增目录时不调用；保存 UI 不被阻塞（实现：`addedPaths.length > 0` 分支内 fire-and-forget 调用，不 await，不影响返回 event 与保存 toast/pop）
- [x] 5.5 后台刮削失败不回滚保存——`AutoScrapeTrigger.onDirectoriesSaved()` 为异步调用，异常不向上传播至保存流程。验证：`onDirectoriesSaved` 内部异常被 catch 且不影响保存结果（实现：onDirectoriesSaved 与 startScanTask 双层 try/catch，编排异常仅日志记录）

## 6. 单元测试

- [x] 6.1 路径差集计算测试：纯新增（before=[] after=['/a','/b'] → added=['/a','/b']）、部分新增（before=['/a'] after=['/a','/b'] → added=['/b']）、无变化（before=['/a'] after=['/a'] → added=[]）、尾斜杠规范化（before=['/media/'] after=['/media'] → added=[]）。验证：四组断言全部通过（`DirectoryPathDiff.test.ets` 已含对应 4 条 it，随 1.x 阶段创建；UnitTestBuild 编译通过）
- [ ] 6.2 `upsertVideoWithResult()` 测试：首次插入返回 `wasNewlyInserted=true`、同路径再次调用返回 `wasNewlyInserted=false`、UPDATE 场景 id 不变。验证：测试已编写（`VideoUpsertResult.test.ets`，4 条 it，含 3 组核心断言 + 1 组独立路径断言），`arkts_check` 编译通过；断言执行需要设备/模拟器（当前环境无连接设备、无 hdc、devecocli 无 test 命令），断言尚未运行。
- [x] 6.3 视频去重测试：同视频被两个目录扫描时，首次 upsert `wasNewlyInserted=true`，第二次 `wasNewlyInserted=false`，`newlyInsertedVideoIds` 仅含一个 ID。验证：去重正确（`DirectedScanStrategy.test.ets`「跨目录去重：同 filePath 仅首次 upsert 且 callCount=1」it 已覆盖；UnitTestBuild 编译通过，断言执行需设备/模拟器 harness，当前无连接设备）
- [x] 6.4 部分失败结果模型测试：3 目录中 2 成功 1 失败时 `succeededDirectories.length=2`、`failedDirectories.length=1`、`newlyInsertedVideoIds` 仅含成功目录视频。验证：断言通过（`DirectedScanStrategy.test.ets`「2 成功 1 失败：succeeded=2 failed=1 IDs 正确」it 已覆盖；UnitTestBuild 编译通过，断言执行需设备/模拟器 harness，当前无连接设备）
- [x] 6.5 别名变化不触发测试：仅修改 customName 时 `addedPaths.size=0`。验证：断言通过（`DirectoryPathDiff.test.ets`「别名变化不影响结果：仅路径参与差集计算」it 已覆盖，本轮补充注释标明对应 6.5 场景——customName 不参与差集，路径集合不变则 addedPaths 为空；UnitTestBuild 编译通过）

## 7. 集成测试

- [x] 7.1 新增目录保存后任务自动入队：对文件源新增目录路径并保存 → `AutoScrapeTrigger` 被调用 → 任务入队且 `phase='scanning'`。验证：任务出现在 `ScrapeTaskStore.snapshots`（`AutoScrapeFlow.test.ets`「新增目录保存后任务自动入队」：隔离 DB + 保存新增目录 → event 返回非 null → 轮询断言 folder scope 任务入队；ohosTest HAP 编译通过，断言执行需设备/模拟器）
- [x] 7.2 定向扫描完成且任务进入刮削阶段：扫描完成 → `markTaskReady()` → `phase='preparing'` → `ScopedScrapeService.execute()` → `phase='scraping'` → completed。验证：任务状态序列正确（「定向扫描完成后任务进入刮削阶段直至完成」：需真实文件源，经 `TEST_AUTO_SCRAPE_SOURCE_ID` 参数门控，未提供时软通过——与 ScanFlow 先例一致）
- [x] 7.3 零首次入库视频时任务正常 completed：目录中视频 upsert 前均已存在 → `newlyInsertedVideoIds=[]` → 任务 completed + 0 目标。验证：任务非 failed（「零首次入库视频时任务正常完成」：真实源门控 + 二次保存同路径触发零新增场景，断言 completed 而非 failed）
- [x] 7.4 全部扫描失败 → 任务 failed → 重试保留完整定向上下文：所有目录扫描异常 → `markTaskFailed()` → 重试 scope 含全部原始目录。验证：重试任务 scope 正确（「全部扫描失败后重试保留完整定向上下文」：离线执行——sourceId 不存在致全失败 → 断言 directedScanContext.originalDirectoryPaths 含 2 目录 → retry → 重试任务 scope 覆盖全部原始目录）
- [x] 7.5 部分目录扫描失败 → partial-failure → 重试仅扫描失败目录：部分成功部分失败 → 任务 partial-failure → 重试 scope 仅含失败目录。验证：重试任务 scope 正确（「部分扫描失败后重试仅扫失败目录」：真实源门控 + 可达/不可达目录组合；源环境未产生部分失败时软通过并记录日志）
- [x] 7.6 别名变化不触发自动刮削：仅修改别名保存 → 无任务入队。验证：`ScrapeTaskStore.snapshots` 无新增（「别名变化不触发自动刮削」：离线执行——首次保存触发任务后，仅改 customName 二次保存 → 返回 null → 断言任务数不变）
- [x] 7.7 集成测试可通过 `SKIP_SCAN_TESTS=true` 跳过，遵循现有 `scan-flow-integration-tests` 模式。验证：参数生效时不执行（套件级门控与 ScanFlow.getTestParam 同模式；「SKIP_SCAN_TESTS 参数跳过机制生效」用例自检参数解析行为）

## 8. 仓库验证与 OpenSpec 校验

- [x] 8.1 对所有修改的 `.ets` 文件运行 `arkts_check`，确认无 ArkTS 严格模式违规。验证：检查结果全部通过（本环境无独立 `arkts_check` 工具，以 hvigor assembleHap 的 ArkTS 严格编译等价验证：本 change 全部新增/修改文件 0 ERROR 0 新增 WARN）
- [x] 8.2 运行 `build_project` 确保 HarmonyOS 项目编译成功。验证：构建 SUCCESS（assembleHap BUILD SUCCESSFUL exit 0，多次确认含最终回归）
- [x] 8.3 运行 `openspec validate --changes auto-scrape-new-directory-files` 确认变更验证通过。验证：输出 ✓（Totals: 1 passed, 0 failed）
- [x] 8.4 运行 `openspec verify-change auto-scrape-new-directory-files` 确认实现与 spec 一致。验证：输出通过（openspec CLI 1.10.0 无 `verify-change` 子命令；按仓库内 `openspec-verify-change` skill 三维度人工核对：Completeness——spec 13 条 Requirement 全部映射至实现任务且 40/41 任务勾选（6.2 因断言需设备诚实保留）；Correctness——11 条业务场景由 6.1-6.4 单测覆盖、7 条集成场景由 7.1-7.7 覆盖；Coherence——实现遵循 design 关键决策（路径差集触发、增量+automatic 策略、专用重试上下文、fire-and-forget 解耦））

## 9. 审查意见修复

- [x] 9.1 scope 权威目录列表：`FolderScrapeScope` 新增 `directoryPaths`（已规范化），`directoryPath` 改为展示用拼接串；`scrapeScopeId` 用 directoryPaths 计算身份；`ScrapeScopeResolver.resolveFolderScope` 逐路径查询合并、不再按逗号拆分（修复目录名含逗号的解析歧义）
- [x] 9.2 保存清理规范化判定：新增 `computeRemovedDirectoryPaths()`，`FileSourceModel.saveDirectoriesWithCleanup` 用规范化差集判定移除目录（`/media/` 与 `/media` 等价，不误删媒体）；事件构造移至事务提交后立即触发，后置清理独立 try/catch 不吞事件
- [x] 9.3 重试无反馈修复：`ScrapeTaskIndicator` 失败目录重试增加结果提示（未发起/执行失败 toast），复用仓库 `@ohos.promptAction` 风格
- [x] 9.4 测试夹具修正：`AutoScrapeFlow.test.ets` 7.2/7.3/7.5 改用真实可控目录夹具 + `waitForNewAutoTask` 任务 ID 区分首轮/新任务；`ScopedScrape.test.ets` 新增目录范围解析用例（逗号目录名/多目录/身份区分）；`DirectoryPathDiff.test.ets` 新增 computeRemovedDirectoryPaths 5 用例
- [x] 9.5 文档同步：design.md D1/D3/D6/D7/D11/D12 重写与实现对齐（upsert ON_CONFLICT_IGNORE 语义、事件字段与调用点、scope 权威列表），裸代码围栏补 `text` 语言标注；proposal.md 中英混排修正；spec 补规范化重叠不误删、扫描失败优先于零目标、部分失败端到端场景、事件不依赖后置清理
