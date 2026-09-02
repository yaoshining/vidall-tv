# 任务：add-scrape-task-phase

## 1. 类型与快照

- [ ] 1.1 `ScopedScrapeTypes.ets`：新增 `export type ScrapeTaskPhase = 'scanning' | 'preparing' | 'scraping'`
- [ ] 1.2 `ScrapeTaskSnapshot` 新增 `@Trace phase: ScrapeTaskPhase`，构造函数默认 `'preparing'`

## 2. 队列挂起与阶段传播

- [ ] 2.1 `ScrapeTaskQueue.enqueue(request, options?)`：新增可选 `{ phase?: ScrapeTaskPhase }`，创建快照后设置初始 phase
- [ ] 2.2 `schedule()` 跳过 `phase === 'scanning'` 的等待任务（挂起）
- [ ] 2.3 新增 `updateScanProgress(taskId, progress)`：仅当任务处于 `waiting && phase==='scanning'` 时更新进度并 publish
- [ ] 2.4 新增 `markTaskReady(taskId)`：仅当 `waiting && phase==='scanning'` 时置 phase 为 preparing，publish 并 schedule
- [ ] 2.5 新增 `markTaskFailed(taskId)`：仅当 `waiting && phase==='scanning'` 时置 status 为 failed（result 全零），publish
- [ ] 2.6 `start()` 内 onProgress 回调扩展为 `(progress, phase?)`：收到 phase 时更新任务 phase

## 3. 服务准备阶段上报

- [ ] 3.1 `ScopedScrapeService.ets`：`ScrapeProgressCallback` 扩展为 `(progress: ScrapeProgress, phase?: ScrapeTaskPhase) => void`
- [ ] 3.2 `executeAutomatic`：进入分析循环前上报 `preparing`（{0, videoCount}），逐个 `loadTarget` 完成后上报 {已分析数, videoCount}；进入目标写入循环时上报 `scraping`
- [ ] 3.3 `executeWithConfirmation`：全新任务同 3.2；带 resumeState 的恢复执行跳过 preparing，首个进度事件即上报 `scraping`

## 4. 扫描进度回调

- [ ] 4.1 `VideoScannerTypes.ets`：新增 `ScanProgressCallback = (completed: number, total: number) => void`，`ScanOptions` 增加可选 `onScanProgress`
- [ ] 4.2 `VideoScannerUtil.scan`：先收集全部文件源及其目录（一次 DB 读取）得到总目录数，再逐目录扫描；每个目录完成与扫描开始时调用 `onScanProgress(completed, total)`；未传回调时行为与现在完全一致

## 5. 全局入口串联

- [ ] 5.1 `MediaLibraryTab.runScan`：先 `enqueue(request, { phase: 'scanning' })` 记录 taskId → 以 onScanProgress 回调调用 `VideoScannerUtil.scan`（回调内 `updateScanProgress`）→ 成功后 `markTaskReady(taskId)` → toast
- [ ] 5.2 扫描抛错时 `markTaskFailed(taskId)` 并保留既有错误 toast；finally 重置 `isDiscoveringScan`
- [ ] 5.3 `globalStatusText`/`globalProgressText` 按任务 phase 显示“扫描中/准备中/刮削中”与目录进度文案

## 6. UI 阶段文案

- [ ] 6.1 `ScrapeTaskIndicator.ets`：任务项状态行按 phase 显示“扫描中 / 准备中 / 刮削中”（等待确认、终态文案不变）
- [ ] 6.2 扫描阶段进度文案沿用 `completed/total`（含义为已扫描目录数）

## 7. 测试

- [ ] 7.1 `ScopedScrape.test.ets`：scanning 任务挂起不被调度；`markTaskReady` 后开始执行；`updateScanProgress` 仅在 scanning 阶段生效；取消后 ready/progress 被忽略；onProgress phase 传播到快照；服务在目标写入前上报 preparing 与 scraping
- [ ] 7.2 `VideoScannerUtil.test.ets`：传入回调时收到 (completed, total) 且 total 等于目录总数；未传回调时扫描结果与既有行为一致
