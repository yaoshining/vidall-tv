# 提案：全局刮削任务覆盖扫描与准备阶段

## Why

用户点击全局刮削后，文件扫描（`VideoScannerUtil.scan`）与目标准备（范围解析 + 逐视频 `loadTarget` 分析）都发生在任务入队之前，任务列表在这两个阶段完全无感知，表现为“点击后无反馈”。本变更让全局刮削任务在扫描开始前就进入任务队列，并为任务新增阶段（phase）维度，使扫描与准备进度全程可见、可取消。

## What Changes

- `ScrapeTaskSnapshot` 新增 `@Trace phase` 字段：`scanning | preparing | scraping`，构造默认 `preparing`（局部刮削行为不变）
- `ScrapeTaskQueue` 支持带初始 phase 入队；调度器跳过 scanning 阶段的等待任务（挂起）；新增 `updateScanProgress`、`markTaskReady`、`markTaskFailed` 供扫描驱动方使用
- executor 进度回调扩展为 `(progress, phase?)`：准备阶段按已分析视频数上报 preparing，进入目标写入时上报 scraping；恢复执行（候选确认后）直接从 scraping 继续
- `VideoScannerUtil.scan` 新增可选 `onScanProgress(completed, total)` 回调，扫描前先收集全部文件源目录以获得总目录数
- `MediaLibraryTab.runScan` 改为：先入队（phase=scanning）→ 扫描进度回传任务 → `markTaskReady`；扫描失败时 `markTaskFailed` 并 toast
- `ScrapeTaskIndicator` 与媒体库全局状态文案按 phase 显示“扫描中 / 准备中 / 刮削中”
- 扫描阶段展示上下文：适配器上报当前枚举目录，`ScanContextInfo`（源类型/源名/配置目录/当前路径）经扫描回调传入任务快照 `@Trace scanContext`；UI 展示“源类型 · 源名 · 配置目录 · 正在扫描: 路径”，超长路径按段中部截断（保留前两段 + `…` + 末段，如 `/根文件夹/爷文件夹/…/abc.mp4`）

## Impact

- Affected specs: `scrape-task-queue`
- Affected code:
  - `entry/src/main/ets/services/scrape/ScopedScrapeTypes.ets`
  - `entry/src/main/ets/services/scrape/ScrapeTaskQueue.ets`
  - `entry/src/main/ets/services/scrape/ScopedScrapeService.ets`
  - `entry/src/main/ets/utils/VideoScannerTypes.ets`、`entry/src/main/ets/utils/VideoScannerUtil.ets`、`entry/src/main/ets/utils/WebDAVAdapter.ets`、`entry/src/main/ets/utils/SMBAdapter.ets`、`entry/src/main/ets/utils/PathDisplayUtil.ets`
  - `entry/src/main/ets/components/scrape/ScrapeTaskIndicator.ets`
  - `entry/src/main/ets/pages/home/tabs/MediaLibraryTab.ets`
  - `entry/src/test/ScopedScrape.test.ets`、`entry/src/test/VideoScannerUtil.test.ets`
- 兼容性：phase 默认值 `preparing` 与回调可选参数保证既有调用点（局部刮削、重试、测试假实现）无需强制修改；扫描回调为可选参数
- 明确不做（Non-goals）：不改变扫描本身的目录遍历语义；不改变重试、去重、并发上限的既有规则；不做 openspec 归档
