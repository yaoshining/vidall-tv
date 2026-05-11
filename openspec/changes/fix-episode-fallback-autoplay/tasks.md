## 1. 恢复决策建模

- [x] 1.1 梳理 `VideoPlayerController` 当前 pending resume state 的字段与消费路径，补齐“恢复后是否自动播放”的显式决策来源
- [x] 1.2 调整切集/`reloadSource`/续播初始化链路，使新媒体在建立恢复决策时不再只依赖瞬时 `isPlaying` 或 `isSeeking`

## 2. Fallback 透传与消费

- [x] 2.1 修改 AVPlayer unsupported fallback 捕获逻辑，确保在 `seekDone -> play()` 窗口内仍能保留自动播放意图
- [x] 2.2 调整 fallback 后新后端 ready 的恢复逻辑，保证位置与自动播放语义只消费一次且不会污染后续媒体会话

## 3. 诊断与验证

- [x] 3.1 补充续播恢复链路的结构化日志，覆盖恢复决策建立、fallback 捕获、fallback 消费与自动播放执行结果
- [x] 3.2 为切集后触发 unsupported fallback 的场景补充验证用例，确认“位置正确且自动播放恢复”与“应保持暂停”两类语义都不回归
