## MODIFIED Requirements

### Requirement: 系统 SHALL 在 prepared 后按固定优先级链自动选择字幕来源

视频进入 `prepared` 状态后，`SubtitleDispatcher.resolveSubtitle()` SHALL 按以下顺序裁决字幕来源：
1. 用户指定字幕（持久化绑定）
2. AVPlayer 内置字幕轨道
3. 同目录同名外置字幕文件
4. 本地 App 缓存（通过 `SubtitleCacheManager.getLastUsedSubtitle()` 查询）
5. 无字幕

#### Scenario: 用户绑定存在且 URL 匹配时优先加载用户指定字幕
- **WHEN** 视频进入 prepared 状态
- **AND** 该视频 videoPath 存在用户绑定记录
- **AND** 绑定的 subtitlePath（URL）在 allSubtitleTracks 中有对应 item
- **THEN** 调度器返回 `type: 'user-specified'`，对应 track 被激活
- **AND** adapter 的语言偏好自动选轨结果被覆盖

#### Scenario: 用户绑定存在但 URL 不在轨道列表中时降级
- **WHEN** 视频进入 prepared 状态
- **AND** 该视频存在用户绑定记录
- **AND** 绑定的 subtitlePath 在 allSubtitleTracks 中找不到匹配项
- **THEN** 调度器清除该绑定
- **AND** 继续按步骤 2（内置字幕）往下裁决

#### Scenario: 无用户绑定时按 adapter 已加载轨道的语言偏好选轨
- **WHEN** 视频进入 prepared 状态
- **AND** 该视频无用户绑定
- **THEN** 调度器不覆盖 adapter 的自动选轨结果
- **AND** 内置字幕或同名外置字幕仍按语言偏好正常激活

#### Scenario: 步骤 1-3 均无结果时查询本地缓存
- **WHEN** 视频进入 prepared 状态
- **AND** 无用户绑定、无内置字幕命中、无同名外置文件
- **AND** `SubtitleCacheManager.getLastUsedSubtitle()` 返回非 null 路径
- **AND** 该路径在 allSubtitleTracks 中有对应的 cached 轨道
- **THEN** 调度器返回 `type: 'user-specified'`，对应 cached 轨道被激活

#### Scenario: 缓存存在但文件已删除时降级到无字幕
- **WHEN** 步骤 4 查询到 `lastUsed` 文件名
- **AND** 对应本地文件已不存在（被 LRU 清理）
- **THEN** `getLastUsedSubtitle()` 返回 null
- **AND** 调度器继续到步骤 5，返回 `type: 'none'`

#### Scenario: 步骤 1-4 均无结果时不自动发起在线搜索
- **WHEN** 视频进入 prepared 状态
- **AND** 无用户绑定、无内置字幕、无同名外置文件、缓存返回 null
- **THEN** 调度器返回 `type: 'none'`
- **AND** 不自动发起网络搜索请求
