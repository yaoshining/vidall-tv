# Ijk 字幕桥接实施方案（先 ijk 后统一软字幕）

## 1. 目标与范围

### 1.1 目标
- 先在 HarmonyOS TV 的 `ijkplayer` 路径补齐字幕能力，覆盖家庭用户主要观影场景。
- 保证方案可回收：后续切换到统一软字幕渲染时，页面层和控制层改动最小。

### 1.2 用户与痛点
- 用户：家庭用户。
- 当前痛点：
  - `ijkplayer` 字幕支持不足。
  - `AVPlayer` 内嵌轨道嗅探信息不准确（名称/语言/编码）。

### 1.3 范围约束
- 本阶段先支持：内嵌/外置字幕基础能力。
- 外置格式先支持：`srt`、`vtt`。
- 暂不做：`ass` 特效级渲染（可保留基础文本兼容策略）。

## 2. 成功指标（验收）
- 常见格式播放成功率 >= 95%。
- 存在字幕资源时字幕可用命中率 >= 90%。
- 字幕与播放进度偏差 P95 <= 120ms。
- `seek` 后字幕恢复 <= 200ms。
- 字幕开启后额外 CPU 增量目标 < 8%。

## 3. 总体设计

### 3.1 设计原则
- 单一时间源：字幕时间轴只跟随播放器 `positionMs`。
- 后端解耦：上层仅依赖统一字幕适配接口，不依赖 `ijk` 特有字段。
- 渲染解耦：字幕渲染与播放后端隔离，后续可平滑替换为统一软渲染引擎。

### 3.2 关键分层
1. `VideoPlayerController`：统一字幕控制入口、时间驱动、状态发布。
2. `SubtitleBackendAdapter`：后端适配层（`ijk`/`av`）。
3. UI 层（`VideoControls` + `VideoPlayer`）：只消费统一状态和控制方法。

## 4. 文件级改造清单

### 4.1 新增：统一适配接口
- 文件：`entry/src/main/ets/components/core/player/subtitle/SubtitleBackendAdapter.ets`
- 建议接口：
  - `loadTracks(): Promise<void>`
  - `getTracks(): SubtitleTrackItem[]`
  - `switchTrack(index: number): Promise<void>`
  - `loadExternalSubtitle(url: string, headers: Record<string, string>): Promise<void>`
  - `setDelayMs(ms: number): void`
  - `onSeek(positionMs: number): void`
  - `onPosition(positionMs: number): void`
  - `getCurrentSubtitleText(): string`
  - `release(): void`

### 4.2 新增：ijk 适配器
- 文件：`entry/src/main/ets/components/core/player/subtitle/IjkSubtitleBackendAdapter.ets`
- 内容：
  - 封装内嵌轨枚举、切轨、外挂字幕加载、偏移设置。
  - 对不可读轨道信息做兜底命名：`轨道1/轨道2`。
  - 不向上层暴露 `ijk` 私有字段。

### 4.3 新增：AV 适配器壳（可最小实现）
- 文件：`entry/src/main/ets/components/core/player/subtitle/AvSubtitleBackendAdapter.ets`
- 内容：
  - 先做接口对齐，减少控制层分支。

### 4.4 修改：控制器统一字幕入口
- 文件：`entry/src/main/ets/components/core/player/VideoPlayerController.ets`
- 新增字段建议：
  - `private subtitleAdapter: SubtitleBackendAdapter | null = null`
  - `private subtitleDelayMs: number = 0`
  - `private lastSubtitleText: string = ''`
- 新增方法建议：
  - `initSubtitleAdapter()`
  - `tickSubtitleByPosition(positionMs: number)`
  - `applySubtitleDelay(deltaMs: number)`
  - `switchSubtitleTrack(index: number)`（改为代理到 adapter）
- 行为要求：
  - 播放中按 100~200ms 更新字幕。
  - `seek` 后立即 `onSeek` 并刷新一次字幕。
  - 仅在字幕文本变化时更新 `subtitleUpdateCounter`。

### 4.5 修改：控制层菜单能力
- 文件：`entry/src/main/ets/components/core/player/VideoControls.ets`
- 内容：
  - 增加字幕偏移调节入口（例如 `-500ms`、`+500ms`）。
  - 展示当前偏移值。
  - 轨道不可读时显示兜底文案。

### 4.6 保持：UI 渲染层最小变更
- 文件：`entry/src/main/ets/components/core/player/VideoPlayer.ets`
- 内容：
  - 继续通过 `SubtitleRenderer` 渲染统一字幕状态。
  - 不直接调用 `ijk` 原生字幕 API。

## 5. 同步与性能策略

### 5.1 同步策略
- 唯一时间源：播放器当前位置 `positionMs`。
- `seek` 优先级最高：完成后立即重定位字幕。
- 偏移计算：`displayMs = positionMs + subtitleDelayMs`。

### 5.2 性能策略
- 禁止每 tick 全量扫描字幕。
- 采用“二分定位 + 游标推进”处理 cue。
- 字幕文本未变化时不触发 UI 更新。
- 外置字幕加载与解析异步执行，可中断旧任务。

## 6. 错误与降级
- 无字幕轨：提示“无可用字幕”，不影响播放。
- 字幕加载失败：提示错误并保留播放。
- 轨道信息缺失：使用兜底名称，不阻断切轨。
- 时间源异常：切到降级模式并记录日志。

## 7. 测试计划

### 7.1 功能测试
- 内嵌轨枚举/切换。
- 外置 `srt/vtt` 加载。
- 偏移调节生效。
- 无字幕与异常文件场景。

### 7.2 稳定性测试
- 高频 `seek`（连续拖动）。
- 长时播放（>= 60 分钟）漂移观察。
- 多格式回归（`mp4`、`mkv`、`ts`、`m2ts`、`avi`）。

### 7.3 性能测试
- 对比字幕开关前后 CPU 占用。
- 监控掉帧与卡顿。

## 8. 交付节奏（10 天）
- Day 1-4：子任务A（ijk 字幕后端能力）
- Day 5-7：子任务B（统一适配接口）
- Day 8-10：子任务C（同步与可观测性）

## 9. 对应 Issue
- Epic：#16
- 子任务A：#17
- 子任务B：#18
- 子任务C：#19

## 10. 后续演进（非本期）
- 引入统一软字幕渲染引擎，替换后端特有实现。
- 增强 ASS 支持（样式与特效分级实现）。
- 建立字幕质量自动化回归基线。