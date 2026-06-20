# Spec: integration-history-list-page

## Purpose

定义集成测试历史列表页面（`integration/history-list/index.html`）的行为规范。该页面读取 `integration/integration-history.json` 数据源，以 TailwindCSS 深色风格展示每次 Run 的统计信息。

---

## Requirements

### Requirement: 集成测试历史列表页从 JSON 数据源渲染

历史列表页 SHALL 通过内联 JavaScript 读取 `../integration-history.json`（相对路径），解析后动态渲染到页面。

`integration/integration-history.json` 的数据结构 SHALL 为数组，每项包含：
- `run_number`：Run 编号（整数）
- `timestamp`：ISO 8601 UTC 时间戳
- `status`：`"pass"` 或 `"fail"`
- `passed`：通过用例数（整数）
- `failed`：失败用例数（整数）
- `total`：总用例数（整数）
- `report_href`：对应 Allure 报告的相对路径（集成测试 Allure 报告位于 `integration/index.html`）

#### Scenario: 有历史记录时渲染表格
- **WHEN** `integration/integration-history.json` 存在且包含至少一条记录
- **THEN** 页面渲染深色风格表格，按 `run_number` 降序排列，每行显示 Run 编号、状态徽标、通过/失败/总计、时间戳、报告链接

#### Scenario: JSON 不存在或为空时显示占位状态
- **WHEN** `integration/integration-history.json` fetch 失败或数组为空
- **THEN** 页面显示"暂无历史记录"占位信息，不抛出 JS 错误

---

### Requirement: 集成测试历史列表页视觉规范

页面 SHALL 使用 `vendor/tailwind.js`（相对路径 `../../vendor/tailwind.js`）作为样式框架，与单元测试历史列表页保持同一视觉风格。

#### Scenario: 页面样式与单元测试历史列表一致
- **WHEN** 用户访问集成测试历史列表页
- **THEN** 页面深色背景、表格结构、徽标样式与单元测试历史列表页保持一致
