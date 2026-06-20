# integration-status-json

## Purpose

定义集成测试 CI 推送到 `gh-pages/` 根目录的 `integration-status.json` 文件的结构、写入时机和状态推导规则，供 Portal Landing Page 读取展示。

## Requirements

### Requirement: integration-status-json-schema
集成测试 CI（`integration-test.yml`）在每次 run 后写入 `integration-status.json` 到 `gh-pages/` 根目录。

**字段：**
```json
{
  "suite": "integration",
  "status": "passed | failed | partial",
  "passed": <number>,
  "failed": <number>,
  "total": <number>,
  "run_number": <string>,
  "run_url": <string>,
  "timestamp": "<ISO 8601 UTC 时间>"
}
```

### Requirement: integration-status-json-timing
`integration-status.json` 必须在 Allure 报告推送到 `gh-pages/integration/` 之后立即生成并推送，属于同一 git commit。

### Requirement: integration-status-json-status-derivation
`status` 字段按如下规则推导（同 unit-status-json 规范）：
- `failed == 0 && total > 0` → `"passed"`
- `failed > 0 && passed > 0` → `"partial"`
- `passed == 0 && total > 0` → `"failed"`
- `total == 0` → `"passed"`
