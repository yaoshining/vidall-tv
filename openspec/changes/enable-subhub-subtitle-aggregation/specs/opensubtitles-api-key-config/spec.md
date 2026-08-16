## ADDED Requirements

### Requirement: 设置页必须展示字幕通道状态

系统 SHALL 在应用设置页新增 OpenSubtitles 配置入口，默认展示「使用 SubHub（推荐）」状态。入口 SHALL 支持展开查看状态和切换为自定义 Key 直连模式。

#### Scenario: 默认展示 SubHub 状态
- **WHEN** 用户进入设置页且未配置自定义 Key
- **THEN** OpenSubtitles 配置入口显示「SubHub · 推荐」状态文案
- **AND** 不显示 API Key 输入框

#### Scenario: 展开后可填写自定义 API Key
- **WHEN** 用户激活 OpenSubtitles 配置入口
- **THEN** 展示 API Key 输入框（遥控器可聚焦）
- **AND** 展示「如何获取 API Key」引导链接/提示文本
- **AND** 用户填写并保存后，App 切换为直连模式

## MODIFIED Requirements

### Requirement: OPENSUBTITLES_API_KEY 必须持久化到 AppPreferences

系统 SHALL 将用户填写的 API Key 存入 `AppPreferences` 的 `PrefKey.OPENSUBTITLES_API_KEY`。该值 SHALL 在 App 启动时自动读取，读取失败时回退为空字符串（触发 SubHub 通道）。

#### Scenario: 保存 Key 后立即生效
- **WHEN** 用户在设置页保存 API Key
- **THEN** 下一次字幕搜索使用直连模式（OpenSubtitles 直连结果优先，并拼接 SubHub 结果）
- **AND** 无需重启 App

#### Scenario: 清空 Key 后恢复 SubHub 模式
- **WHEN** 用户清空 API Key 输入框并保存
- **THEN** `PrefKey.OPENSUBTITLES_API_KEY` 存储空字符串
- **AND** 下一次字幕搜索恢复仅使用 SubHub 通道

## REMOVED Requirements

### Requirement: 设置页必须展示 OpenSubtitles 当前通道状态

**Reason**: 默认通道由「官方代理」改为「SubHub」，且「代理限额耗尽时引导填 Key」场景随代理通道退出默认路径而不再适用。

**Migration**: 使用新的「设置页必须展示字幕通道状态」需求（默认展示「SubHub · 推荐」）。
