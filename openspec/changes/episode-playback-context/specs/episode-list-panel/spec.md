## MODIFIED Requirements

### Requirement: PlayerSettingsDialog 在媒体库上下文中显示选集区块
当 `videoPlayerController.playbackContext` 是 `MediaLibraryContext` 时，播放器设置面板 SHALL 在顶部显示 `选集` 区块；当不存在媒体库上下文时，设置面板 SHALL 保持原有结构，不显示该区块。

#### Scenario: MediaLibraryContext 时显示选集区块
- **WHEN** 播放器携带 `MediaLibraryContext` 打开设置面板
- **THEN** 面板顶部显示标题为 `选集` 的区块

#### Scenario: 无媒体库上下文时不显示选集区块
- **WHEN** `playbackContext` 为 `undefined` 或 `FileExplorerContext`
- **THEN** 设置面板中不显示 `选集` 区块

---

### Requirement: 选集区块按当前实现展示两段分页
`EpisodeListPanel` SHALL 展示当前季剧集，并在总集数大于 6 时按两段分页显示：第一页为 `1-6`，第二页为 `7-最后`。

#### Scenario: 集数不超过 6 时只显示单段范围
- **WHEN** 当前季共有 4 集
- **THEN** 只显示一个范围标签 `1-4`

#### Scenario: 集数超过 6 时显示两段范围
- **WHEN** 当前季共有 10 集
- **THEN** 显示两个范围标签 `1-6` 与 `7-10`

---

### Requirement: 选择剧集会先更新播放上下文中的当前位置
当前实现下，用户从 `选集` 区块选择某一集时，系统 SHALL 先通过 `jumpTo` 更新 `playbackContext.currentIndex`，再关闭设置面板。

#### Scenario: 选择其他剧集时 currentIndex 更新
- **WHEN** 当前播放第 2 集，用户在 `选集` 区块中选择第 5 集
- **THEN** `playbackContext.currentIndex` 更新为第 5 集对应索引，并关闭设置面板

---

### Requirement: 选择剧集 SHALL 真正切换当前播放 URL
用户从 `选集` 区块选择其他剧集后，播放器 SHALL 重新载入所选条目的播放 URL，使实际播放内容与 `playbackContext.currentIndex` 保持一致。

#### Scenario: 选择其他剧集后播放器切换到所选 URL
- **WHEN** 当前正在播放第 2 集，用户在 `选集` 区块中选择第 5 集
- **THEN** 播放器当前播放源切换为第 5 集对应的 URL，而不是继续播放原来的 URL
