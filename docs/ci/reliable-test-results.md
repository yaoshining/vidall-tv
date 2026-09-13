# 可核验的单测结果与成套签名

## 问题与环境

iMac 为 Intel/macOS，SDK Previewer API 24、6.1.1.125，Hypium 锁定 1.0.25。hvigor test 实际启动 Previewer；工作流保留原设备前置检查，但不作为真机单测证据。GC 线程输出可插入用例名和状态码，SDK 生成的 test_result.txt 又省略用例编号，不能用末尾汇总补造逐例结果。

## 结构化通道

StructuredReport.js 通过 Hypium Core 的 spec/suite/task 事件采集真实开始、结束和失败状态。在 SDK OhReport.finishTest 之前，使用与覆盖率相同的文件 API 写入 gate-results.json，不修改 SDK、依赖、断言或业务代码。

执行器在启动当前进程前生成 gate-context.json，包含 run ID、SHA 和执行开始时间，并删除旧结果。门禁核对注册数量、连续逐例编号、名称、状态、框架汇总、hook 错误和完成时间。缺失、损坏、旧身份、未完成、0 项、跳过、失败、错误、计数不一致、非零退出码、超时和 OhmUrl 仍失败。未配置上下文的普通本地单测继续使用 SDK 报告。

原始 coverage.log、SDK test_result.txt 和结构化报告同时保留。CI 选择结构化报告为唯一逐例证据，缺失时不回退到文本汇总。legacy 解析继续用于历史回归，未增加字符修补规则。

## 签名材料

旧 CI 日志包含证书在 2026-08-05 过期及 keystore 打开失败。本机成套材料的开发者证书有效至 2027-08-22，已通过 deveco-cli 签名构建。

工作流使用新的 SIGNING_BUNDLE_BASE64，旧 Secrets 保留。包内包含证书链、P12、profile、5 个配套 material 文件和校验清单。恢复器只接受指定文件结构，拒绝链接、路径穿越、重复/缺失文件、校验和或 default 配置不匹配、过期证书。材料存放在本次运行专用的 0700 目录、文件权限 0600，工作流结束后清理。只替换 default 配置的证书路径，保持密码和别名；材料不进入 Git 或 Actions artifacts。

重新打包使用 restore_signing.package_bundle(Path('certs/debug'), Path('build-profile.json5').read_text())，获得明确凭据上传授权后通过 stdin 传给 gh secret set SIGNING_BUNDLE_BASE64，不打印包内容。回滚工作流可重新引用旧 Secrets，但旧证书已过期，回滚不等于签名可用。

集成依赖恢复使用官方 ohpm install，覆盖完整依赖图，不修改锁文件或版本；此前手动还原部分 HAR 无法保证 pinyin-pro 等依赖存在。

## 验证

- 本机 Apple M1 Max/macOS Previewer 正例 795/795，结构化门禁通过。
- 隔离工作树临时注入一项真实断言失败：794 通过、1 失败，门禁拒绝；注入源文件已恢复，未提交。
- Python 和 Node 回归覆盖缺失/重复/错配、跳过、失败、hook 错误、旧报告、磁盘写失败及材料混配。
- deveco-cli 应用签名构建与 UnitTestBuild 通过。最终 SHA 的 CI 结果以 PR Actions 为准。

这些结果不替代物理 TV/API19、UI/遥控器及设备性能测量。首页优化仍在独立 PR #335。
