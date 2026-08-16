## ADDED Requirements

### Requirement: 字幕搜索结果必须展示来源标记

系统 SHALL 在字幕搜索抽屉的每条结果行展示来源标记，用于区分字幕来自 OpenSubtitles 直连还是 SubHub。`source=opensubtitles` 的结果 SHALL 展示「直连」标记，`source=subhub` 的结果 SHALL 展示「SubHub」标记，两者使用不同颜色区分。

#### Scenario: 展示直连来源标记
- **WHEN** 搜索结果包含 `source=opensubtitles` 的条目
- **THEN** 该条目展示「直连」来源标记

#### Scenario: 展示 SubHub 来源标记
- **WHEN** 搜索结果包含 `source=subhub` 的条目
- **THEN** 该条目展示「SubHub」来源标记
- **AND** 与「直连」标记颜色可区分
