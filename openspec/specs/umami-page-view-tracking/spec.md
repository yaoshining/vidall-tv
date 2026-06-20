## ADDED Requirements

### Requirement: UmamiAnalyticsService 提供页面浏览追踪能力

系统 SHALL 提供 `UmamiAnalyticsService` 单例，通过持有 `UmamiReporter` 引用发送 page_view 事件，激活 Umami 仪表板的「用户路径」和「漏斗」分析面板。`UmamiAnalyticsService` MUST 在 `EntryAbility.onCreate()` 完成初始化，不得在初始化前调用 `trackPageView`。

#### Scenario: 调用 trackPageView 发送 page_view 事件
- **WHEN** 调用 `UmamiAnalyticsService.getInstance().trackPageView('/player')`
- **THEN** 系统通过 `UmamiReporter` 发送 `type = event` 请求，`payload.url = '/player'`，`payload.name` 不包含自定义事件名（或为空），标识为 page_view 语义

#### Scenario: 未初始化时调用 trackPageView 不崩溃
- **WHEN** 在 `UmamiAnalyticsService.initialize()` 调用前调用 `trackPageView`
- **THEN** 系统静默忽略该调用（使用 `isInitialized()` 守卫），不抛出异常，不崩溃

### Requirement: 各页面在出现时上报对应 page_view 路径

系统 SHALL 在以下时机触发 page_view 上报，`url` 字段使用规定路径：

| 路径 | 触发时机 |
|------|---------|
| `/home` | `HomePage.aboutToAppear()` |
| `/media-library` | 首页 Swiper tab 切换到媒体库索引时 |
| `/file-browser` | 首页 Swiper tab 切换到文件浏览索引时 |
| `/player` | `PlayerPage.aboutToAppear()` |
| `/settings/player` | `SettingsPage.aboutToAppear()`（播放器设置） |
| `/settings/sources` | `SettingsPage.aboutToAppear()`（文件源设置）|

#### Scenario: 进入播放器页面时上报 /player
- **WHEN** `PlayerPage` 作为 NavDestination 出现（push 到导航栈后）
- **THEN** 系统发送 `url = '/player'` 的 page_view 事件

#### Scenario: 切换到媒体库 tab 时上报 /media-library
- **WHEN** 用户在首页切换到媒体库标签（Swiper onChange 触发对应索引）
- **THEN** 系统发送 `url = '/media-library'` 的 page_view 事件

#### Scenario: 从播放器 pop 回首页后重新进入播放器再次上报
- **WHEN** 用户从播放器返回首页后再次进入播放器
- **THEN** 系统再次发送 `url = '/player'` 的 page_view 事件（`aboutToAppear` 再次触发）
