# 历史输出兼容性样例

`unit-success-612.txt` 来自原项目本地 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`，读取于 2026-09-12。它是已生成的历史成功结果，汇总为 612 执行、612 通过、0 失败、0 错误、0 忽略。只将 class/test 名称脱敏为顺序编号，行序、逐例状态与原始汇总保持不变。

原始文件 SHA-256：`e243c4fa5cacda957e821aa8bed91d860ca2fcd6307499155fff8079a337faaf`。
原始文件修改时间（UTC）：`2026-08-22T08:28:54.031445+00:00`。

此样例证明当前解析器兼容已有工具输出，不证明当前提交已在设备执行，也不将该历史结果作为门禁通过依据。测试用例直接验证解析结果；正式门禁仍拒绝早于当前执行的文件。

历史成功集成运行 25383382116 的 GitHub 日志已返回 HTTP 410，本地也没有 aa-test.log。真实集成输出兼容性尚未验收，仅有可控协议样例，未为获取日志操作设备。

`unit-success-795.txt` 来自本 PR 的真实运行 [34704387512](https://github.com/yaoshining/vidall-tv/actions/runs/34704387512)，artifact `unit-test-results-550/test_result.txt`。795 个结果均成功，但旧解析器拒绝了一对重复 test 行：第一行被插入 hilog 时间/PID/TID，第二行是相同名称的完整重发。本样例脱敏名称，保留此重复及附加字段、所有 result 与汇总，用于验证兼容性。原始 SHA-256：`957c1348202a197758a4af7873d23d4cf7dfa00b2b25510dfb1b9a7b145afc44`。
