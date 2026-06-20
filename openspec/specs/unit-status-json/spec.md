# unit-status-json

## Purpose

定义单元测试 CI 推送到 `gh-pages/` 根目录的 `unit-status.json` 文件的结构、写入时机和状态推导规则，供 Portal Landing Page 读取展示。

## Requirements

### Requirement: unit-status-json-schema
单测 CI（`ci-compile-check.yml`）在每次 run 后写入 `unit-status.json` 到 `gh-pages/` 根目录。

**字段：**
```json
{
  "suite": "unit",
  "status": "passed | failed | partial",
  "passed": <number>,
  "failed": <number>,
  "total": <number>,
  "run_number": <string>,
  "run_url": <string>,
  "timestamp": "<ISO 8601 UTC 时间>"
}
```

### Requirement: unit-status-json-timing
`unit-status.json` 必须在 Allure 报告推送到 `gh-pages/unit/` 之后立即生成并推送，属于同一 git commit。

### Requirement: unit-status-json-status-derivation
`status` 字段按如下规则推导：
- `failed == 0 && total > 0` → `"passed"`
- `failed > 0 && passed > 0` → `"partial"`
- `passed == 0 && total > 0` → `"failed"`
- `total == 0` → `"passed"`（编译检查无测试用例时默认通过）
