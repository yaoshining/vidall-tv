# 抽取共享刮削处理器（doScrapeOnly 去重）

## Why

`WebDAVAdapter` 与 `SMBAdapter` 的 `doScrapeOnly` 方法各约 270 行，**功能逻辑（分类 → 刮削 → 入库 → 写 scrape_info）100% 一致**，仅存在日志前缀、局部变量名、`const db` 声明位置、以及若干日志行的漂移差异。两处大段复制粘贴导致修一处刮削逻辑需同步改两份，极易漏改引发 WebDAV/SMB 扫描行为不一致。

## What Changes

- 新建 `utils/VideoScrapeProcessor.ets`，导出统一函数 `processVideoScrape(videoId, fileName, scrapeClient, mode, info, logPrefix)`，收敛两处 `doScrapeOnly` 的重复实现。
- `WebDAVAdapter.doScrapeOnly` 与 `SMBAdapter.doScrapeOnly` 改为**薄委托**：仅调用 `processVideoScrape(...)` 并传入各自日志前缀（`[VideoScanner][SCRAPE]` / `[VideoScanner][SMB][SCRAPE]`），调用点保持不变。
- 日志前缀参数化；两版漂移的日志行统一为**并集**（WebDAV 补「电影复用更新」，SMB 补「电影刮削结果 / 电影入库 / 剧集复用已有记录 / 剧集入库」等），变量名统一为更清晰的 `db` / `movie` / `series` / `movieScrapeInfo`。
- 刮削决策、DB 写入、返回值完全不变（纯逻辑收敛 + 日志一致性微调）。

## Capabilities

### New Capabilities

<!-- 无：纯重构 + 日志一致性微调 -->

### Modified Capabilities

<!-- 无：无 spec 级行为变更 -->

> `.openspec.yaml` 设置 `skip_specs: true`，不产生 spec delta。

## Impact

- 受影响文件：`utils/VideoScrapeProcessor.ets`（新增）、`utils/WebDAVAdapter.ets`、`utils/SMBAdapter.ets`。
- 无 API / 依赖 / 数据库 / 资源变更。
- 无 breaking change。
- 日志输出：两适配器刮削日志统一为并集（仅调试日志，不影响功能）。
