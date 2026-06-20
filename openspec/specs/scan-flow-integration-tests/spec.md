# Scan Flow Integration Tests

## Purpose

提供扫描流程的集成测试覆盖，验证 WebDAV 连接成功前提下的扫描触发和状态变更。

## Requirements

### Requirement: 基于 WebDAV 连接成功的扫描触发测试
系统 SHALL 提供自动化测试用例，在 WebDAV 连接已验证成功的前提下，导航到扫描入口页面，触发"快速扫描"，验证扫描状态从空闲变为运行中、再变回完成状态，且扫描统计数值（视频数/目录数）有非负整数输出。

#### Scenario: 快速扫描触发并完成
- **WHEN** 在扫描入口页点击"快速扫描"按钮
- **THEN** 页面出现扫描进行中的状态指示，扫描完成后统计数值大于等于 0

#### Scenario: 扫描页面统计区域可见
- **WHEN** 进入扫描入口页
- **THEN** 页面中存在显示视频文件数、目录数的统计文本区域

---

### Requirement: 扫描流程集成测试可通过参数跳过
当 `SKIP_SCAN_TESTS` 参数为 `true` 时，扫描流程测试套件 SHALL 被跳过。此参数默认值为 `false`，CI 中在 WebDAV 凭据不可用时应设为 `true`。

#### Scenario: SKIP_SCAN_TESTS=true 时扫描测试被跳过
- **WHEN** `aa test` 启动时传入 `-s SKIP_SCAN_TESTS true`
- **THEN** 扫描流程相关用例不执行，测试报告中标记为跳过，不影响其他套件运行
