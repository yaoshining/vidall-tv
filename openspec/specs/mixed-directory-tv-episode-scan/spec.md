# Mixed Directory TV Episode Scan

## Purpose

定义扫描器在混合目录结构（同时包含根层视频文件和季子目录）下的媒体类型分类行为，确保根层弱语义文件能被正确识别为 TV 剧集并进入刮削流程。

## Requirements

### Requirement: 混合目录结构下根层分集必须被识别为 TV
当扫描目录同时包含根层视频文件（弱语义文件名）和季子目录（如 `第一季`、`Season 1`）时，扫描器 SHALL 将根层视频文件的媒体类型识别为 `tv`，而非 `unknown`，并进入剧集刮削流程。

#### Scenario: 根层弱语义文件在存在季子目录时被分类为 tv
- **WHEN** 扫描目录 `/蜜语纪/`，该目录包含 `19.mp4`（根层）和子目录 `第一季/`
- **THEN** `classifyVideoScrapeTarget('19.mp4', '/蜜语纪/19.mp4', { seasonSiblingDetected: true })` 返回 `mediaType: 'tv'`

#### Scenario: 不含季子目录时弱语义文件保持 unknown
- **WHEN** 扫描目录 `/电影合集/`，该目录包含 `19.mp4` 但无任何季子目录
- **THEN** `classifyVideoScrapeTarget('19.mp4', '/电影合集/19.mp4', { seasonSiblingDetected: false })` 返回 `mediaType: 'unknown'`（原有行为不变）

---

### Requirement: 扫描器在发现季子目录时向根层文件注入 seasonSiblingDetected
`VideoScannerUtil.scanDir` SHALL 在列出当前目录内容后，检查子目录列表中是否存在命中 `isSeasonDirectorySegment` 的条目；若存在，则对当前层（depth 不变）的视频文件分类时传入 `seasonSiblingDetected: true`。

#### Scenario: 含第一季子目录的根层文件获得 seasonSiblingDetected=true
- **WHEN** 扫描 `蜜语纪/`，子目录列表包含 `第一季`
- **THEN** 扫描器对 `蜜语纪/19.mp4` 调用分类时传入 `seasonSiblingDetected: true`

#### Scenario: 无季子目录时不注入 seasonSiblingDetected
- **WHEN** 扫描某目录，子目录列表中无 `第X季` / `Season N` 结构
- **THEN** 扫描器对本层视频文件调用分类时不传入 `seasonSiblingDetected`（或传 `false`）

---

### Requirement: 配置根目录名作为候选 seriesHint 传递给根层弱语义文件
当 `extractSeriesHintFromFilePath` 对根层弱语义文件返回 `undefined` 或空值时，扫描器 SHALL 将配置目录路径末段（如 `蜜语纪`）作为 `seriesHint` 传入刮削流程。

#### Scenario: 根层弱语义文件使用配置目录名刮削剧集
- **WHEN** 配置目录为 `/nas/蜜语纪`，根层文件 `19.mp4` 被识别为 tv，`extractSeriesHintFromFilePath` 返回 `蜜语纪`
- **THEN** 刮削调用 `autoScrapeTvEpisode('19.mp4', '蜜语纪', 'tv')` 并返回匹配剧集的第 19 集信息

#### Scenario: 根层弱语义文件成功刮削后出现在剧集列表
- **WHEN** 混合结构目录完整扫描后，`19.mp4`、`20.mp4`、`21.mp4`、`22.mp4` 被刮削为同一剧集条目的第 19-22 集
- **THEN** 剧集列表显示完整 1-30 集，无缺失
