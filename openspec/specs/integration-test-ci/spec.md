## ADDED Requirements

### Requirement: 使用原始 bundle name 构建和安装 HAP
CI 流水线 SHALL 使用 `com.yao.vidalltv` 作为 bundleName 构建 app HAP 和 ohosTest HAP，不得在 CI 中修改 `app.json5` 的 bundleName。

#### Scenario: 构建 HAP 时不修改 app.json5
- **WHEN** 触发 `integration-test` workflow
- **THEN** `AppScope/app.json5` 中的 bundleName 保持为 `com.yao.vidalltv`

#### Scenario: 安装成功
- **WHEN** HAP 使用 `com.yao.vidalltv` bundle 签名
- **THEN** `hdc install` 返回 `install bundle successfully`，不返回签名验证失败错误

---

### Requirement: 精确定位 HAP 产物路径
CI 流水线 SHALL 优先使用固定预期路径定位 app HAP（`entry/build/default/outputs/default/entry-default-signed.hap`）和 test HAP（`entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap`）。

#### Scenario: HAP 产物在预期路径存在
- **WHEN** hvigor assembleHap 成功完成
- **THEN** workflow 直接使用预期路径，无需执行 `find` 兜底

#### Scenario: HAP 产物不在预期路径
- **WHEN** 预期路径不存在
- **THEN** 执行 `find` 兜底，打印所有 `.hap` 文件列表后以非零退出码失败

---

### Requirement: WebDAV 测试凭据从 GitHub Secrets 注入
`WebDAV.test.ets` 中的 WebDAV 服务器地址、用户名、密码 SHALL 从 `process.env` 读取，不得硬编码在源码中。

#### Scenario: Secrets 已配置
- **WHEN** `WEBDAV_HOST`、`WEBDAV_USERNAME`、`WEBDAV_PASSWORD` 均已设置
- **THEN** 测试使用 env 值发起连接，不使用硬编码默认值

#### Scenario: Secrets 未配置（本地开发兜底）
- **WHEN** 任一 env 变量未设置
- **THEN** 测试使用代码中的 fallback 默认值，确保本地 DevEco 调试不中断

---

### Requirement: hvigor 使用 `--no-daemon` 模式运行
所有 hvigor 调用（sync、assembleHap）SHALL 使用 `--no-daemon` 标志，不使用 `--daemon`。

#### Scenario: CI 构建完成后无遗留 daemon 进程
- **WHEN** workflow 所有 hvigor 步骤完成
- **THEN** 无 hvigor daemon 进程在后台存活

---

### Requirement: 集成测试结果须生成结构化报告
CI 流水线 SHALL 在 `aa test` 执行完成后，生成 Allure HTML 报告并发布到 `gh-pages` 分支的 `integration/` 子目录；workflow 须配置 `contents: write` 权限以支持 gh-pages push。

#### Scenario: 测试通过时生成报告
- **WHEN** `TestFinished-ResultCode: 0`
- **THEN** Allure HTML 报告已发布到 gh-pages，`integration/index.html` 可访问

#### Scenario: 测试失败时仍生成报告
- **WHEN** `TestFinished-ResultCode` 非 0
- **THEN** Allure HTML 报告仍发布（`if: always()` 步骤），记录失败用例，workflow 以非零退出码结束

---

### Requirement: Job Summary 包含测试通过/失败统计
workflow SHALL 在 `$GITHUB_STEP_SUMMARY` 中写入集成测试的 pass/fail 汇总行。

#### Scenario: 测试全部通过
- **WHEN** `aa-test.log` 包含 `TestFinished-ResultCode: 0`
- **THEN** Summary 显示 `集成测试通过`

#### Scenario: 测试失败
- **WHEN** `aa-test.log` 不包含 `TestFinished-ResultCode: 0`
- **THEN** Summary 显示失败信息，并附加最近 50 行 hilog 内容

---

### Requirement: CI 环境校验包含签名证书存在性检查
`Verify self-hosted runner environment` 步骤 SHALL 检查 signing profile 中引用的 `.cer`、`.p7b`、`.p12` 文件是否存在。

#### Scenario: 证书文件存在
- **WHEN** `build-profile.json5` 中 default signing config 的证书文件均可访问
- **THEN** 环境校验步骤通过

#### Scenario: 证书文件缺失
- **WHEN** 任一证书文件不存在
- **THEN** 环境校验步骤以非零退出码失败，并输出缺失的文件路径

---

### Requirement: integration-ci-status-json-push
集成测试 workflow（`integration-test.yml`）SHALL 在 Allure 报告发布步骤完成后，额外生成并推送 `integration-status.json` 到 `gh-pages/` 根目录。

#### Scenario: 集成测试运行完成
- **WHEN** Allure 报告成功推送到 `gh-pages/integration/`
- **THEN** `integration-status.json` 被写入 `gh-pages/` 根目录，内容符合 integration-status-json spec 的字段定义

---

### Requirement: integration-ci-portal-update
集成测试 workflow SHALL 在推送 `integration-status.json` 后，读取 `unit-status.json`（如存在）合并生成 portal `index.html`，并推送到 `gh-pages/` 根目录。

#### Scenario: unit-status.json 存在
- **WHEN** `gh-pages/unit-status.json` 存在
- **THEN** portal 展示单测和集成测试各自的状态卡片

#### Scenario: unit-status.json 不存在
- **WHEN** `gh-pages/unit-status.json` 不存在
- **THEN** portal 单测卡片显示"🔄 尚未运行"占位状态，不报错
