# File Source UI Tests

## Purpose

提供文件源管理流程的 UI 自动化测试覆盖，包括 WebDAV/SMB 源添加、连接测试、目录选择器等交互验证。

## Requirements

### Requirement: 添加 WebDAV 源的 UI 交互测试
系统 SHALL 提供自动化测试用例，覆盖从文件源列表页进入"添加文件源"弹层、选择 WebDAV/Alist 类型、填写表单、点击测试连接、验证连接成功 toast、点击保存并验证文件源卡片出现在列表中的完整流程。

#### Scenario: 成功添加 WebDAV 文件源
- **WHEN** 测试用例依次执行：进入文件源 tab → 点击"添加" → 选择"WebDAV / Alist" → 填写服务器名称/地址/端口/用户名/密码 → 点击"测试连接"
- **THEN** 页面出现"连接成功" toast，且 toast 文本可通过 `BY.text('连接成功')` 定位

#### Scenario: 保存 WebDAV 文件源后列表中出现新卡片
- **WHEN** 测试连接成功后点击"保存"按钮
- **THEN** 弹层关闭，文件源列表中出现以服务器名称命名的新卡片

---

### Requirement: 添加 SMB 源的 UI 交互测试
系统 SHALL 提供自动化测试用例，覆盖选择 SMB 类型、填写必填字段（名称/服务器地址/用户名/密码）、点击保存的流程；当 `SKIP_SMB_TESTS` 参数为 `true` 时，该套件 SHALL 被跳过并标记为 SKIP 而不是 FAIL。

#### Scenario: SKIP_SMB_TESTS=true 时 SMB 测试被跳过
- **WHEN** `aa test` 启动时传入 `-s SKIP_SMB_TESTS true`
- **THEN** SMB 相关用例不执行，测试报告中标记为跳过

#### Scenario: 打开添加 SMB 弹层
- **WHEN** 在"添加文件源"弹层中选择 SMB 类型
- **THEN** 出现"添加 SMB 源"弹层，包含名称、服务器地址、"发现局域网设备"按钮、用户名、密码等字段

---

### Requirement: 目录选择器 UI 交互测试
系统 SHALL 提供自动化测试用例，覆盖在文件源已添加后打开目录选择器、浏览子目录（面包屑导航）、勾选文件夹、点击"完成"的流程。

#### Scenario: 进入目录选择器并浏览子目录
- **WHEN** 在文件源设置中触发"选择扫描目录"操作
- **THEN** 出现"选择文件夹"弹层，显示根目录下的文件夹列表和面包屑导航

#### Scenario: 勾选文件夹并完成选择
- **WHEN** 在目录选择器中点击一个文件夹的勾选图标，然后点击"完成"
- **THEN** 弹层关闭，选中的目录出现在文件源配置的目录列表中
