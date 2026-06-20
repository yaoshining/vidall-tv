# opensubtitles-api-key-config Specification

## Purpose

定义 OpenSubtitles API Key 的设置入口、用户交互方式与持久化契约，支持用户在代理模式（默认）与自定义 API Key 直连模式之间切换。

## Requirements

### Requirement: 设置页必须展示 OpenSubtitles 当前通道状态

系统 SHALL 在应用设置页新增 OpenSubtitles 配置入口，默认展示「使用官方代理（推荐）」状态。入口 SHALL 支持展开查看代理配额状态和切换为自定义 Key 模式。

#### Scenario: 默认展示代理状态
- **WHEN** 用户进入设置页且未配置自定义 Key
- **THEN** OpenSubtitles 配置入口显示「官方代理 · 推荐」状态文案
- **AND** 不显示 API Key 输入框

#### Scenario: 展开后可填写自定义 API Key
- **WHEN** 用户激活 OpenSubtitles 配置入口
- **THEN** 展示 API Key 输入框（遥控器可聚焦）
- **AND** 展示「如何获取 API Key」引导链接/提示文本
- **AND** 用户填写并保存后，App 切换为直连模式

#### Scenario: 代理限额耗尽时自动展示 Key 填写引导
- **WHEN** 字幕搜索因代理返回 429 失败
- **THEN** 字幕搜索 UI 展示「今日代理配额已用完，建议填写自己的 API Key」
- **AND** 提供快捷跳转到设置页的入口

---

### Requirement: OPENSUBTITLES_API_KEY 必须持久化到 AppPreferences

系统 SHALL 将用户填写的 API Key 存入 `AppPreferences.OPENSUBTITLES_API_KEY`（PrefKey 新增项）。该值 SHALL 在 App 启动时自动读取，读取失败时回退为空字符串（触发代理模式）。

#### Scenario: 保存 Key 后立即生效
- **WHEN** 用户在设置页保存 API Key
- **THEN** 下一次字幕搜索直接使用直连模式
- **AND** 无需重启 App

#### Scenario: 清空 Key 后恢复代理模式
- **WHEN** 用户清空 API Key 输入框并保存
- **THEN** `AppPreferences.OPENSUBTITLES_API_KEY` 存储空字符串
- **AND** 下一次字幕搜索恢复使用代理通道
