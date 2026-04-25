## 1. 本地季集匹配能力

- [x] 1.1 新增 `EpisodeGroupMatcher`，实现基于本地 `tv_episodes`、`scrape_info` 与 `videos` 的季集查询与匹配
- [x] 1.2 为 `EpisodeGroupMatcher` 增加会话级缓存与缺失数据降级逻辑
- [x] 1.3 补充 `EpisodeGroupMatcher` 的单元测试，覆盖正常匹配、缺集、无元数据、缓存命中场景

## 2. PlaybackContext 集成收口

- [x] 2.1 调整 `MediaLibraryContext` 构建流程，改为复用 `EpisodeGroupMatcher` 生成当前季可播放列表
- [x] 2.2 更新播放器和详情页入口，确保媒体库上下文统一走本地匹配结果且保持现有切集链路兼容
- [x] 2.3 补充 `PlaybackContext` / `MediaLibraryContext` 相关测试，验证排序、索引回退和局部缺集降级

## 3. 自动下一集与设置交互

- [x] 3.1 在 `EpisodePlaybackManager` 中实现自动下一集状态机，复用现有切集逻辑处理下一集跳转
- [x] 3.2 在播放器页面补充倒计时提示、返回键/ESC 取消和手动切集时的倒计时清理
- [x] 3.3 在 `PlayerSettingsDialog` 中增加自动下一集开关与倒计时秒数设置，并与播放流程联动
- [x] 3.4 处理无下一集、列表缺失、下一集加载失败等异常场景的安全降级

## 4. 回归验证与规格同步

- [x] 4.1 补充自动下一集与设置项测试，覆盖启用、关闭、取消、失败降级场景
- [x] 4.2 运行相关本地单测与播放器回归构建，确认切集、自动播放和设置项链路通过
- [x] 4.3 更新 change 中的任务勾选与必要说明，确保变更达到 apply-ready 和实现闭环
