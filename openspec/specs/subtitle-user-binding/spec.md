## ADDED Requirements

### Requirement: 系统 SHALL 在用户手动选择外置字幕时保存绑定关系

用户在播放过程中通过 UI 手动选择一个外置字幕轨道（`kind === 'external'`，有 `url` 字段）时，系统 SHALL 将 `{ videoPath, subtitlePath: track.url, subtitleType: 'local-file', savedAt }` 写入 AppPreferences，key 格式为 `subtitle_binding_<sha256Hex(videoPath).slice(0,12)>`。

#### Scenario: 用户选择外置字幕时绑定被持久化
- **WHEN** 用户在播放中选择一个 `kind === 'external'` 的字幕轨道
- **THEN** 系统调用 `SubtitleDispatcher.saveUserBinding(videoPath, track.url, 'local-file')`
- **AND** AppPreferences 中写入对应 key 的绑定记录
- **AND** 下次同一视频 prepared 后该绑定被优先加载

#### Scenario: 用户选择内置字幕时不写绑定
- **WHEN** 用户在播放中选择一个 `kind === 'internal'` 的字幕轨道
- **THEN** 系统不调用 `saveUserBinding`
- **AND** AppPreferences 中不新增绑定记录

### Requirement: 系统 SHALL 在用户关闭字幕或绑定文件丢失时清除绑定

用户选择"关闭字幕"（trackIndex === -1）时，系统 SHALL 调用 `clearUserBinding(videoPath)` 删除该视频的绑定记录。调度器在绑定文件 URL 匹配失败时也 SHALL 自动清除该绑定。

#### Scenario: 用户关闭字幕时绑定被清除
- **WHEN** 用户在播放中选择"关闭字幕"（trackIndex === -1）
- **THEN** 系统调用 `SubtitleDispatcher.clearUserBinding(videoPath)`
- **AND** AppPreferences 中对应 key 被删除
- **AND** 下次打开同一视频时不自动加载字幕（无绑定）

#### Scenario: 绑定文件 URL 在下次播放时不存在则自动清除
- **WHEN** 视频进入 prepared 状态
- **AND** 存在用户绑定但绑定 URL 不在 allSubtitleTracks 中
- **THEN** 调度器自动调用 `clearUserBinding(videoPath)`
- **AND** 本次播放继续按步骤 2 往下裁决，不加载已失效的绑定

### Requirement: 绑定数据结构 SHALL 包含 videoPath、subtitlePath、subtitleType 和 savedAt 四个字段

绑定记录 SHALL 使用 `SubtitleBinding` 接口，字段含义：
- `videoPath`：视频的完整 URL 路径（用于唯一标识视频）
- `subtitlePath`：字幕的完整 URL（local-file）或本地路径（downloaded/cached）
- `subtitleType`：`'local-file' | 'cached' | 'downloaded'`
- `savedAt`：绑定写入时的 Unix 时间戳（毫秒）

#### Scenario: 绑定数据可序列化并在 AppPreferences 中稳定读写
- **WHEN** 系统写入一条 `SubtitleBinding` 记录
- **AND** 应用重启后再次读取该 key
- **THEN** 反序列化结果与写入时的字段值一致
- **AND** `savedAt` 不为 0

#### Scenario: AppPreferences 中 key 损坏时读取返回 null
- **WHEN** 对应 key 的 value 无法解析为合法 `SubtitleBinding`（JSON 损坏或字段缺失）
- **THEN** `getUserBinding()` 返回 null
- **AND** 不抛出异常，调度器继续执行步骤 2
