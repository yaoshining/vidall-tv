## Context

见 proposal.md - Why。当前默认季逻辑（`entry/src/main/ets/utils/VideoScrapeProcessor.ets` 的 `processVideoScrape`）为：

```
explicitSeasonNum = explicitEpisodeNum !== undefined ? (directorySeasonNum ?? 1) : undefined;
```

该表达式将「默认季 1」绑定在「必须先用弱语义逻辑提取到集数」上。一旦 `extractEpisodeNumberFromWeakSemanticFileName` 提取失败（`01~4K.mp4` 数字后跟 `~` 非空格/结尾），`explicitEpisodeNum` 为空，`explicitSeasonNum` 也为空，`autoScrapeTvEpisode` 因而无法获得季号（`effectiveSeasonNumber = parsed.seasonNumber = undefined`），刮削退化为裸 `tv`。

`autoScrapeTvEpisode` 内部已有 `effectiveSeasonNumber = explicitSeasonNumber ?? (explicitEpisodeNumber !== undefined ? 1 : parsed.seasonNumber)`，说明 Season 1 兜底能力已存在于刮削层，缺的是入口把它正确传递。

## Goals / Non-Goals

**Goals:**
- 修复 `extractEpisodeNumberFromWeakSemanticFileName`，使 `01~4K/01_4K/01-4K` 也能提取集数。
- 将「无季信息默认季 1」从「依赖集数提取成功」解耦：目标分类为 `tv` 且文件名为非标准季集命名（无 `SxxExx`）时，季号恒为 `directorySeasonNum ?? 1`。

**Non-Goals:**
- 不改动画册、电影刮削逻辑。
- 不改变混合目录 `seasonSiblingDetected`、显式 `SxxExx`、含季号目录名的行为。
- 不新增外部依赖或数据模型。

## Decisions

**Decision 1：集数提取正则放宽分隔符**
`extractEpisodeNumberFromWeakSemanticFileName` 的纯数字分支由 `/^(\d{1,3})(?:\s|$)/` 扩展为允许 `~`、`_`、`-`、空格作为数字与质量标签之间的分隔，例如 `/^(\d{1,3})(?:[\s~_\-]|$)/`。仅匹配开头的 1-3 位数字，仍保留 1900-2099 年份过滤与 >999 上限过滤，避免误判。

- 备选：直接在 parseFileName 层支持。但弱语义集数提取在入口分类后需要独立确定集号，改动最小且职责清晰的落点是该函数本身。
- 风险：放宽分隔可能把 `2024-01-01` 这类日期误判为集数 → 靠年份区间过滤（2024 落入 1900-2099）规避。

**Decision 2：默认季 1 与集数提取解耦**
在 `processVideoScrape`，当 `parseFileName` 未解析出标准季号时，向 `autoScrapeTvEpisode` 传入显式季号 `directorySeasonNum ?? 1`，不再依赖 `explicitEpisodeNum` 是否非空：

```
const hasStandardSeason = parsedFileName.seasonNumber !== undefined;
const explicitSeasonNum = hasStandardSeason ? undefined : (directorySeasonNum ?? 1);
```

- `SxxExx` 文件：`parsedFileName.seasonNumber` 有值 → 不传 `explicitSeasonNum`，由 `autoScrapeTvEpisode` 使用 `parsed.seasonNumber`，避免覆盖成 1。
- 弱语义文件：无标准季号 → 恒传 `directorySeasonNum ?? 1`，默认第一季兜底生效。
- 备选：改成「只依赖 mediaType==='tv'」。但带标准 `SxxExx` 的文件不能被硬编码成季 1，故必须以「是否已有标准季号」为界，而非以「是否提得到集数」为界。

## Risks / Trade-offs

- [集数误判] 放宽分隔符可能匹配到日期/版本号 → Mitigation：保留 1900-2099 年份过滤与 >999 上限；仅在字符串开头匹配数字。
- [目录名带季号但季号提取异常] 如父目录含多季元数据 → Mitigation：沿用 `extractSeasonNumberFromDirectoryName` 既有逻辑，仅复用其结果，不改变其判定。
- [Season 1 实际不存在] 极少数剧集以 Season 0（Specials）开头 → Mitigation：TMDB 调研显示绝大多数剧集存在 Season 1；`fetchSeason(1)` 失败时维持现有 `season=null` 处理，不回归。

## Migration Plan

无数据迁移。改动为纯行为修复，随应用版本发布；可回滚为先前的 `explicitSeasonNum` 依赖表达式。

## Open Questions

无。
