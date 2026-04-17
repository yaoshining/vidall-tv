## 1. unit-test.yml：JSON 存档逻辑

- [x] 1.1 在"Publish to gh-pages"步骤中，读取已有 `unit/unit-history.json`（不存在时初始化为空数组），追加本次 Run 记录（run_number、timestamp、status、passed、failed、total、report_href、coverage_href），保留最近 30 条后写回
- [x] 1.2 在"Publish to gh-pages"步骤中，读取已有 `unit/coverage-history.json`（不存在时初始化为空数组），追加本次 Run 覆盖率摘要（run_number、timestamp、lines_pct、functions_pct、branches_pct），保留最近 30 条后写回

## 2. unit-test.yml：覆盖率文件路径重构

- [x] 2.1 将 Istanbul 原始 HTML 的复制目标从 `unit/runs/run-N/coverage/` 改为 `unit/runs/run-N/coverage/detail/`（使用 `cp -r` 保留完整目录结构）
- [x] 2.2 在 `unit/runs/run-N/coverage/` 目录下生成 `index.html`（覆盖率汇总页），内联 TailwindCSS + ECharts，读取同目录 `coverageReport.json` 渲染三个指标卡、文件条形图、历史趋势折线图

## 3. unit-test.yml：历史列表页生成逻辑替换

- [x] 3.1 将现有"扫描 runs/ 目录名生成静态表格"的 Python 逻辑，替换为"读取 `unit/unit-history.json` 生成 TailwindCSS 深色风格动态页面"的逻辑
- [x] 3.2 新历史列表页 HTML 使用内联 JS fetch `../unit-history.json`，按 run_number 降序渲染表格，每行含：Run 编号链接、状态徽标、通过/失败/总计、时间戳（本地时间）、"查看报告"按钮、"查看覆盖率"按钮（有 coverage_href 时显示）

## 4. integration-test.yml：JSON 存档与历史列表页

- [x] 4.1 在"Update portal"步骤中，读取已有 `integration/integration-history.json`（不存在时初始化为空数组），追加本次 Run 记录（run_number、timestamp、status、passed、failed、total、report_href），保留最近 30 条后写回
- [x] 4.2 在"Update portal"步骤中，生成 `integration/history-list/index.html`，与单元测试历史列表页同风格：TailwindCSS 深色表格，内联 JS fetch `../integration-history.json`，按 run_number 降序渲染

## 5. 验证

- [ ] 5.1 在本地用 Python 脚本模拟 CI 的 JSON 追加逻辑，验证首次创建、追加、超 30 条裁剪三种情况正确
- [ ] 5.2 触发一次 CI（push 小改动），确认 gh-pages 分支新增：`unit/unit-history.json`、`unit/coverage-history.json`、`unit/runs/run-N/coverage/index.html`、`unit/runs/run-N/coverage/detail/index.html`
- [ ] 5.3 验证 `unit/history-list/index.html` 页面在浏览器中正确加载 TailwindCSS 样式和表格数据
- [ ] 5.4 验证 `unit/runs/run-N/coverage/index.html` 中 ECharts 图表正常渲染（三个指标卡 + 文件条形图）
- [ ] 5.5 触发一次集成测试 CI，确认 `integration/integration-history.json` 和 `integration/history-list/index.html` 正确生成
