# integration-status-json

## Purpose

定义集成测试的权威门禁状态在报告中的展示契约。
本规范将编译状态与设备测试执行结果分别记录，并确保必需检查、报告与历史记录基于同一次运行证据保持一致，防止未执行、执行异常或缺少结果时产生虚假的成功结论。

## Requirements

### Requirement: integration-status-json-schema
`integration-test.yml` SHALL 使用本次门禁判定结果生成 `integration-status.json`。至少包含 `suite`、`status`（`passed` / `failed` / `not_run`）、`gate_passed`、`build_status`、`reason`、`passed`、`failed`、`errors`、`total`、运行标识、commit SHA 及时间戳。

#### Scenario: 编译成功但测试未执行
- **WHEN** 编译成功而测试未执行
- **THEN** `build_status` 可为 `success`，但 `status` 不得为 `passed`，`gate_passed` 必须为 false

### Requirement: integration-status-json-timing
工作流必须（SHALL）先在本地生成并持久化本次门禁状态，保存为 Actions 产物，并通过独立步骤推送远端状态 JSON 及本次摘要；随后独立发布 Allure 报告、更新 Portal。Summary、历史记录和最终门禁均复用该结果，后置步骤失败不得改写或回滚已发布状态。若远端不可写，明确报告状态发布失败，依据运行标识区分旧远端记录，本地结果和产物仍为本次权威证据。

#### Scenario: 报告生成或发布失败
- **WHEN** 外部报告无法生成或发布
- **THEN** 本次原始门禁结论和日志仍可由 Actions 日志或产物检查，不以历史报告冒充本次报告

### Requirement: integration-status-json-status-derivation
workflow SHALL 仅在编译成功、本次执行正常完成、结果有效、实际执行数大于 0 且失败数和错误数均为 0 时标为 `passed`。设备缺失、超时、OhmUrl 错误、缺失/损坏/过期结果或 0 个执行用例均不能通过。

#### Scenario: 零用例
- **WHEN** 实际执行数为 0，即使命令返回 0
- **THEN** 状态为 `not_run`，必需门禁失败

#### Scenario: 失败或错误用例
- **WHEN** `failed > 0` 或 `errors > 0`
- **THEN** 状态为 `failed`，不因存在通过用例而标为通过

#### Scenario: 全部执行用例通过
- **WHEN** 执行证据有效且所有通过条件满足
- **THEN** 状态为 `passed`，最终门禁通过
