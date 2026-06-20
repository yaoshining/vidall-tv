# portal-page

## Purpose

统一测试报告 Portal Landing Page，聚合单元测试与集成测试的状态，提供可访问的 HTML 入口页面，发布到 `gh-pages` 根目录。

## Requirements

### Requirement: portal-html-generation
CI 必须在每次报告推送后生成 `index.html` 并推送到 `gh-pages` 根目录，作为统一的 Portal Landing Page。

**生成方式：** Python 内联脚本（在 workflow 中），读取 `unit-status.json` 和 `integration-status.json`，渲染完整 HTML 后写入根目录。

**状态数据 baked-in：** HTML 中的状态数据在生成时写入，不依赖运行时 fetch。

### Requirement: portal-visual-design
Portal 页面视觉规范：

- 背景色 `#0d1117`（GitHub 深色），文字 `#e6edf3`
- 双列卡片布局（宽屏并排，窄屏堆叠）
- 每张卡片展示：
  - 套件名称（单元测试 / 集成测试）
  - 状态徽标：✅ 全部通过 / ⚠️ 部分失败 / ❌ 全部失败 / 🔄 尚未运行
  - 通过率（如 `42 / 45`）
  - 最近 Run 编号与 UTC 时间戳
  - "查看报告"按钮，直链到对应 Allure 报告
- 使用 Tailwind CSS CDN，无额外构建步骤
- 响应式布局，适配 TV 大屏

### Requirement: portal-fallback-state
当某套件的 status JSON 不存在时，对应卡片显示"🔄 尚未运行"占位状态，不报错，不跳过渲染。

### Requirement: portal-unit-report-path
单测"查看报告"按钮链接到 `/unit/index.html`（不再是根目录）。

### Requirement: portal-integration-report-path
集成测试"查看报告"按钮链接到 `/integration/index.html`。

---

### Requirement: 集成测试 CI 追加 integration-history.json

`integration-test.yml` SHALL 在每次 Run 的"Update portal"步骤中，将统计摘要追加到 `integration/integration-history.json`（最多保留 30 条），供历史列表页读取。

追加记录结构：`{run_number, timestamp, status, passed, failed, total, report_href}`

#### Scenario: 集成测试历史 JSON 写入
- **WHEN** 集成测试 CI Run 完成并进入门户更新步骤
- **THEN** `integration/integration-history.json` 包含本次记录，超出 30 条时删除最旧记录

---

### Requirement: 集成测试 CI 生成历史列表页

`integration-test.yml` SHALL 在每次 Run 的"Update portal"步骤中，生成 `integration/history-list/index.html`，内容使用 TailwindCSS + 内联 JS 读取 `../integration-history.json` 动态渲染。

#### Scenario: 历史列表页可以展示集成测试统计
- **WHEN** 用户访问 `integration/history-list/index.html`
- **THEN** 页面展示集成测试每次 Run 的 Run 编号、状态、通过/失败/总计、时间戳、报告链接
