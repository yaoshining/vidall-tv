# 任务：add-scrape-task-phase

## 1. 类型与快照

- [x] 1.1 `ScopedScrapeTypes.ets`：新增 `export type ScrapeTaskPhase = 'scanning' | 'preparing' | 'scraping'`
- [x] 1.2 `ScrapeTaskSnapshot` 新增 `@Trace phase: ScrapeTaskPhase`，构造函数默认 `'preparing'`

## 2. 队列挂起与阶段传播

- [x] 2.1 `ScrapeTaskQueue.enqueue(request, options?)`：新增可选 `{ phase?: ScrapeTaskPhase }`，创建快照后设置初始 phase
- [x] 2.2 `schedule()` 跳过 `phase === 'scanning'` 的等待任务（挂起）
- [x] 2.3 新增 `updateScanProgress(taskId, progress)`：仅当任务处于 `waiting && phase==='scanning'` 时更新进度并 publish
- [x] 2.4 新增 `markTaskReady(taskId)`：仅当 `waiting && phase==='scanning'` 时置 phase 为 preparing，publish 并 schedule
- [x] 2.5 新增 `markTaskFailed(taskId)`：仅当 `waiting && phase==='scanning'` 时置 status 为 failed（result 全零），publish
- [x] 2.6 `start()` 内 onProgress 回调扩展为 `(progress, phase?)`：收到 phase 时更新任务 phase

## 3. 服务准备阶段上报

- [x] 3.1 `ScopedScrapeService.ets`：`ScrapeProgressCallback` 扩展为 `(progress: ScrapeProgress, phase?: ScrapeTaskPhase) => void`
- [x] 3.2 `executeAutomatic`：进入分析循环前上报 `preparing`（{0, videoCount}），逐个 `loadTarget` 完成后上报 {已分析数, videoCount}；进入目标写入循环时上报 `scraping`
- [x] 3.3 `executeWithConfirmation`：全新任务同 3.2；带 resumeState 的恢复执行跳过 preparing，首个进度事件即上报 `scraping`

## 4. 扫描进度回调

- [x] 4.1 `VideoScannerTypes.ets`：新增 `ScanProgressCallback = (completed: number, total: number) => void`，`ScanOptions` 增加可选 `onScanProgress`
- [x] 4.2 `VideoScannerUtil.scan`：先收集全部文件源及其目录（一次 DB 读取）得到总目录数，再逐目录扫描；每个目录完成与扫描开始时调用 `onScanProgress(completed, total)`；未传回调时行为与现在完全一致

## 5. 全局入口串联

- [x] 5.1 `MediaLibraryTab.runScan`：先 `enqueue(request, { phase: 'scanning' })` 记录 taskId → 以 onScanProgress 回调调用 `VideoScannerUtil.scan`（回调内 `updateScanProgress`）→ 成功后 `markTaskReady(taskId)` → toast
- [x] 5.2 扫描抛错时 `markTaskFailed(taskId)` 并保留既有错误 toast；finally 重置 `isDiscoveringScan`
- [x] 5.3 `globalStatusText`/`globalProgressText` 按任务 phase 显示"扫描中/准备中/刮削中"与目录进度文案

## 6. UI 阶段文案

- [x] 6.1 `ScrapeTaskIndicator.ets`：任务项状态行按 phase 显示"扫描中 / 准备中 / 刮削中"（等待确认、终态文案不变）
- [x] 6.2 扫描阶段进度文案沿用 `completed/total`（含义为已扫描目录数）

## 7. 测试

- [x] 7.1 `ScopedScrape.test.ets`：scanning 任务挂起不被调度；`markTaskReady` 后开始执行；`updateScanProgress` 仅在 scanning 阶段生效；取消后 ready/progress 被忽略；onProgress phase 传播到快照；服务在目标写入前上报 preparing 与 scraping
- [x] 7.2 `VideoScannerUtil.test.ets`：传入回调时收到 (completed, total) 且 total 等于目录总数；未传回调时扫描结果与既有行为一致

## 8. 扫描上下文展示

- [ ] 8.1 `VideoScannerTypes.ets`：新增 `ScanContextInfo { sourceType: FileSourceType; sourceName: string; directoryPath: string; currentPath: string }`；`ScanProgressCallback` 扩展第三参 `context?: ScanContextInfo`；`ScanOptions` 增加可选 `onCurrentPath?: (currentPath: string) => void`
- [ ] 8.2 `WebDAVAdapter.ets` / `SMBAdapter.ets`：`scanDir` 每次进入目录（调用 `listDirectory` 前）上报当前路径（`onCurrentPath`），未提供回调时行为不变；`scan` 把回调透传给 `scanDir`
- [ ] 8.3 `VideoScannerUtil.scan`：扫描每个目录前以该目录构造 `ScanContextInfo` 调用 `onScanProgress(completed, total, context)`；把 `options.onCurrentPath` 包装为"以最新枚举路径更新 context.currentPath 再回调"；目录完成后 `completed++` 时的回调不携带 context（UI 保留上次上下文）
- [ ] 8.4 `ScopedScrapeTypes.ets`：新增 `ScrapeScanContext { sourceTypeLabel: string; sourceName: string; directoryPath: string; currentPath: string }`；`ScrapeTaskSnapshot` 新增 `@Trace scanContext: ScrapeScanContext | undefined`，构造默认 `undefined`
- [ ] 8.5 `ScrapeTaskQueue.updateScanProgress` 增加第三参 `context?: ScrapeScanContext`：仅当 context 非 undefined 时赋值 `task.scanContext`，更新守卫不变
- [ ] 8.6 新建 `entry/src/main/ets/utils/PathDisplayUtil.ets`：导出 `truncateMiddlePath(path: string, maxLen: number): string`——不超长原样返回；超长时保留前两段路径段 + `/…/` + 末段（如 `/根文件夹/爷文件夹/…/abc.mp4`）；仍超长则头缩为第一段；最终仍超长则对尾部做前缀 `…` 截断到 maxLen
- [ ] 8.7 `MediaLibraryTab.runScan`：扫描回调把 `ScanContextInfo` 映射为 `ScrapeScanContext`（`FileSourceType` → 显示标签：webdav→'WebDAV'、smb→'SMB'、其余原样返回枚举值）传给 `updateScanProgress`；新增私有方法 `scanContextText()` 拼接 `标签 · 源名 · 配置目录 · 正在扫描: 截断路径`
- [ ] 8.8 `MediaLibraryTab.GlobalScrapeStatus`：scanning 且存在 `scanContext` 时在进度条下增加一行上下文展示（`globalStatusText` 的 scanning 文案追加 ` · 源标签·源名`）；`ScrapeTaskIndicator.TaskItem`：scanning 且存在 `scanContext` 时在状态行下追加 `源标签 · 源名 · 配置目录` 与 `正在扫描: 截断路径` 两行
- [ ] 8.9 测试：`VideoScannerUtil.test.ets` 增加 `truncateMiddlePath` 用例（不超长原样；超长保留前两段+…+末段且与示例一致；极端超长收缩与尾截断）；`ScopedScrape.test.ets` 增加 `updateScanProgress` 携带 context 时快照 `scanContext` 被更新、不携带时保留旧值的用例
