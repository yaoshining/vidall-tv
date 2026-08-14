# 任务：抽取共享刮削处理器（doScrapeOnly 去重）

## 1. 新建共享处理器

- [x] 1.1 新建 `utils/VideoScrapeProcessor.ets`
- [x] 1.2 导出 `processVideoScrape`（以 WebDAV 版为基线，`logPrefix` 参数化）
- [x] 1.3 合并 SMB 独有的「电影复用更新」日志与两条注释
- [x] 1.4 `const db` 提升到函数顶部，变量名统一为 db/movie/series/movieScrapeInfo
- [x] 1.5 统一 `movie scrape_info 落库` 文本
- [x] 1.6 重建 import 列表

## 2. WebDAVAdapter.ets 改造

- [x] 2.1 `doScrapeOnly` 体替换为委托 `processVideoScrape(..., '[VideoScanner][SCRAPE]')`
- [x] 2.2 精简不再需要的 import

## 3. SMBAdapter.ets 改造

- [x] 3.1 `doScrapeOnly` 体替换为委托 `processVideoScrape(..., '[VideoScanner][SMB][SCRAPE]')`
- [x] 3.2 精简不再需要的 import

## 4. 验证

- [x] 4.1 `hvigorw assembleHap`（`--no-daemon`）编译通过
- [x] 4.2 真机安装启动冒烟
- [x] 4.3 `openspec validate extract-video-scrape-processor` 通过
