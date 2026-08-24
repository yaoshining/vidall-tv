## Why

在 `重器/01~4K.mp4` 这类"单层无季子目录、文件名无 S01/S1 季号标记"的路径下扫描剧集，刮削结果缺少季信息（裸 `tv` 而非 `episode`）。根因是 `extractEpisodeNumberFromWeakSemanticFileName` 无法从 `01~4K`（数字后跟 `~`/`_` 而非空格）提取集数，而默认季 1 逻辑又依赖"能提取到集数"这一前提，导致季号兜底失效。TMDB 数据中绝大多数剧集都存在 Season 1，因此按第一季补全是安全且符合直觉的。

## What Changes

- 修复 `extractEpisodeNumberFromWeakSemanticFileName`：让 `01~4K.mp4`、`01_4K.mp4` 这类以 `~`/`_`/`-` 分隔的弱语义文件名也能正确提取集数（此前仅 `01 4K.mp4` 这类空格分隔可提取）。
- 将"无季信息默认季 1"与"是否提取到集数"解耦：只要目标被分类为 `tv`，且文件名与父目录均无法解析出季号，即默认按第一季补全（复用现有 `?? 1` 兜底），不再要求必须先提取到集数。
- 保证 `重器/01~4K.mp4` 刮削后关联到剧集第一季，而非仅作为裸 `tv` 入库。
- 不影响已有混合目录扫描（`seasonSiblingDetected`）、显式 `SxxExx` 及含季号目录名的行为。

## Capabilities

### New Capabilities

- `tv-episode-season-defaulting`: 定义当 TV 剧集文件名与父目录均无法解析出季号时，刮削默认按第一季补全的行为。

### Modified Capabilities

## Impact

- 入口：`entry/src/main/ets/utils/VideoScrapeProcessor.ets` 的 `processVideoScrape`（默认季逻辑）。
- 集数提取：`entry/src/main/ets/utils/VideoScannerHelpers.ets` 的 `extractEpisodeNumberFromWeakSemanticFileName`。
- 刮削兜底：`entry/src/main/ets/lib/ScrapeClient.ets` 的 `autoScrapeTvEpisode`（Season 1 兜底路径已存在，行为一致性复核）。
- 测试：`entry/src/test/` 下弱语义文件名/刮削关联相关测试需补充 `~`/`_` 分隔与"无季信息默认季 1"用例。
- 不新增外部依赖、Cloud DB 模型或 API。
