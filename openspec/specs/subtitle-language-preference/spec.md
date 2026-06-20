# subtitle-language-preference Specification

## Purpose

定义应用级字幕语言偏好的设置入口、持久化模型与统一读取契约，确保后续字幕搜索、结果排序过滤与播放默认选轨复用同一份偏好语义。
## Requirements
### Requirement: 应用设置页必须提供字幕语言偏好入口与独立子页

系统 SHALL 在应用设置首页新增“字幕”分组，并提供“字幕语言偏好”入口；用户进入后 SHALL 打开独立子页管理语言偏好，而不是在首页行内编辑。

#### Scenario: 首页展示字幕语言偏好入口与当前摘要
- **WHEN** 用户打开应用设置首页
- **THEN** 页面显示“字幕”分组
- **AND** 分组内存在“字幕语言偏好”入口
- **AND** 入口摘要展示当前偏好语言顺序（如 `简体中文 / 繁体中文`）

#### Scenario: 首页入口整行可聚焦与激活
- **WHEN** 用户使用遥控器将焦点移动到“字幕语言偏好”入口的任意水平区域（包括右侧语言摘要区域）
- **THEN** 焦点落在整行入口容器上，而不是只落在左侧标题或右侧摘要文本上
- **AND** 用户按确认键后进入字幕语言偏好子页
- **AND** 右侧摘要文本不会缩小该入口的可聚焦或可点击区域

#### Scenario: 进入字幕语言偏好子页
- **WHEN** 用户在设置首页激活“字幕语言偏好”入口
- **THEN** 系统进入独立子页
- **AND** 子页显示当前已选语言列表、可选语言列表与 `hideOtherLanguages` 开关

---

### Requirement: 字幕语言偏好必须具备默认值、可扩展语言注册表与本地持久化

系统 SHALL 使用统一的 `SubtitleLanguagePreference` 模型管理配置，并通过可扩展语言注册表定义可选语言集合。该偏好 SHALL 持久化到 `subtitle_language_preference`，默认值为：
- `languages = ['zh-CN', 'zh-TW']`
- `hideOtherLanguages = false`

MVP 语言注册表至少包含：`zh-CN`、`zh-TW`、`en`、`ja`、`ko`、`fr`、`de`、`es`。

#### Scenario: 首次读取时返回默认偏好
- **WHEN** 本地尚未保存 `subtitle_language_preference`
- **THEN** 系统返回默认偏好 `['zh-CN', 'zh-TW']`
- **AND** `hideOtherLanguages` 默认为 `false`

#### Scenario: 非法持久化内容回退默认值
- **WHEN** `subtitle_language_preference` 存在但 JSON 无法解析，或解析后语言 code 无效
- **THEN** 系统回退到默认偏好
- **AND** 不因异常配置导致设置页或后续搜索链路崩溃

#### Scenario: 新增语言通过扩展注册表接入
- **WHEN** 后续版本在语言注册表中新增一个合法语言项
- **THEN** 设置页与偏好归一化逻辑可以直接识别该语言
- **AND** 无需为该语言单独新增排序或过滤分支逻辑

---

### Requirement: 用户必须能够调整语言优先级并控制是否隐藏其他语言

系统 SHALL 允许用户选择最多 3 种偏好语言，并在子页中通过 TV 遥控器可操作的方式调整其优先级顺序。系统 SHALL 同时提供 `hideOtherLanguages` 开关，用于控制搜索结果是否隐藏非偏好语言。

#### Scenario: 调整已选语言优先级
- **WHEN** 用户在字幕语言偏好子页将 `繁体中文` 上移到 `简体中文` 之前
- **THEN** 偏好顺序更新为 `['zh-TW', 'zh-CN']`
- **AND** 设置首页摘要同步反映新的顺序

#### Scenario: 达到上限时不能继续新增第四种语言
- **WHEN** 用户已经选择了 3 种偏好语言
- **AND** 用户尝试再选中第 4 种语言
- **THEN** 系统拒绝本次新增选择
- **AND** 保留原有 3 种偏好语言顺序不变

#### Scenario: hideOtherLanguages 开关持久化
- **WHEN** 用户将 `hideOtherLanguages` 打开并退出设置页后重新进入应用
- **THEN** 开关状态仍为开启
- **AND** 读取到的偏好配置包含 `hideOtherLanguages = true`

---

### Requirement: 后续字幕搜索请求、结果排序过滤与播放默认选轨必须通过统一偏好快照接入

系统 SHALL 提供统一的字幕语言偏好读取/归一化接口，供后续在线字幕搜索请求构造、本地搜索结果排序与过滤，以及播放开始时的默认字幕轨自动选择共同复用。本 requirement 只定义接入契约，不要求本 change 实现具体 OpenSubtitles API。

#### Scenario: 搜索请求按偏好顺序读取语言列表
- **WHEN** 后续字幕搜索模块准备发起一次在线搜索
- **THEN** 它从统一偏好快照中读取 `preferredLanguages`
- **AND** 传递的语言顺序与用户设置顺序一致

#### Scenario: hideOtherLanguages=false 时偏好语言优先展示
- **WHEN** 后续字幕搜索结果同时包含偏好语言与非偏好语言
- **AND** `hideOtherLanguages = false`
- **THEN** 偏好语言结果排在非偏好语言之前
- **AND** 非偏好语言结果仍然保留展示

#### Scenario: hideOtherLanguages=true 时过滤非偏好语言
- **WHEN** 后续字幕搜索结果包含 `en`、`fr` 等非偏好语言
- **AND** 用户偏好为 `['zh-CN', 'zh-TW']`
- **AND** `hideOtherLanguages = true`
- **THEN** 最终结果中只保留 `zh-CN` 或 `zh-TW` 的字幕条目

#### Scenario: 未注册语言在不过滤模式下作为非偏好结果兜底
- **WHEN** Provider 返回一个当前注册表中没有的语言 code
- **AND** `hideOtherLanguages = false`
- **THEN** 系统将该结果视为非偏好语言
- **AND** 它排在所有偏好语言结果之后，而不是导致排序失败

#### Scenario: 播放时按偏好自动选择默认字幕轨
- **WHEN** 播放链路拿到当前视频的可用字幕轨列表
- **AND** 用户偏好为 `['zh-CN', 'zh-TW', 'en']`
- **AND** 可用字幕轨包含 `en` 与 `zh-TW`
- **THEN** 系统默认自动选择 `zh-TW` 字幕轨
- **AND** 选择依据是用户偏好顺序，而不是轨道返回顺序

#### Scenario: 播放时无偏好匹配则不强制切到非偏好轨
- **WHEN** 播放链路拿到的可用字幕轨都不在当前偏好语言列表中
- **THEN** 系统不得因为字幕语言偏好配置而强制切换到任意非偏好轨道
- **AND** 系统保持既有默认行为或无字幕状态

#### Scenario: 用户手动改轨后当前播放会话不再被自动偏好覆盖
- **WHEN** 系统已按偏好完成一次播放默认字幕轨选择
- **AND** 用户在当前播放会话中手动切换到了另一条字幕轨
- **THEN** 系统不得在同一播放会话中再次仅因偏好配置自动切回先前偏好轨道

---

### Requirement: 字幕语言偏好快照必须支持 OpenSubtitles API languages 参数格式输出

系统 SHALL 确保 `SubtitleLanguageSearchPreferenceSnapshot.languagesParam` 字段输出符合 OpenSubtitles `languages` 查询参数格式（逗号分隔的 BCP-47 语言码，如 `"zh-CN,zh-TW,en"`）。该字段可直接传入 `OpenSubtitlesClient.search()` 的 `languages` 参数，无需额外转换。

#### Scenario: 快照 languagesParam 可直接用于 OpenSubtitles 搜索
- **WHEN** 用户语言偏好为 `['zh-CN', 'zh-TW', 'en']`
- **THEN** `snapshot.languagesParam` 返回 `"zh-CN,zh-TW,en"`
- **AND** 该字符串可直接作为 OpenSubtitles `GET /subtitles?languages=` 的参数值

#### Scenario: 单语言偏好时不含多余逗号
- **WHEN** 用户语言偏好只有 `['zh-CN']`
- **THEN** `snapshot.languagesParam` 返回 `"zh-CN"`（无尾部逗号）

#### Scenario: 空偏好时 languagesParam 为空字符串
- **WHEN** 用户语言偏好为空数组
- **THEN** `snapshot.languagesParam` 返回 `""`
- **AND** OpenSubtitlesClient 在 languagesParam 为空时不传 languages 参数（返回全语言结果）

