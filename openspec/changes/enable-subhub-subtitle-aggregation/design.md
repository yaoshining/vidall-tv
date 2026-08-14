# Design: enable-subhub-subtitle-aggregation

## Context

当前在线字幕链路（`SubtitleAcquisitionService` → `OpenSubtitlesClient` → `SubtitleDownloader`）只接 OpenSubtitles 一个源，`OpenSubtitlesClient.resolveBaseUrl()` 按 `OPENSUBTITLES_API_KEY` 是否存在在「官方代理 Worker」与「直连」之间切换。`SubHubClient` 已在演示阶段落地（`entry/src/main/ets/lib/SubHubClient.ets`），能对 SubHub 做搜索与下载，但尚未接入正式字幕链路。动机见 proposal.md - Why，行为契约见 specs。

## Goals / Non-Goals

**Goals**
- 让字幕获取服务按「有无 OS Key」选择 provider 集合并聚合结果、按来源分派下载。
- 结果可区分来源（`opensubtitles` / `subhub`），UI 可展示来源 chip。
- 保持现有 `SubtitleAcquisitionService` 对 UI 的调用形态（`search(input)` / `download(input)`）基本不变，把复杂度收在 service 层。

**Non-Goals**
- 不实现会员/免费额度门控（账户体系未建立，见 proposal 延后项）。
- 不删除 `proxy/opensubtitles-worker` 与 `OS_PROXY_BASE_URL`。
- 不改动 `SubtitleCacheManager` / `SubtitleDispatcher` 的既有缓存语义（仅新增 `source: 'subhub'` 取值）。
- 不把 Caller Key 迁移到 BuildProfile/secret（本次仍用 AppEnv 常量）。

## Decisions

### 1. Provider 抽象 + 解析器（而非在 service 内 if/else）
新增 `SubtitleProvider` 接口与 `OpenSubtitlesSubtitleProvider` / `SubHubSubtitleProvider` 两个实现，`SubtitleProviderResolver` 负责产出 provider 列表。
- **为什么**：两个 provider 的搜索/下载形态差异大（OS 是「查 link 再下载」、SubHub 是「GET 二进制」），接口化后 service 层只关心聚合与分支，且为将来接入 `EntitlementService` 的额度/会员判断留了插入点。
- **备选**：直接在 `search/download` 里 if/else —— 简单，但把两类来源的字段映射和错误处理混在一起，测试与后续扩展都差。

### 2. 统一 `SubtitleSearchResult`，用 `source` + 可选字段做判别
`SubtitleSearchResult` 改为本地统一定义：`source: 'opensubtitles' | 'subhub'`，OS 结果用 `fileId`、SubHub 结果用 `subtitleRef`（其余 `subtitleId/fileName/languageCode/downloadCount` 共用）。
- **为什么**：UI 需要一个单一列表展示两类结果，字段复用能最小化 `SubtitleSelectorDrawerDialog` 的改动。
- **备选**：`source` + 判别联合类型（discriminated union）—— 类型更严，但 ArkTS 对复杂联合类型支持有限，且现有 UI 用 `result.fileId` 等扁平访问，union 会带来大量收窄代码。

### 3. 并发聚合 + 每 provider 独立降级（partial 语义）
`search` 用 `Promise.all` 并发调用 provider，每个 provider 单独 `catch` 后记 `hilog.warn` 并返回空数组；全部失败才抛错。顺序固定 OS 在前、SubHub 在后。
- **为什么**：SubHub 上游（如 xunlei）可能超时/跳过，OpenSubtitles 结果仍应正常返回，不能因单源失败整体报错；并发降低搜索延迟。
- **备选**：串行 —— 简单但延迟叠加，且任一源失败会打断后续。

### 4. 客户端内容指纹去重（OS 优先）
新增 `SubtitleDeduplicator`，key = `normalize(fileName) + ':' + languageCode`，normalize 做 lowercase/trim/去扩展名/去发布组标记；碰撞保留 `source=opensubtitles`。
- **为什么**：SubHub 不支持 `exclude_providers`（见 `.plans/reference/plan-subhubApiSurvey.md`），有 Key 时两个源会返回大量重叠结果；OS 结果带真实 `downloadCount`，信息更丰富，故优先保留。
- **备选**：不去重 —— 结果噪音大；服务端过滤 —— API 未提供。

### 5. 下载按 `source` 分派，SubHub 复用现有落盘路径规范
OS 走现有 `SubtitleDownloader.download(fileId, ...)`；SubHub 走 `SubHubClient.download(subtitleRef, fallback)` 拿 `ArrayBuffer`，再用 `SubtitleDownloader` 已导出的 `buildSubtitleDir/buildSubtitlePath/sha256Hex` 落盘（把「mkdir + write ArrayBuffer + close」抽成一个共享 helper，避免两处重复 fs 代码）。文件名优先 `Content-Disposition`（`SubHubClient` 已实现），回退 `releaseName.format`，再回退 `subtitle.srt`。
- **为什么**：SubHub 下载是「GET 二进制」而非「POST 拿 link」，不能复用 `SubtitleDownloader.download` 的 OS 语义；但落盘目录/命名必须与 OS 一致，才能让 `SubtitleCacheManager` / `SubtitleDispatcher` 无感复用。
- **风险规避**：SubHub `format` 字段不可靠（已提 issue #200），因此下载文件名不信任 `format`，以 `Content-Disposition` 为准。

### 6. Caller Key 用 AppEnv 常量（临时）
新增 `AppEnv.SUBHUB_API_KEY`（当前为 `subhub_live_...`），`SubHubClient` 构造默认取它。账户体系建立后迁到 BuildProfile/secret。
- **为什么**：SubHub 是开发者自建的网关，Caller Key 是开发者级凭据（不同于用户自填的 OS Key），本次无账户体系，先用常量最简。
- **风险**：明文进 git —— 与现有 TMDB key、OS 代理 secret 同等级，已在 proposal 标注迁移计划。

### 7. 错误归类扩展（不新增独立错误类型）
`classifyAcquisitionError` 增加对 `SubHubApiError` / `SubHubNetworkError` 的映射（见 proposal 的映射表），产出 `subhub_*` 四个新 kind；UI 的 `toastMessageForAcquisitionError` 增加对应文案。搜索 `NO_RESULTS` 已在 `SubHubClient.search` 内转空数组，不算错误。
- **为什么**：复用现有「具体异常 → kind → Toast」链路，UI 只需加 case，不引入新的错误传递协议。

## Risks / Trade-offs

- [SubHub 上游 provider 超时/跳过（如 xunlei timeout）] → 聚合层按 partial 处理，OpenSubtitles 结果照常返回；`SubHubClient.search` 已把 `provider_failures` 与 `results` 分离，不影响主流程。
- [Caller Key 明文泄漏] → proposal 已标注后续迁移 BuildProfile/secret；本次不引入。
- [去重误删] → normalize 后仍歧义的 key 会视为不同而都保留（宁多勿删）；后续如需更激进去重再收紧 normalize。
- [SubHub 下载文件名缺失] → 三级回退（Content-Disposition → releaseName.format → subtitle.srt），保证总能落盘。
- [OS Key 失效（401）] → OS provider 失败被降级记录，SubHub 结果仍返回；若 SubHub 也失败才整体报错。

## Migration Plan

- 无数据迁移：`OPENSUBTITLES_API_KEY` 等 PrefKey 语义不变，仅「无 Key 时走 SubHub」的行为变化。
- 部署：正常构建 `assembleHap` 装机即可；行为从「无 Key → OS 代理」切换为「无 Key → SubHub」。
- 回滚：revert 本分支即可恢复旧行为；OS 代理 Worker 仍在线，代码未删，可随时切回。

## Open Questions

- 是否在后续删除 `proxy/opensubtitles-worker` 与 `OS_PROXY_BASE_URL`（取决于是否还有其它调用方），留待用户决定。
- 会员/免费每日额度如何叠加（依赖账户体系与 `entitlement-architecture` 的 `EntitlementService` 落地），本次不决策。
