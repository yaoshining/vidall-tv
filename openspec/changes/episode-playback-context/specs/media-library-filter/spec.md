## MODIFIED Requirements

### Requirement: 媒体库聚合列表只展示有刮削信息的条目
系统 SHALL 让媒体库最近添加与同类聚合列表只展示有 `scrape_info` 的视频条目。

#### Scenario: 无 scrape_info 的视频不出现在最近添加
- **WHEN** 某视频记录没有关联的 `scrape_info`
- **THEN** 该视频不出现在最近添加结果中

#### Scenario: 有 scrape_info 的视频仍出现在媒体库列表
- **WHEN** 某视频记录存在关联的 `scrape_info`
- **THEN** 该视频仍可出现在媒体库聚合列表中

---

### Requirement: 已刮削但缺少海报的条目仍然保留
当条目已有 `scrape_info` 但没有可用海报时，系统 SHALL 保留该条目，由 UI 使用标题等文本信息兜底。

#### Scenario: 无海报但已有刮削信息的条目仍保留
- **WHEN** `scrape_info` 存在，但海报字段为空
- **THEN** 该条目仍会出现在媒体库结果中，供 UI 以标题兜底展示

---

### Requirement: 未刮削视频仍可通过文件浏览器访问
系统 SHALL 不影响文件浏览器路径对未刮削视频的访问与播放。

#### Scenario: 文件浏览器仍展示未刮削视频文件
- **WHEN** 用户从文件源进入文件浏览器
- **THEN** 仍可看到并播放未刮削的视频文件
