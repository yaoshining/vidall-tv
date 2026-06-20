# Spec: integration-test-allure-report

## Purpose

定义集成测试 Allure 报告的生成、标记与发布规范，包括日志解析、结果 JSON 生成、历史趋势保留，以及 gh-pages 多测试类型共享 landing page。

---

## Requirements

### Requirement: 解析 aa-test 日志生成 Allure result JSON
集成测试 workflow SHALL 解析 `aa-test.log` 中每条 `[pass]`/`[fail]` 记录，为每个测试用例生成独立的 Allure result UUID JSON 文件，存入 `.ci/allure-results/`。

#### Scenario: 存在通过的测试用例
- **WHEN** `aa-test.log` 包含 `[pass] <testCaseName>` 行
- **THEN** 对应 result JSON 的 `status` 为 `passed`，`name` 为 `<testCaseName>`

#### Scenario: 存在失败的测试用例
- **WHEN** `aa-test.log` 包含 `[fail] <testCaseName>` 行
- **THEN** 对应 result JSON 的 `status` 为 `failed`，`statusDetails.message` 包含失败信息

#### Scenario: 无法解析日志但整体通过
- **WHEN** `aa-test.log` 无 `[pass]`/`[fail]` 行，且 `TestFinished-ResultCode: 0`
- **THEN** 生成单条 `passed` result，name 为 `IntegrationTestSuite`，防止 Allure 报告为空

---

### Requirement: 为集成测试 result 添加区分标签
每个集成测试 result JSON SHALL 包含以下 Allure 标签：`suite=Integration Tests`、`parentSuite=Device Tests`、`tag=integration`，使其在 Allure 界面与单测（`suite=CI Compile`）明确区分。

#### Scenario: Allure 报告展示集成测试 Suite
- **WHEN** Allure HTML 报告中打开 Suites 视图
- **THEN** 集成测试用例显示在 `Device Tests > Integration Tests` 路径下，与单测的 `CI Compile` 路径分离

#### Scenario: 通过 Tag 筛选集成测试
- **WHEN** 用户在 Allure 报告中按 Tag 筛选 `integration`
- **THEN** 仅显示集成测试用例，不混入单测结果

---

### Requirement: 使用 allure-commandline 生成 HTML 报告并保留历史趋势
集成测试 workflow SHALL 使用 `allure-commandline@2.27.0` 将 `.ci/allure-results/` 生成 HTML 报告，并从 `gh-pages/integration/history/` 读取历史趋势数据。

#### Scenario: 首次生成报告（无历史数据）
- **WHEN** `gh-pages` 分支不存在 `integration/history/` 目录
- **THEN** allure generate 正常完成，报告中趋势图为空但不报错

#### Scenario: 非首次生成（有历史数据）
- **WHEN** `gh-pages/integration/history/` 存在有效历史文件
- **THEN** allure generate 生成包含趋势图的 HTML 报告

---

### Requirement: 集成测试报告发布到 gh-pages integration/ 子目录
集成测试 workflow SHALL 将生成的 Allure HTML 报告发布到 `gh-pages` 分支的 `integration/` 子目录，历史 run 存入 `integration/runs/run-<N>/`，根目录内容不得被删除。

#### Scenario: 发布后报告可访问
- **WHEN** workflow 成功推送 gh-pages
- **THEN** `<owner>.github.io/<repo>/integration/` 可访问最新 Allure HTML 报告

#### Scenario: 单测报告不被覆盖
- **WHEN** 集成测试 workflow 推送 gh-pages
- **THEN** gh-pages 根目录的单测 `runs/` 目录内容保持不变

---

### Requirement: 共享 landing page 区分展示单测和集成测试
`gh-pages` 根目录 `index.html` SHALL 同时展示单测和集成测试两个历史 run 列表，每个分区有独立标题和链接，用户无需进入子目录即可区分。

#### Scenario: landing page 展示两类测试入口
- **WHEN** 用户访问 `<owner>.github.io/<repo>/`
- **THEN** 页面包含"单元测试报告"和"集成测试报告"两个独立分区，各自列出历史 run 链接

#### Scenario: 仅有集成测试历史时
- **WHEN** `integration/runs/` 有数据但根目录 `runs/` 为空
- **THEN** 集成测试分区正常显示，单测分区显示"暂无记录"占位文字
