## MODIFIED Requirements

### Requirement: 媒体搜索支持拼音全拼匹配

系统 SHALL 仅在本地文件源类搜索中 在用户输入拼音全拼时，从 movies 和 tv_series 表的 `title_pinyin` 字段进行 LIKE 匹配，返回对应媒体内容。
`title_pinyin` SHALL 为 title 字段的无声调全小写拼音连续字符串（如"斗罗大陆" → `"douluodalu"`），在刮削入库时同步写入。

#### Scenario: 输入全拼搜索到对应内容
- **WHEN** 用户搜索关键词为某媒体 title 的全拼（如 `"douluodalu"`）
- **THEN** 对应媒体出现在搜索结果中

#### Scenario: 输入全拼部分片段也能匹配
- **WHEN** 用户搜索关键词为全拼的子串（如 `"douluo"`）
- **THEN** title_pinyin 中包含该子串的媒体出现在搜索结果中

#### Scenario: 全拼匹配大小写不敏感
- **WHEN** 用户输入大写全拼（如 `"DOULUODALU"`）
- **THEN** 系统将输入 toLowerCase() 后与 title_pinyin 匹配，结果不受大小写影响

### Requirement: 媒体搜索支持拼音首字母匹配

系统 SHALL 仅在本地文件源类搜索中 在用户输入拼音首字母时，从 `title_initials` 字段进行 LIKE 匹配。
`title_initials` SHALL 为 title 每个汉字声母的小写连续字符串（如"斗罗大陆" → `"dldl"`），在刮削入库时同步写入。

#### Scenario: 输入首字母搜索到对应内容
- **WHEN** 用户搜索关键词为某媒体 title 各汉字声母的拼接（如 `"dldl"`）
- **THEN** 对应媒体出现在搜索结果中

#### Scenario: 首字母为关键词前缀时匹配
- **WHEN** 用户输入首字母前缀（如 `"dl"`）
- **THEN** title_initials 以该前缀开头的媒体出现在搜索结果中

### Requirement: 搜索结果按相关度排序

仅对本地文件源类搜索，当 keyword 非空时，系统 SHALL 按相关度分层排序结果，次级按评分降序。
相关度优先级由高到低：完全匹配 → 标题前缀 → 标题包含 → 全拼前缀 → 首字母前缀 → 其他。
keyword 为空时，保持原有 rating DESC 排序不变。

#### Scenario: 完全匹配标题的结果排在最前
- **WHEN** 搜索词与某媒体 title 完全相等
- **THEN** 该媒体排在结果列表第一位

#### Scenario: 前缀匹配结果排在包含匹配之前
- **WHEN** 同时存在 title 以关键词开头的结果和 title 中间含关键词的结果
- **THEN** 前缀匹配的结果排列在包含匹配结果之前

#### Scenario: 无关键词时按评分降序
- **WHEN** 搜索 keyword 为空字符串
- **THEN** 结果按 rating 降序排列，与引入拼音功能前行为一致

## ADDED Requirements

### Requirement: 本地拼音质量回归

系统 SHALL 对中文、全拼、首字母与混合输入执行一致的规范化和可解释排序，并处理常见多音词与词段边界；短首字母不得因过度模糊匹配让大量无关结果挤占前列。具体阈值依据可回归样例集确定，不改变既有标题优先层级。

#### Scenario: 混合输入和多音词
- **WHEN** 使用覆盖中文、大小写全拼、首字母、常见混合输入及多音词的固定样例集检索本地库
- **THEN** 典型漏召回得到修复，既有正确命中保持，记录预期命中和排序以证明没有明显放大噪声

#### Scenario: 短首字母控制
- **WHEN** 输入短首字母且有大量潜在模糊候选
- **THEN** 合理前缀匹配保持可用，无关模糊结果不挤占相关结果前列

#### Scenario: 服务器不使用本地拼音规则
- **WHEN** 当前来源是影视服务器
- **THEN** 不要求为该实例建立本地拼音索引，也不套用本地排序替代服务端检索
