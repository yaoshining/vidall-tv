# Spec: unit-history-list-page

## Purpose

定义单元测试历史列表页面（`unit/history-list/index.html`）的行为规范。该页面读取 `unit/unit-history.json` 数据源，以 TailwindCSS 深色风格展示每次 Run 的统计信息。

---

## Requirements

### Requirement: 单元测试历史列表页从 JSON 数据源渲染

历史列表页 SHALL 通过内联 JavaScript 读取同目录的 `../unit-history.json`（相对路径），解析后动态渲染到页面，不依赖服务端渲染。

`unit/unit-history.json` 的数据结构 SHALL 为数组，每项包含：
- `run_number`：Run 编号（整数）
- `timestamp`：ISO 8601 UTC 时间戳
- `status`：`"pass"` 或 `"fail"`
- `passed`：通过用例数（整数）
- `failed`：失败用例数（整数）
- `total`：总用例数（整数）
- `report_href`：对应 Allure 报告的相对路径
- `coverage_href`：对应覆盖率汇总页的相对路径（可选，无覆盖率时省略）

#### Scenario: 有历史记录时渲染表格
- **WHEN** `unit/unit-history.json` 存在且包含至少一条记录
- **THEN** 页面渲染深色风格表格，按 `run_number` 降序排列，每行显示 Run 编号、状态徽标、通过/失败/总计、时间戳、报告链接

#### Scenario: JSON 不存在或为空时显示占位状态
- **WHEN** `unit/unit-history.json` fetch 失败或数组为空
- **THEN** 页面显示"暂无历史记录"占位信息，不抛出 JS 错误

---

### Requirement: 单元测试历史列表页视觉规范

页面 SHALL 使用 `vendor/tailwind.js`（相对路径 `../../vendor/tailwind.js`）作为样式框架，采用深色背景（`bg-gray-950` 或等效色），与门户页风格一致。

每行数据 SHALL 显示：
- Run 编号（带链接，指向 `report_href`）
- 状态徽标：`✅ 通过` 或 `❌ 失败`
- 通过/失败/总计（格式：`42 / 0 / 42`）
- 时间戳（本地时间格式）
- 操作按钮："查看报告" 链接、"查看覆盖率" 链接（有 `coverage_href` 时显示）

#### Scenario: 通过状态行视觉区分
- **WHEN** 某条记录 `status` 为 `"pass"`
- **THEN** 状态列显示绿色徽标 `✅ 通过`

#### Scenario: 失败状态行视觉区分
- **WHEN** 某条记录 `status` 为 `"fail"`
- **THEN** 状态列显示红色徽标 `❌ 失败`
