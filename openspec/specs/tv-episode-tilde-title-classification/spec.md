# tv-episode-tilde-title-classification Specification

## Purpose

定义文件名解析器在标题清洗时把 `~` 视为分隔符处理，从而使 `01~4K.mp4` 这类波浪线分隔的弱语义文件名能被正确分类为 TV 剧集并进入刮削流程，修复删除剧集信息后重刮削时部分集数缺失的问题。

## Requirements

### Requirement: 文件名标题清洗将波浪线作为分隔符
`parseFileName` 在解析文件标题时 SHALL 将 `~` 视为与 `.`、`_`、`-` 同等地位的清洗分隔符，使 `01~4K.mp4` 解析出的标题为 `01`（纯数字弱语义），而非 `01~`。

#### Scenario: `01~4K.mp4` 标题解析为 01
- **WHEN** 调用 `parseFileName('01~4K.mp4')`
- **THEN** 返回的 `title` 为 `01`，且 `mediaType` 仍为 `movie`（无标准季集标记）

#### Scenario: 标准季集文件名不受影响
- **WHEN** 调用 `parseFileName('Breaking.Bad.S01E01.1080p.mkv')`
- **THEN** 返回的 `seasonNumber=1`、`episodeNumber=1`、`mediaType='tv'`，标题清洗不受 `~` 改动影响

### Requirement: 波浪线分隔弱语义文件被分类为 TV
当 `parseFileName` 解析出弱语义标题（如 `01`）且路径提供 TV 语义信号（如 `TV Series`）时，分类器 SHALL 将该文件分类为 `tv`，使其进入剧集刮削流程，而非因文件名/路径信号冲突归为 `unknown`。

#### Scenario: `01~4K.mp4` 在 TV Series 路径下分类为 tv
- **WHEN** 对 `/Videos/TV Series/重器/01~4K.mp4` 调用 `classifyVideoScrapeTarget('01~4K.mp4', filePath, context)`
- **THEN** 返回 `mediaType: 'tv'`（不再为 `unknown`/`movie`），进入剧集刮削并触发默认第一季兜底
