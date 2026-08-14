# 拆分 VideoScannerUtil.ets

## Why

`utils/VideoScannerUtil.ets`（1695 行）把四类职责塞进一个文件：共享数据结构与类型、纯函数工具、三种协议适配器（WebDAV / SMB / Unsupported 各 600+ / 500+ / 36 行）、以及扫描编排类 `VideoScannerUtil`。文件内职责边界清晰、无耦合，是典型的 god class，应拆分为单一职责模块以提升可维护性。

## What Changes

- 新建 `utils/VideoScannerTypes.ets`：共享数据结构与契约 —— `VideoFileInfo` / `VideoScrapeContext` / `SourceScanStat` / `ScanResult` / `ScanMode` / `ScanOptions` / `DEFAULT_SCAN_OPTIONS` / `ISourceAdapter`。
- 新建 `utils/VideoScannerHelpers.ets`：共享纯函数 —— `isVideoFile` / `hasSeasonSiblingDirectory` / `createVideoScrapeContext` / `classifyVideoScrapeTarget` / `hasCompleteScrapeAssociation` / `shouldRepairIncompleteTvEpisode` / `extractEpisodeNumberFromWeakSemanticFileName` / `clearStaleScrapeAssociationsForOverwrite` 及 `VIDEO_EXTENSIONS`。
- 新建 `utils/WebDAVAdapter.ets`：`WebDAVAdapter` 类（原 278~900 行）。
- 新建 `utils/SMBAdapter.ets`：`SMBAdapter` 类（原 906~1458 行）。
- 瘦身 `utils/VideoScannerUtil.ets`：保留 `UnsupportedAdapter` + 适配器工厂 `createAdapter` + 编排类 `VideoScannerUtil`，并 `export type { ScanMode }` 以保持对外导入路径不变。
- 纯代码搬迁，零行为变更（仅 `export` 位置变化，消费方 `MediaLibraryTab.ets` 无需改动）。

## Capabilities

### New Capabilities

<!-- 无：纯重构 -->

### Modified Capabilities

<!-- 无：无 spec 级行为变更 -->

> 纯重构，`.openspec.yaml` 设置 `skip_specs: true`，不产生 spec delta。

## Impact

- 受影响文件：`utils/VideoScannerTypes.ets` / `utils/VideoScannerHelpers.ets` / `utils/WebDAVAdapter.ets` / `utils/SMBAdapter.ets`（新增）、`utils/VideoScannerUtil.ets`（瘦身）。
- 对外 API：`VideoScannerUtil`（类）与 `ScanMode`（类型）的导入路径保持不变，`MediaLibraryTab.ets` 无需改动。
- 无 API / 依赖 / 数据库 / 资源变更。
- 无 breaking change。
