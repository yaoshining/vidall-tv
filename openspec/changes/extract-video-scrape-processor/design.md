# 设计：抽取共享刮削处理器（doScrapeOnly 去重）

## 目标

把 `WebDAVAdapter.doScrapeOnly` 与 `SMBAdapter.doScrapeOnly` 的 ~270 行重复实现收敛为一个共享函数，消除复制粘贴，保持刮削决策 / DB 写入 / 返回值不变，日志输出统一为两版并集。

## 差异清单（diff 逐行比对结果）

两方法功能逻辑一致，差异仅 4 类：

1. **日志前缀**（每处 `console.*`）：WebDAV `[VideoScanner][SCRAPE]`，SMB `[VideoScanner][SMB][SCRAPE]`。
2. **局部变量名**：`db`/`sdb`、`movie`/`mov`、`series`/`ser`、`movieScrapeInfo`/`smScrapeInfo`。
3. **`const db` 声明位置**：SMB 在顶部声明一次；WebDAV 分散在 fix-missing / unknown / movie / tv 四个分支内。
4. **日志行漂移**（前缀之外的差异）：
   - 仅 WebDAV 有：`电影刮削结果 title=... posterUrl=... rating=...`、`电影入库 movieId=...`、`剧集复用已有记录 seriesId=...`、`剧集入库 seriesId=...`。
   - 仅 SMB 有：`电影复用更新 posterUrl/originCountryJson movieId=...`。
   - 文本差异：WebDAV `scrape_info 落库` vs SMB `movie scrape_info 落库`。

## 决策记录

### D1：抽成独立模块 `VideoScrapeProcessor.ets`，导出 `processVideoScrape`

`doScrapeOnly` 涉及 DB 写入与刮削调用，非纯函数，不放入 `VideoScannerHelpers`（纯函数模块）。单独建 `VideoScrapeProcessor.ets` 更贴合职责。

### D2：函数签名以 `logPrefix` 参数化

```typescript
export async function processVideoScrape(
  videoId: number,
  fileName: string,
  scrapeClient: ScrapeClient,
  mode: ScanMode,
  info: VideoFileInfo,
  logPrefix: string
): Promise<void>
```

- WebDAV 传 `'[VideoScanner][SCRAPE]'`，SMB 传 `'[VideoScanner][SMB][SCRAPE]'`，前缀行为保持不变（WebDAV 缺 `[WebDAV]` 段的历史不一致**不在本次修复**，避免扩大改动面）。
- `clearStaleScrapeAssociationsForOverwrite` 的 `logPrefix` 参数直接透传该值。

### D3：适配器保留 `doScrapeOnly` 作为薄委托

`doScrapeOnly` 是 `private` 方法，其调用点（各 3 处，位于 `scanDir` 的异步闭包内）保持不变；仅方法体替换为一行委托，传入本适配器的 `logPrefix`。这样 diff 最小、`this` 绑定不受影响。

### D4：日志统一为两版并集

以 WebDAV 版为基线（变量名更清晰、日志更全），合并 SMB 独有的「电影复用更新」日志与两条注释（`fix-missing` / `overwrite`），并统一 `movie scrape_info 落库` 文本。结果：两适配器刮削日志完全对称，便于排障。

### D5：`const db` 提升到函数顶部

`FileSourceDatabase.getInstance()` 是单例，调用次数不影响行为。提升到函数顶部声明一次，消除四处重复 `const db`。

### D6：变量名统一

统一为 `db` / `movie` / `series` / `movieScrapeInfo`（WebDAV 的更清晰命名），无行为影响。

### D7：验证策略

- 编译验证：`hvigorw assembleHap`（`--no-daemon`）。
- 行为验证：真机安装启动冒烟；扫描刮削路径依赖真实 WebDAV/SMB 源，以编译 + 启动 + 用户手动扫描为准。
- 不新增单测（功能逻辑未变）。

## 迁移计划

1. 新建 `VideoScrapeProcessor.ets`，写入 `processVideoScrape`（以 WebDAV 版为基线 + D2/D4/D5/D6 改造）。
2. `WebDAVAdapter.doScrapeOnly` 体替换为委托 `processVideoScrape(..., '[VideoScanner][SCRAPE]')`，精简 import。
3. `SMBAdapter.doScrapeOnly` 体替换为委托 `processVideoScrape(..., '[VideoScanner][SMB][SCRAPE]')`，精简 import。
4. `assembleHap` 编译通过。
5. 真机冒烟 + `openspec validate`。

## 风险与回滚

- 风险低：功能逻辑逐字保留，仅日志与变量名收敛；编译期捕获 import 遗漏。
- 日志输出变化：两适配器刮削日志对称化（仅调试信息）。
- 回滚：revert 单次 commit。
