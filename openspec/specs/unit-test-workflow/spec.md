# Spec: unit-test-workflow

## Purpose

定义单元测试编译、设备执行、权威门禁状态及诊断报告的可信度要求。
本规范将编译状态与设备测试执行结果分别记录，并确保必需检查、报告与历史记录基于同一次运行证据保持一致，防止未执行、执行异常或缺少结果时产生虚假的成功结论。

## Requirements

### Requirement: 编译与设备测试分别判定
`unit-test.yml` SHALL 在 iMac self-hosted runner 上执行 `UnitTestBuild` 和必需的设备测试。编译成功只表示编译步骤通过，不能替代设备测试通过。

#### Scenario: 编译成功但测试未执行
- **WHEN** 编译成功，但设备不可用、测试步骤被跳过或实际执行用例数为 0
- **THEN** 报告标识测试未执行及具体原因，必需测试门禁失败

#### Scenario: 编译失败
- **WHEN** `UnitTestBuild` 非零退出
- **THEN** 编译步骤及 job 失败，不启动设备测试，仍保留编译日志

#### Scenario: 正常设备测试通过
- **WHEN** 本次测试在期限内正常结束，结果有效且实际执行用例数大于 0，全部执行用例通过
- **THEN** 测试状态与必需门禁均通过

### Requirement: 异常执行须使门禁失败
workflow SHALL 保留测试命令真实退出码，检测 `Failed to resolve OhmUrl` / `10311002`，对超时、非零退出、失败或错误用例输出具体原因并使门禁失败。

#### Scenario: OhmUrl 解析失败
- **WHEN** 本次执行日志包含 OhmUrl 错误，即使命令返回 0
- **THEN** 门禁失败，报告明确标识 OhmUrl 错误，保留原日志

#### Scenario: 超时
- **WHEN** 测试命令超过限定执行时间
- **THEN** 只终止本次启动的测试进程，记录超时并使门禁失败；不得重启或杀死全局 hdc

#### Scenario: 用例失败或错误
- **WHEN** 有效结果中的失败数或错误数大于 0
- **THEN** 门禁和报告均失败，不以部分用例通过代替整体通过

### Requirement: 本次有效结果是唯一判定依据
workflow SHALL 在执行前清理旧测试结果，并严格验证当前结果文件；日志中的汇总、编译成功文字或历史报告不能替代结果文件。

#### Scenario: 结果文件缺失、损坏或过期
- **WHEN** 结果缺失、无法解析、字段缺失、计数矛盾或属于旧运行
- **THEN** 门禁失败并记录具体原因，不回退到旧报告或默认 0 个失败

### Requirement: 按触发提交执行
workflow SHALL 同步触发运行对应的准确提交；同步失败须停止构建和设备测试。

#### Scenario: PR 测试
- **WHEN** PR 触发测试
- **THEN** 使用 PR head SHA，并在诊断结果中关联运行标识

### Requirement: 日志与报告不改变原始测试结论
workflow SHALL 将权威门禁结果用于 Summary、状态 JSON 和历史报告，并在成功、失败或未执行时保留本次日志与诊断产物。报告生成、发布、上传失败 SHALL 单独显示，不改写或掩盖原始测试结论。

#### Scenario: 发布失败
- **WHEN** 报告发布失败
- **THEN** 显式记录发布失败，仍执行最终门禁；已失败或未执行的测试不能变为通过

### Requirement: 设备工作流互斥且不主动中断运行
设备测试 workflow SHALL 使用共享 concurrency group，关闭 `cancel-in-progress`，避免单测与集成测试同时使用设备或主动中断已有运行。

#### Scenario: 同时触发
- **WHEN** 单测和集成测试同时触发
- **THEN** 运行串行化，不取消正在执行的设备任务

---

### Requirement: 单元测试 CI 追加 unit-history.json

`unit-test.yml` 的"Publish to gh-pages"步骤 SHALL 在每次 Run 完成后，将统计摘要追加到 `unit/unit-history.json`（最多保留 30 条），供历史列表页读取。

#### Scenario: 首次 Run 时自动创建文件
- **WHEN** `unit/unit-history.json` 在 gh-pages 分支中不存在
- **THEN** CI 创建该文件并写入包含本次记录的数组

#### Scenario: 后续 Run 时追加记录
- **WHEN** `unit/unit-history.json` 已存在
- **THEN** CI 追加本次记录，超出 30 条时删除最旧记录

---

### Requirement: 单元测试 CI 追加 coverage-history.json

`unit-test.yml` 的"Publish to gh-pages"步骤 SHALL 在每次 Run 完成后，将覆盖率摘要追加到 `unit/coverage-history.json`（最多保留 30 条），供覆盖率趋势图读取。

#### Scenario: 覆盖率数据写入
- **WHEN** 覆盖率 JSON（`coverageReport.json`）生成成功
- **THEN** `unit/coverage-history.json` 中包含本次行/函数/分支覆盖率百分比

---

### Requirement: 单元测试 CI 覆盖率文件复制路径变更

`unit-test.yml` SHALL 将 Istanbul 原始 HTML 覆盖率报告复制到 `unit/runs/run-N/coverage/detail/`（而非直接放在 `coverage/` 根目录），并额外生成覆盖率汇总页 `unit/runs/run-N/coverage/index.html`。

#### Scenario: 覆盖率文件夹结构正确
- **WHEN** CI 完成覆盖率复制
- **THEN** `coverage/index.html` 为汇总页，`coverage/detail/index.html` 为 Istanbul 原始页

---

### Requirement: 单元测试历史列表 HTML 从 unit-history.json 生成

`unit-test.yml` SHALL 生成 `unit/history-list/index.html`，页面使用 TailwindCSS + 内联 JS 读取 `../unit-history.json` 动态渲染，不再通过扫描目录名生成静态表格。

#### Scenario: 历史列表页可以展示完整统计信息
- **WHEN** 用户访问 `unit/history-list/index.html`
- **THEN** 页面展示 Run 编号、状态、通过/失败/总计、时间戳、报告/覆盖率链接
