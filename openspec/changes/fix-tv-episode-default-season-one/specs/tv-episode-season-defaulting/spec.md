## Purpose

定义当 TV 剧集的目标文件无法从文件名或父目录解析出季号时，刮削流程默认按第一季补全并关联到剧集季信息，确保单层无季目录（如 `重器/01~4K.mp4`）的剧集不被当作裸 tv 处理。

## ADDED Requirements

### Requirement: 无季信息时默认按第一季补全
当目标文件被分类为 `tv`，且文件名与父目录均无法解析出季号时，刮削流程 SHALL 默认按第一季（season 1）处理，并关联到剧集的季/集信息，而非仅作为裸 `tv` 入库。

#### Scenario: `01~4K.mp4` 无季信息默认第一季
- **WHEN** 扫描 `重器/`（无季子目录），目标文件 `01~4K.mp4` 被分类为 `tv`，文件名与父目录 `重器` 均无法解析出季号
- **THEN** 刮削按 first season（S1）调用 `autoScrapeTvEpisode`，并将结果关联到该剧集第一季，`scrape_info` 记录 `seasonNumber=1`

#### Scenario: `01_4K.mp4` 弱语义文件名提取集数后默认第一季
- **WHEN** 目标文件 `01_4K.mp4` 被分类为 `tv`，且父目录无法解析出季号
- **THEN** 集数提取结果为 1，季号默认补全为 1，刮削关联到剧集 S1E1

### Requirement: 弱语义文件名支持波浪线/下划线/连字符分隔
`extractEpisodeNumberFromWeakSemanticFileName` SHALL 能从 `01~4K.mp4`、`01_4K.mp4`、`01-4K.mp4` 这类以 `~`、`_`、`-` 分隔质量标签的弱语义文件名中提取集数（如 1），与 `01 4K.mp4`（空格分隔）保持一致行为。

#### Scenario: `01~4K.mp4` 提取集数 1
- **WHEN** 调用 `extractEpisodeNumberFromWeakSemanticFileName('01~4K.mp4')`
- **THEN** 返回 1

#### Scenario: `01_4K.mp4` 提取集数 1
- **WHEN** 调用 `extractEpisodeNumberFromWeakSemanticFileName('01_4K.mp4')`
- **THEN** 返回 1

#### Scenario: 纯年份文件名不误判为集数
- **WHEN** 调用 `extractEpisodeNumberFromWeakSemanticFileName('2024.mp4')`
- **THEN** 返回 `undefined`（过滤 1900-2099 年份）
