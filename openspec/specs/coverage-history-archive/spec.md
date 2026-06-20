# Spec: coverage-history-archive

## Purpose

定义覆盖率历史存档机制：每次单元测试 Run 将覆盖率摘要追加到 `unit/coverage-history.json`，为覆盖率趋势折线图提供跨 Run 的数据源。

---

## Requirements

### Requirement: 每次 Run 追加覆盖率摘要到 coverage-history.json

`unit-test.yml` 的"Publish to gh-pages"步骤 SHALL 在生成覆盖率报告后，将本次 Run 的覆盖率摘要追加到 `unit/coverage-history.json`。

追加记录的数据结构 SHALL 为：
- `run_number`：当前 Run 编号（整数）
- `timestamp`：ISO 8601 UTC 时间戳
- `lines_pct`：行覆盖率百分比（浮点数，来自 `summary.lines.pct`）
- `functions_pct`：函数覆盖率百分比
- `branches_pct`：分支覆盖率百分比

文件不存在时 SHALL 自动初始化为空数组再追加。

#### Scenario: coverage-history.json 不存在时自动初始化
- **WHEN** `unit/coverage-history.json` 在 gh-pages 分支中不存在
- **THEN** CI 创建该文件并写入包含本次记录的数组

#### Scenario: coverage-history.json 存在时追加新记录
- **WHEN** `unit/coverage-history.json` 已存在且包含历史记录
- **THEN** CI 在数组末尾追加本次记录，保留所有历史数据

---

### Requirement: coverage-history.json 保留最近 30 条记录

`unit/coverage-history.json` SHALL 最多保留最近 30 条记录，超出时删除最旧的记录，防止文件无限增长。

#### Scenario: 记录数超过 30 时裁剪最旧记录
- **WHEN** 追加后记录数超过 30
- **THEN** 保留最新 30 条，删除最旧的记录

#### Scenario: 记录数未超过 30 时全量保留
- **WHEN** 追加后记录数 ≤ 30
- **THEN** 所有历史记录完整保留，无删除

---

### Requirement: coverage-history.json 对应 unit-history.json 同步更新

每次 Run SHALL 同步更新 `unit/unit-history.json`，追加记录结构符合 `unit-history-list-page` spec 定义，保留最近 30 条。

#### Scenario: 每次 Run 同步写入 unit-history.json
- **WHEN** 单元测试 CI Run 完成并进入"Publish to gh-pages"步骤
- **THEN** `unit/unit-history.json` 和 `unit/coverage-history.json` 均被更新，记录数不超过 30
