## MODIFIED Requirements

### Requirement: 播放器设置面板开关测试
系统 SHALL 提供自动化测试用例，覆盖在播放器界面打开"设置"面板（右上角设置按钮）、验证面板出现"画面比例"、"字幕管理"、"画质增强"三个区域，以及在 `MediaLibraryContext` 存在时出现"剧集列表"Tab，在无上下文时不出现"剧集列表"Tab。当无可播放媒体文件时，该套件 SHALL 标记为 SKIP。

#### Scenario: 打开播放器设置面板
- **WHEN** 播放器正在播放或暂停时，选中并激活右上角"设置"按钮
- **THEN** 出现设置面板，可通过 `BY.text('画面比例')` 定位到画面比例区域

#### Scenario: 设置面板包含字幕管理入口
- **WHEN** 设置面板已打开
- **THEN** 可通过 `BY.text('字幕管理')` 定位到字幕管理区域，并包含"选择字幕"按钮

#### Scenario: 有 MediaLibraryContext 时设置面板显示剧集列表 Tab
- **WHEN** 播放器携带 MediaLibraryContext 进入，设置面板已打开
- **THEN** 可通过 `BY.text('剧集列表')` 定位到剧集列表 Tab 入口

#### Scenario: 无 PlaybackContext 时设置面板不显示剧集列表 Tab
- **WHEN** 播放器未携带任何 playbackContext，设置面板已打开
- **THEN** 设置面板中不存在文本为"剧集列表"的 Tab

---

### Requirement: 画面比例切换测试
系统 SHALL 提供自动化测试用例，覆盖在设置面板中切换画面比例（适应/填充/拉伸）三个选项，验证选中状态的视觉反馈（选中项样式变化或文本变化）。

#### Scenario: 切换到"填充"画面比例
- **WHEN** 在设置面板中选中"填充"选项
- **THEN** "填充"选项呈选中状态（通过组件 isSelected 或样式属性验证），播放画面不崩溃

#### Scenario: 切换回"适应"画面比例
- **WHEN** 在设置面板中选中"适应"选项
- **THEN** "适应"选项呈选中状态

---

### Requirement: 播放器设置面板在无媒体时安全跳过
当测试环境中无可播放媒体文件（文件浏览器找不到 .mp4/.mkv 等文件）时，`PlayerSettings.test.ets` 中的全部用例 SHALL 标记为跳过（SKIP），而非抛出异常导致测试套件崩溃。

#### Scenario: 无媒体文件时播放器测试安全跳过
- **WHEN** 文件浏览器中不存在可播放文件，且 `SKIP_PLAYER_TESTS` 参数为 `true`
- **THEN** 所有播放器设置测试用例被跳过，不出现 FAIL 状态
