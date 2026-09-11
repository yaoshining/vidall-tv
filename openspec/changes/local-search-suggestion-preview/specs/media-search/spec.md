## MODIFIED Requirements

### Requirement: 媒体搜索支持拼音首字母匹配

系统 SHALL 仅在本地文件源类搜索中 在用户输入拼音首字母时，从 `title_initials` 字段进行 LIKE 匹配。
`title_initials` SHALL 为 title 每个汉字拼音首字母（每字一个字母）的小写连续字符串（如"斗罗大陆" → `"dldl"`，"重庆森林" → `"cqsl"`），在刮削入库时同步写入。

#### Scenario: 输入首字母搜索到对应内容
- **WHEN** 用户搜索关键词为某媒体 title 各汉字拼音首字母的拼接（如 `"dldl"`）
- **THEN** 对应媒体出现在搜索结果中

#### Scenario: 首字母为关键词前缀时匹配
- **WHEN** 用户输入首字母前缀（如 `"dl"`）
- **THEN** title_initials 以该前缀开头的媒体出现在搜索结果中

#### Scenario: 单首字母前缀
- **WHEN** 本地库存在“花开锦绣”，用户输入 `H` 或 `h`
- **THEN** 系统 SHALL 匹配标题首字母前缀，包括单字母；不得扩展为任意中段或跳字匹配

