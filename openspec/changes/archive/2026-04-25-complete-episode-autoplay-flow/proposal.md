## Why

当前播放器已经具备基础的播放上下文和选集面板，但当季完整剧集列表仍缺少基于本地已刮削数据的稳定匹配层，自动下一集、倒计时和取消交互也尚未收口。现在需要把 `#122` 与 `#123` 统一推进，补齐“本地季集识别 -> 切集 -> 自动续播”的连续观看闭环。

## What Changes

- 新增本地剧集匹配能力，基于 `tv_episodes`、`scrape_info` 和 `videos` 构建当前季的完整可播放列表，不在播放器流程中实时请求外部 API。
- 调整播放器播放上下文的构建方式，使媒体库场景优先使用本地匹配结果作为剧集列表来源，并支持进程内缓存与缺失数据降级。
- 新增自动下一集能力，包括接近播放完成时的倒计时提示、取消交互、快捷键处理和失败降级。
- 新增播放器相关设置项，使自动播放开关和倒计时秒数能够在播放器设置中生效。

## Capabilities

### New Capabilities
- `episode-autoplay`: 定义媒体库场景下自动下一集、倒计时提示、取消操作和相关设置项的行为。

### Modified Capabilities
- `playback-context`: 调整媒体库播放上下文的剧集列表来源与导航语义，使其基于本地已刮削季集数据和视频匹配结果构建可播放列表。

## Impact

- Affected specs: `openspec/specs/playback-context/spec.md`，新增 `openspec/specs/episode-autoplay/spec.md`
- Affected code: `entry/src/main/ets/components/core/player/`、`entry/src/main/ets/pages/player/`、`entry/src/main/ets/pages/detail/`、`entry/src/main/ets/db/files/FileSourceDatabase.ets`
- Affected tests: 播放上下文、播放器交互、自动播放与设置项相关单测/集成测试
- Dependencies: 继续复用现有本地数据库与播放器控制器，不新增外部网络依赖
