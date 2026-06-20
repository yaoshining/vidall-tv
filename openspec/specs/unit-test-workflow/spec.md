# Spec: unit-test-workflow

## Purpose

定义 `unit-test.yml` GitHub Actions workflow 的行为规范，包括在 iMac self-hosted runner 上执行 `UnitTestBuild`、代码同步、退出码采集、日志上传及 concurrency 防冲突等要求。

---

## Requirements

### Requirement: unit-test workflow 在 iMac self-hosted runner 上执行 UnitTestBuild
`unit-test.yml` SHALL 在打有 `harmonyos-tv-test` 标签的 iMac self-hosted runner 上执行 `UnitTestBuild`，使用 DevEco Studio 内置 SDK（`/Applications/DevEco-Studio.app/Contents/sdk`）和已检出的工程路径（`/Users/shiningyao/DevecostudioProjects/vidall-tv`）。

#### Scenario: workflow_call 触发时成功构建
- **WHEN** `ci-compile-check.yml` 的 `compile-check` job 通过后，通过 `workflow_call` 触发 `unit-test.yml`
- **THEN** iMac runner 执行 `UnitTestBuild`，hvigor 退出码为 0，job 状态为 `success`

#### Scenario: workflow_dispatch 手动触发时成功构建
- **WHEN** 在 GitHub Actions 页面手动触发 `unit-test.yml`（workflow_dispatch）
- **THEN** iMac runner 执行 `UnitTestBuild`，hvigor 退出码为 0

#### Scenario: UnitTestBuild 失败时 job 以非零状态结束
- **WHEN** 测试文件编译错误导致 hvigor 退出码非 0
- **THEN** job 状态为 `failure`，PR check 显示失败

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
`unit-test.yml` SHALL 在构建完成后（无论成功或失败，`if: always()`），将 `UnitTestBuild` 日志文件上传为 Actions artifact，供事后排查。

#### Scenario: 构建成功时日志可下载
- **WHEN** `UnitTestBuild` 成功
- **THEN** Actions artifact 包含完整构建日志，保留至少 7 天

#### Scenario: 构建失败时日志可下载
- **WHEN** `UnitTestBuild` 失败
- **THEN** Actions artifact 仍上传，包含编译错误详情

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
