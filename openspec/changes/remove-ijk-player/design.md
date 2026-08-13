## Context

播放器目前通过统一接口承载 AVPlayer、IJKPlayer、MPV，以及兼容保留的 native/ffmpeg 标识。IJK 的依赖、libraryname XComponent、字幕桥接、DAR 布局、硬解探测、SMB 代理接管和偏好设置分散在多个模块中。参见 `proposal.md` 的动机与范围。

MPV 已通过 controller surface 模式接入，并能直接消费 SMB URI；AVPlayer 仍依赖现有 HTTP 代理。ffprobe 与 SMB 字幕桥接也会读取普通代理 URL，因此代理功能不能因删除 IJK 而整体移除。

## Goals / Non-Goals

**Goals:**

- 将活跃播放链路收敛为 AVPlayer 主路径、MPV 唯一回退。
- 完整删除 IJK 二进制、运行时分支、UI 入口和支撑代码。
- 保持续播位置、自动播放意图、字幕轨和 SMB 播放行为连续。
- 让类型、测试、文档和规格不再表达 IJK 可用性。

**Non-Goals:**

- 不删除兼容保留的 native/ffmpeg 后端标识；仅把其旧映射目标改为 MPV。
- 不替换 MPV HAR 或项目自有 FFmpeg 动态库。
- 不重构通用轨道预探测数据模型。
- 不新增模拟器软解后端。

## Decisions

### 1. 固定 AVPlayer → MPV 单向回退

后端决策不再读取 `PLAYER_FALLBACK`，AVPlayer 的 unsupported/error fallback 固定为 MPV。MPV 失败直接进入统一错误处理。

选择该方案是因为只剩一个可用软解后端，保留偏好和双向切换只会制造无效状态。备选方案是保留“固定 MPV”设置项，但该入口没有可操作价值，因此放弃。

### 2. 删除 IJK 类型，而非仅隐藏入口

从活跃 backend union、字幕 bridge kind、adapter factory 和 UI 分支中删除 IJK。历史 native/ffmpeg 标识暂保留，以降低本次跨模块兼容风险，但统一映射至 MPV。

备选方案是保留 IJK 枚举作为空壳；这会让调用方继续构造不可实现状态，故不采用。

### 3. 按使用者拆分 SMB 代理清理

保留 AVPlayer、ffprobe、SMB 字幕读取所需的代理 URL 生成和普通生命周期；删除仅为 IJK 接管而存在的 keep-proxy、orphan proxy 和 context 重启流程。

`getProxyUrl` 仍有非 IJK 调用，不能整体删除。原生 C++ 注释和导出按实际调用关系同步收敛。

### 4. 删除 IJK 专属显示与能力代码

`PlayerAspectRatioUtil` 当前只服务 IJK adapter，可整体删除。`VideoPlayerLayoutUtil` 只删除 IJK 尺寸配置，保留 AVPlayer/MPV 共用的 `AspectRatioMode` 到 `RenderFit` 映射。

IJK 硬解决策使用的设备解码能力查询若无其他调用，则同时删除 ArkTS 封装、NAPI 类型声明、C++ 实现和导出，避免遗留不可达原生 API。

### 5. 保留通用媒体轨道预探测

`presetAudioTracks` 与 `presetSubtitleTracks` 继续保留，因为 MPV adapter、音轨路由、ffprobe、SMB 字幕桥接和多个播放入口均在使用。仅修正其中 IJK 专属描述。

### 6. 通过 delta spec 移除 IJK capability

`ijkplayer-aspect-ratio` 使用 REMOVED requirements 明确退役；其他受影响 capability 提供完整 MODIFIED/REMOVED requirement。主规格不在 proposal 阶段直接手改，后续由 OpenSpec sync/archive 流程合并。

## Risks / Trade-offs

- [MPV 在不兼容架构不可用时没有软解替代] → 在 AVPlayer 失败后展示统一错误，规格明确禁止回退到已移除内核。
- [删除 union 值可能暴露大量编译引用] → 分层先改 types/service，再改 controller/UI，最后通过全仓残留搜索和 HAP 编译收口。
- [误删 SMB 代理导致 AVPlayer、ffprobe 或字幕回归] → 以调用关系为准保留 `getProxyUrl` 和普通代理路径，只删除 keep-proxy/orphan 逻辑。
- [旧偏好数据残留] → 不做存储迁移；停止读取该 key 后旧数据无行为影响。
- [历史 deep link 或页面参数传入 ijkplayer] → 编译期类型移除；对兼容保留的 ffmpeg/native 映射 MPV，不为 IJK 字符串保留运行时能力。

## Migration Plan

1. 更新后端类型和 service，使 MPV 成为唯一 fallback。
2. 删除 IJK adapter、依赖和专属支撑代码。
3. 清理 controller、UI、设置和偏好分支。
4. 更新测试、文档与注释，刷新依赖锁文件。
5. 执行格式/lint（若仓库存在对应任务）、单测编译、HAP 编译及全仓 IJK 残留检查。
6. 若出现不可接受回归，可整体回滚该 change 的实现提交；旧偏好数据未迁移，因此回滚不需要数据恢复。
