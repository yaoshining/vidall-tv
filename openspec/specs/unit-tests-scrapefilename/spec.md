# unit-tests-scrapefilename

## Purpose

验证 `parseFileName` 与 `buildSearchTitles` 函数在各类边界文件名场景下的解析行为，包括发布组名称残留、无年份文件名及中英混合标题处理。

## Requirements

### Requirement: parseFileName 处理发布组名称残留
当文件名末尾带有 `-GroupName` 形式的发布组标识时，`parseFileName` 提取的 title SHALL 不包含该发布组字符串。

#### Scenario: 英文电影文件名带发布组后缀
- **WHEN** 输入 `'The.Dark.Knight.2008.1080p.BluRay.x264-YIFY.mkv'`
- **THEN** `title` 为 `'The Dark Knight'`，`year` 为 `2008`，`mediaType` 为 `'movie'`

#### Scenario: 剧集文件名带发布组后缀
- **WHEN** 输入 `'Breaking.Bad.S01E01.1080p.BluRay-GROUP.mkv'`
- **THEN** `title` 为 `'Breaking Bad'`，`seasonNumber` 为 `1`，`episodeNumber` 为 `1`

### Requirement: parseFileName 处理无年份的电影文件名
部分文件名不含年份，`parseFileName` SHALL 仍能提取正确的 title，`year` 返回 `undefined`。

#### Scenario: 无年份的中文电影文件名
- **WHEN** 输入 `'流浪地球.4K.mkv'`
- **THEN** `title` 为 `'流浪地球'`，`year` 为 `undefined`

### Requirement: buildSearchTitles 中英混合标题只取英文
当 title 同时含有中文和英文时，`buildSearchTitles` SHALL 只返回英文部分作为候选词。

#### Scenario: 中英混合标题
- **WHEN** 输入 `'权力的游戏 Game of Thrones'`
- **THEN** 返回数组包含 `'Game of Thrones'`，不包含中文部分

#### Scenario: 纯中文标题
- **WHEN** 输入 `'权力的游戏'`
- **THEN** 返回数组包含 `'权力的游戏'`

#### Scenario: 纯英文标题
- **WHEN** 输入 `'Game of Thrones'`
- **THEN** 返回数组包含 `'Game of Thrones'`

### Requirement: 弱语义分类样本必须纳入回归测试

单元测试套件 SHALL 维护弱语义文件名与路径样本集，覆盖 `movie`、`tv`、`unknown` 三类分类结果，并作为后续规则迭代的长期回归基线。

#### Scenario: TV 弱语义样本可稳定回归
- **WHEN** 测试样本包含文件名 `19 4K.mp4` 且路径为 `/电视剧/狂飙/Season 1/19 4K.mp4`
- **THEN** 该样本的期望分类结果为 `tv`

#### Scenario: unknown 弱语义样本可稳定回归
- **WHEN** 测试样本包含文件名 `22 4K.mp4` 且路径为 `/下载/未整理/22 4K.mp4`
- **THEN** 该样本的期望分类结果为 `unknown`

### Requirement: 新误判样本必须沉淀到测试样本集中

系统 SHALL 在发现新的"识别不了/识别错误"样本时，将该样本补充进单元测试样本集，并把该样本的期望结果纳入回归验证。

#### Scenario: 修复误判时同步补录样本
- **WHEN** 团队发现新的弱语义文件误判案例
- **THEN** 对应修复必须同时包含该样本的单元测试或测试样本表更新
