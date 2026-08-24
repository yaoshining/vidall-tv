## Why

在用 `~/Videos/TV Series/重器/01~4K.mp4` 这类文件名删除剧集信息后重刮削时，季详情页只显示部分集（如 29-33），其余集（如 1-28）缺失。根因是 `parseFileName` 的 title 清洗正则遗漏了 `~` 字符，导致 `01~4K.mp4` 解析出的标题为 `01~`（带多余 `~`），被误判为"有语义标题"（`isWeakSemanticTitleText` 返回 false），进而因路径 tv 信号与文件名 movie 信号冲突被归类为 `unknown`，未进入剧集刮削流程。

## What Changes

- 修复 `ScrapeClient.parseFileName` 的 title 清洗：将清洗分隔符集 `[._-]` 扩展为 `[._~-]`，使 `01~4K.mp4` 解析出的标题为 `01`（纯数字弱语义），而非 `01~`。
- 修复后 `01~4K.mp4` 标题为弱语义，不再贡献 movie 评分，结合 `TV Series` 路径 tv 信号被分类为 `tv`，从而进入剧集刮削并触发该系列已落地的默认第一季兜底。
- 保证 `重器/01~4K.mp4` 这类波浪线分隔文件在删除后重刮削能被完整识别并进入季详情页，不再出现集数缺失。
- 不影响标准 `SxxExx`、空格分隔、电影名等既有文件名解析行为（仅清洗 `~`，属纯增强）。

## Capabilities

### New Capabilities

- `tv-episode-tilde-title-classification`: 定义文件名解析器在标题清洗时将 `~` 作为分隔符处理，确保波浪线分隔的弱语义文件名能被正确分类为 TV 剧集并进入刮削。

### Modified Capabilities

## Impact

- 入口：`entry/src/main/ets/lib/ScrapeClient.ets` 的 `parseFileName`（title 清洗正则）。
- 分类链路：`entry/src/main/ets/lib/MediaTypeClassifier.ets` 的 `classifyMediaType`（消费 `parseFileName` 的 title，行为随清洗增强而修正）。
- 测试：`entry/src/test/ScrapeClient.test.ets` 需补充 `01~4K.mp4` title 解析为 `01` 及分类为 tv 的用例。
- 不新增外部依赖、Cloud DB 模型或 API。
