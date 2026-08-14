# 设计：拆分 VideoScannerUtil.ets

## 目标

把 1695 行的 `VideoScannerUtil.ets` 按职责拆成 5 个模块，消除 god class，保持零行为变更与对外导入路径不变。

## 现状结构（1695 行）

| 行区间 | 内容 | 行数 |
|---|---|---|
| 1~21 | imports | 21 |
| 23~77 | 数据结构 + 类型 + `DEFAULT_SCAN_OPTIONS` | ~55 |
| 79~102 | `VIDEO_EXTENSIONS` + `isVideoFile` | ~23 |
| 104~264 | 纯函数（含 `classifyVideoScrapeTarget` 等） | ~160 |
| 266~272 | `ISourceAdapter` 接口 | 7 |
| 274~900 | `WebDAVAdapter` | ~627 |
| 902~1458 | `SMBAdapter` | ~557 |
| 1460~1480 | `UnsupportedAdapter` | ~21 |
| 1482~1495 | `createAdapter` 工厂 | 14 |
| 1497~1695 | `VideoScannerUtil` 编排类 | ~199 |

## 依赖分析

- **适配器**（WebDAV / SMB / Unsupported）依赖共享类型（`VideoFileInfo` / `VideoScrapeContext` / `ScanOptions` / `ScanMode` / `ISourceAdapter`）与共享纯函数（`isVideoFile` / `createVideoScrapeContext` / `hasSeasonSiblingDirectory` / `classifyVideoScrapeTarget` / `hasCompleteScrapeAssociation` / `shouldRepairIncompleteTvEpisode` / `extractEpisodeNumberFromWeakSemanticFileName` / `clearStaleScrapeAssociationsForOverwrite`）。
- **编排类 + 工厂** 依赖三种适配器 + 共享类型。
- 若共享类型/函数留在 `VideoScannerUtil.ets`，则「适配器 → VideoScannerUtil」与「VideoScannerUtil → 适配器」形成循环依赖。因此共享类型与纯函数必须先行抽离到独立模块。

## 决策记录

### D1：共享类型与纯函数各抽成一个模块

- `VideoScannerTypes.ets`：纯类型/接口/常量，无任何实现逻辑，不 import 其他业务模块（仅 import `FileSourceType`）。
- `VideoScannerHelpers.ets`：纯函数 + `VIDEO_EXTENSIONS`，import `VideoScannerTypes`，不 import 任何适配器，从而切断循环依赖。

### D2：适配器按协议各占一个文件

- `WebDAVAdapter.ets`：仅 `export class WebDAVAdapter`。
- `SMBAdapter.ets`：仅 `export class SMBAdapter`。
- `UnsupportedAdapter`（36 行占位）留在 `VideoScannerUtil.ets`，与工厂 `createAdapter` 同处，避免为 36 行单独建文件。

### D3：`VideoScannerUtil.ets` 收敛为「编排器 + 工厂」

保留：`UnsupportedAdapter`、`createAdapter`、`VideoScannerUtil` 主类，以及 re-export `export type { ScanMode }`。

### D4：对外导入路径保持不变

ArkTS 支持 `export type { X } from '...'`（代码库已有 7 处先例，含 `VideoPlayerController.ets` 的 `export type { SubtitleTrackItem }`）。唯一外部消费方 `MediaLibraryTab.ets` 仅用 `VideoScannerUtil` + `ScanMode`，二者继续从 `utils/VideoScannerUtil` 导入，故消费方零改动。

### D5：搬迁零行为变更

- 各函数/类的实现文本原样移动，不重写逻辑。
- 各文件按需重建最小 import 列表（去除不再使用的 import，补齐新增文件所需 import）。
- `WebDAVAdapter` 与 `SMBAdapter` 的 `doScrapeOnly` 存在大段重复（仅日志前缀不同），**不在本次范围**——那是行为/日志级去重，需单独 change。

### D6：验证策略

- 编译验证：`hvigorw assembleHap`（`--no-daemon`）。
- 行为验证：真机安装启动冒烟；扫描路径可在真机或用户侧触发一次「媒体库扫描」确认无回归（扫描依赖真实 WebDAV/SMB 源，自动化受限，以编译 + 启动 + 用户手动扫描为准）。
- 不新增单测（纯重构）。

## 迁移计划

1. 新建 `VideoScannerTypes.ets` → 搬类型 + `ISourceAdapter` + `DEFAULT_SCAN_OPTIONS`。
2. 新建 `VideoScannerHelpers.ets` → 搬纯函数 + `VIDEO_EXTENSIONS`。
3. 新建 `WebDAVAdapter.ets` → 搬 `WebDAVAdapter`。
4. 新建 `SMBAdapter.ets` → 搬 `SMBAdapter`。
5. 瘦身 `VideoScannerUtil.ets` → 保留编排器/工厂/占位适配器 + re-export。
6. `assembleHap` 编译通过。
7. 真机安装启动冒烟 + `openspec validate`。

## 风险与回滚

- 风险低：纯代码搬迁，编译期即可捕获 import 遗漏。
- 最大风险点是各文件 import 列表的重建（多搬/漏搬），由编译严格校验兜底。
- 回滚：revert 单次 commit。
