# Media Search

## Purpose

定义媒体搜索能力中与拼音搜索相关的行为约束，包括拼音全拼/首字母匹配、拼音字段在入库与升级时的写入，以及搜索结果按相关度排序的规则。

## Requirements

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
- **THEN** 系统按本地搜索统一规则规范化输入后与 title_pinyin 匹配，包括全角字符转换、转小写、声调去除和常见分隔符移除，结果不受这些输入差异影响

#### Scenario: 带声调和分隔符的全拼输入
- **WHEN** 用户输入 `"CHÓNG-QING"` 或全角 `"ＣＨＯＮＧ－ＱＩＮＧ"`
- **THEN** 输入规范化为 `"chongqing"`，能够匹配具有该全拼的媒体，与连续小写全拼输入的结果一致

---

### Requirement: 媒体搜索支持拼音首字母匹配

系统 SHALL 仅在本地文件源类搜索中 在用户输入拼音首字母时，从 `title_initials` 字段进行 LIKE 匹配。
`title_initials` SHALL 为 title 每个汉字声母的小写连续字符串（如"斗罗大陆" → `"dldl"`），在刮削入库时同步写入。

#### Scenario: 输入首字母搜索到对应内容
- **WHEN** 用户搜索关键词为某媒体 title 各汉字声母的拼接（如 `"dldl"`）
- **THEN** 对应媒体出现在搜索结果中

#### Scenario: 首字母为关键词前缀时匹配
- **WHEN** 用户输入首字母前缀（如 `"dl"`）
- **THEN** title_initials 以该前缀开头的媒体出现在搜索结果中

---

### Requirement: 拼音字段在刮削入库时同步写入

系统 SHALL 在 `upsertMovie` 和 `upsertTvSeries` 时，对 title 字段调用 PinyinUtil 计算并写入 `title_pinyin`、`title_initials`。

#### Scenario: 新增电影时写入拼音字段
- **WHEN** 调用 `upsertMovie` 写入一部中文 title 电影
- **THEN** movies 表对应行的 `title_pinyin` 和 `title_initials` 均为非空值

#### Scenario: 更新电视剧时更新拼音字段
- **WHEN** 调用 `upsertTvSeries` 更新剧集 title
- **THEN** tv_series 表对应行的拼音字段随 title 同步更新

#### Scenario: title 为空时拼音字段写入空字符串
- **WHEN** 调用 upsert 时 title 为 undefined 或空字符串
- **THEN** 对应拼音字段写入空字符串或 NULL，不报错

---

### Requirement: 存量数据在 DB 升级时批量回填拼音字段

系统 SHALL 在数据库从 v10 升级至 v11 时，对 movies 和 tv_series 表中所有已有 title 的行批量计算并写入 `title_pinyin`、`title_initials`。

#### Scenario: 升级后存量电影拼音字段非空
- **WHEN** 数据库从 v10 升级到 v11 且 movies 表有存量数据
- **THEN** 所有 title 非空的电影行，title_pinyin 和 title_initials 均被正确回填

#### Scenario: 回填过程中单行异常不中断整体升级
- **WHEN** 某行 title 计算拼音时发生异常
- **THEN** 该行记录错误日志，继续处理下一行，整体迁移不失败

---

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
