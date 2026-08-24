## 1. 修复弱语义集数提取

- [x] 1.1 在 `entry/src/main/ets/utils/VideoScannerHelpers.ets` 的 `extractEpisodeNumberFromWeakSemanticFileName`，将纯数字分支正则 `/^(\d{1,3})(?:\s|$)/` 扩展为允许 `~`、`_`、`-` 分隔，如 `/^(\d{1,3})(?:[\s~_\-]|$)/`，并保留 1900-2099 年份过滤与 >999 上限过滤。验证：对该函数补充 `01~4K.mp4`→1、`01_4K.mp4`→1、`01-4K.mp4`→1、`2024.mp4`→undefined 的测试并运行通过。

## 2. 解耦默认季 1

- [x] 2.1 在 `entry/src/main/ets/utils/VideoScrapeProcessor.ets` 的 `processVideoScrape`，将 `explicitSeasonNum` 改为以「是否已解析出标准季号」为界：当 `parsedFileName.seasonNumber === undefined` 时传 `directorySeasonNum ?? 1`，否则传 `undefined`（不覆盖标准 `SxxExx` 季号）。验证：`重器/01~4K.mp4` 走 tv 分支时最终调用 `autoScrapeTvEpisode(..., explicitSeasonNumber=1)`。
- [x] 2.2 复核 `entry/src/main/ets/lib/ScrapeClient.ets` 的 `autoScrapeTvEpisode`：确认传入 `explicitSeasonNumber=1` 时 `effectiveSeasonNumber=1`、`effectiveEpisodeNumber` 取显式集数或 `parsed.episodeNumber`，Season 1 兜底可正确触发 fetchSeason/fetchEpisode。验证：确认无改动即可满足，或以注释说明既有兜底直接复用。

## 3. 补充/更新测试

- [x] 3.1 在 `entry/src/test/` 中更新或新增 `extractEpisodeNumberFromWeakSemanticFileName` 相关用例，覆盖 `01~4K`、`01_4K`、`01-4K` 及年份过滤。
- [x] 3.2 在 `entry/src/test/` 中新增或更新 TV 剧集刮削关联用例，断言无季信息时 `scrape_info.seasonNumber=1`，且 `重器/01~4K.mp4` 关联到第一季而非裸 `tv`。验证：本地单测构建 `UnitTestBuild` 通过。

## 4. 收尾验证

- [x] 4.1 运行 `openspec validate --change fix-tv-episode-default-season-one`，确认 delta spec 符合校验规则。
- [x] 4.2 汇总变更说明（改了什么、为什么、影响范围、如何验证、残余风险）。
