# Spec: unit-test-workflow

## Purpose

定义 `unit-test.yml` GitHub Actions workflow 的行为规范，包括在 iMac self-hosted runner 上执行 `UnitTestBuild`、代码同步、退出码采集、日志上传及 concurrency 防冲突等要求。

---

## Requirements

### Requirement: unit-test workflow 在 iMac self-hosted runner 上执行两阶段测试
`unit-test.yml` SHALL 在打有 `harmonyos-tv-test` 标签的 iMac self-hosted runner 上执行两阶段策略：第一阶段为 `UnitTestBuild` 编译门禁（必须通过），第二阶段为可选的设备端测试（`continue-on-error: true`）。

#### Scenario: UnitTestBuild 编译门禁成功
- **WHEN** `UnitTestBuild` 执行成功，hvigor 退出码为 0
- **THEN** 编译步骤通过，继续执行设备端测试步骤
- **AND** 即使设备端测试失败或超时，CI job 仍为 `success`

#### Scenario: UnitTestBuild 编译门禁失败
- **WHEN** 测试文件编译错误导致 hvigor 退出码非 0
- **THEN** 编译步骤失败，job 状态为 `failure`，PR check 显示失败
- **AND** 不执行设备端测试步骤

#### Scenario: 设备端测试成功
- **WHEN** 设备已连接且 hvigor `test` 命令在超时时间内完成
- **THEN** 测试结果被解析并写入报告
- **AND** CI job 状态为 `success`

#### Scenario: 设备端测试超时或失败
- **WHEN** 设备端测试因 hdc daemon 卡死而超时（5 分钟上限）或 hvigor 退出码非零
- **THEN** 系统 SHALL 终止卡死进程并清理残留 hdc 进程
- **AND** 该步骤标记为 `continue-on-error`，不阻塞 CI job
- **AND** CI job 仍为 `success`（仅编译通过）

#### Scenario: workflow_dispatch 手动触发时成功构建
- **WHEN** 在 GitHub Actions 页面手动触发 `unit-test.yml`（workflow_dispatch）
- **THEN** iMac runner 执行 `UnitTestBuild`，hvigor 退出码为 0

---

### Requirement: 工程代码在构建前通过 git pull 同步至最新
`unit-test.yml` SHALL 在执行 `UnitTestBuild` 前，在 iMac 工程路径执行 `git pull`，确保构建使用触发 CI 的最新提交代码。

#### Scenario: git pull 成功后执行构建
- **WHEN** workflow 触发，iMac 网络正常
- **THEN** `git pull` 返回 0，随后执行 `UnitTestBuild`

#### Scenario: git pull 失败时 job 中止
- **WHEN** `git pull` 返回非零退出码（如网络异常、冲突）
- **THEN** job 以失败状态中止，不执行后续 `UnitTestBuild`

---

### Requirement: 退出码使用 PIPESTATUS 精确采集
`unit-test.yml` SHALL 使用 `PIPESTATUS[0]`（或不走管道直接取 `$?`）采集 hvigor 真实退出码，不得以管道末端命令（如 `tee`）的退出码替代。

#### Scenario: hvigor 失败但管道末端命令成功
- **WHEN** hvigor 以非零退出码结束，输出通过管道传给 `tee`
- **THEN** CI 采集到 hvigor 的非零退出码，job 正确标记为失败

---

### Requirement: 构建日志上传为 GitHub Actions artifact
`unit-test.yml` SHALL 在构建完成后（无论成功或失败，`if: always()`），将 `UnitTestBuild` 编译日志和设备端测试日志上传为 Actions artifact，供事后排查。

#### Scenario: 构建成功时日志可下载
- **WHEN** `UnitTestBuild` 成功
- **THEN** Actions artifact 包含编译日志和设备端测试日志，保留至少 7 天

#### Scenario: 构建失败时日志可下载
- **WHEN** `UnitTestBuild` 失败
- **THEN** Actions artifact 仍上传编译日志，包含编译错误详情

---

### Requirement: unit-test workflow 通过 concurrency 防止与 integration-test 冲突
`unit-test.yml` SHALL 设置独立的 `concurrency` group（`harmonyos-unit-test`），与 `integration-test.yml` 的 `harmonyos-device-integration-test` group 互相独立，不互相阻塞。

#### Scenario: unit-test 与 integration-test 同时触发
- **WHEN** `unit-test.yml` 和 `integration-test.yml` 同时在 iMac runner 上排队
- **THEN** 两者各自排队在各自 concurrency group 内，互不取消对方

#### Scenario: 同一 concurrency group 内重复触发
- **WHEN** 短时间内多次触发 `unit-test.yml`（如连续推送）
- **THEN** 后触发的 run 取消前一个等待中的 run（`cancel-in-progress: true`）

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
