# Spec: coverage-summary-page

## Purpose

定义每次单元测试 Run 的覆盖率汇总页面（`unit/runs/run-N/coverage/index.html`）的行为规范。该页面使用 TailwindCSS + ECharts 展示行/函数/分支覆盖率指标和文件级明细，Istanbul 原始 HTML 保留在 `coverage/detail/` 供深入查看。

---

## Requirements

### Requirement: 覆盖率汇总页读取 coverageReport.json 渲染数据

覆盖率汇总页 SHALL 通过内联 JavaScript 读取同目录的 `coverageReport.json`，解析 `summary`（汇总数据）和 `files`（文件列表）字段，不依赖服务端渲染。

#### Scenario: coverageReport.json 存在时渲染完整页面
- **WHEN** `coverageReport.json` 存在且包含 `summary` 和 `files` 字段
- **THEN** 页面渲染三个指标卡、文件覆盖率条形图，以及历史趋势折线图（若 `coverage-history.json` 可用）

#### Scenario: coverageReport.json 不存在时显示错误提示
- **WHEN** `coverageReport.json` fetch 失败
- **THEN** 页面显示"覆盖率数据不可用"提示，不抛出 JS 错误

---

### Requirement: 覆盖率汇总页三个指标卡展示

页面顶部 SHALL 展示三个指标卡，分别对应：
- **行覆盖率**（Lines）：`summary.lines.pct`，显示百分比 + `covered/total`
- **函数覆盖率**（Functions）：`summary.functions.pct`
- **分支覆盖率**（Branches）：`summary.branches.pct`

指标卡颜色 SHALL 根据百分比区分：
- `≥ 80%`：绿色
- `50% ~ 79%`：黄色
- `< 50%`：红色

#### Scenario: 高覆盖率时指标卡显示绿色
- **WHEN** `lines.pct >= 80`
- **THEN** 行覆盖率指标卡呈绿色高亮

#### Scenario: 低覆盖率时指标卡显示红色
- **WHEN** `lines.pct < 50`
- **THEN** 行覆盖率指标卡呈红色高亮

---

### Requirement: 文件级覆盖率水平条形图

页面 SHALL 使用 ECharts 渲染水平条形图，展示每个文件的行覆盖率（`files[].summary.lines.pct`），文件名取路径最后两段（`dir/filename.ets`）。

使用 `vendor/echarts.min.js`（相对路径 `../../../../vendor/echarts.min.js`）加载 ECharts。

#### Scenario: 文件列表非空时渲染条形图
- **WHEN** `files` 数组包含至少一个文件
- **THEN** ECharts 水平条形图展示所有文件的行覆盖率

#### Scenario: 文件列表为空时隐藏条形图区域
- **WHEN** `files` 数组为空
- **THEN** 条形图区域不渲染，不显示空白图表

---

### Requirement: 历史趋势折线图

页面 SHALL 尝试从 `../../../coverage-history.json`（相对路径）加载历史数据，使用 ECharts 折线图展示行/函数/分支覆盖率的跨 Run 趋势。

#### Scenario: 历史数据 ≥ 2 条时渲染折线图
- **WHEN** `coverage-history.json` 包含 2 条及以上记录
- **THEN** ECharts 折线图展示三条曲线（行/函数/分支），X 轴为 Run 编号

#### Scenario: 历史数据不足时隐藏折线图
- **WHEN** `coverage-history.json` 不存在或记录数 < 2
- **THEN** 折线图区域不渲染，不报错

---

### Requirement: Istanbul 原始报告保留在 detail 子目录

Istanbul 生成的原始 HTML 覆盖率报告 SHALL 复制到 `coverage/detail/`（不再直接放在 `coverage/` 根目录），汇总页底部 SHALL 提供"查看详细报告"链接指向 `detail/index.html`。

#### Scenario: 点击"查看详细报告"跳转 Istanbul 原始页
- **WHEN** 用户点击汇总页底部"查看详细报告"链接
- **THEN** 浏览器跳转到 `coverage/detail/index.html`（Istanbul 原始 HTML）
