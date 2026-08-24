## Context

见 proposal.md - Why。v1（`fix-tv-episode-default-season-one`）已修复刮削阶段的默认季逻辑，但用户删除系列后重刮削仍发现 `重器/01~4K.mp4` 一类文件只显示部分集数（29-33），其余（1-28）缺失。

本轮根因在更早的**分类阶段**：`ScrapeClient.parseFileName` 的 title 清洗只清除 `[._-]`，遗漏了 `~`。`01~4K.mp4` → `title='01~'`，`isWeakSemanticTitleText('01~')` 返回 false（cleanedTitle 长度=2）→ 被当作有语义标题 → 走 movie 评分（+60）。而路径 `TV Series` 提供 tv 信号（+60），60:60 落入 `conflicting-signals` → 分类为 `unknown` → 不进入剧集刮削。

## Goals / Non-Goals

**Goals:**
- 让 `parseFileName` 在 title 清洗时把 `~` 视为分隔符，输出 `01` 而非 `01~`。
- 使 `01~4K.mp4` 这类波浪线分隔文件在 TV 路径下分类为 `tv`，进而进入剧集刮削并触发 v1 的默认第一季兜底。

**Non-Goals:**
- 不改动画册/电影刮削判断的其余逻辑。
- 不改变 `SxxExx`、空格分隔、电影名等既有解析行为。
- 不新增依赖或数据模型。

## Decisions

**Decision 1：在 parseFileName 的 title 清洗中加入 `~`**
`ScrapeClient.parseFileName` 中 title 清洗由 `.replace(/[._-]/g, ' ')` 改为 `.replace(/[._~-]/g, ' ')`。

- 理由：`~` 是无意义分隔符，清理后 `01~4K.mp4` 的标题为 `01`，为纯数字弱语义；`parseFileName` 返回的 `mediaType` 仍为 `movie`（无标准 SxxExx），但分类器 `classifyMediaType` 会因弱语义标题不再给 movie 分，结合路径 tv 信号分类为 `tv`。
- 备选：在 `isWeakSemanticTitleText` 里额外忽略 `~`。但该函数语义是"标题文本是否弱语义"，由 `parseFileName` 产出正确标题后再判定更干净；且 `01~4K` 中 `~` 本应属于分隔符，清洗归属 `parseFileName` 更符合职责分离。
- 风险：`~` 在部分标题中有含义？实际为 NAS/下载站常见的质量/命名分隔标记，无害。

**Decision 2：复用分类器既有路径 tv 信号**
不额外改动 `classifyMediaType` 的评分阈值。修复 title 清洗后，`01~4K.mp4` 弱语义标题不再贡献 movie 分，`tvScore=60, movieScore=0`，命中现有 `tvScore > 0 && movieScore === 0` → `path-tv-semantics` 分支返回 `tv`。

## Risks / Trade-offs

- [影响面] `parseFileName` 为全局共享函数 → Mitigation：改动仅为清洗增强（`[._-]` → `[._~-]`），仅影响含 `~` 的标题，正常 `SxxExx`/空格/电影名不受影响；需补充回归用例。
- [标题含 `~` 有语义] 极少数用例标题本身含 `~` → Mitigation：`~` 多为分隔符，风险极低；若后续发现可再收敛。

## Migration Plan

无数据迁移。纯行为修复，随应用版本发布；可回滚为 `[._-]` 清洗。

## Open Questions

无。
