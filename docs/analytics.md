# 播放指标埋点文档

## 概述

本文档描述 Vidall TV 应用的播放指标埋点系统，包括事件定义、字段说明、使用示例和查询方法。

## 目标指标

- **播放成功率**：≥95%
- **首帧耗时 P50**：<1.5秒 (1500ms)
- **首帧耗时 P95**：<3秒 (3000ms)
- **字幕可用率**：≥95%
- **扫描覆盖率**：≥98%

## 架构设计

### 核心组件

1. **AnalyticsManager**：单例埋点管理器
   - 异步事件队列
   - 本地持久化存储
   - 定时批量刷新
   - 支持按类型、时间范围查询

2. **AnalyticsReporter**：数据聚合报表工具
   - 生成播放、字幕、扫描指标报告
   - 计算 P50/P95 百分位数
   - 导出 JSON 格式报告
   - 检查指标是否达标

3. **AnalyticsTypes**：事件类型和错误码定义
   - 9种事件类型
   - 3级错误码体系
   - 完整的 TypeScript 类型定义

### 设计原则

- **轻量异步**：所有埋点操作异步执行，不阻塞主流程
- **批量刷新**：定时批量写入本地存储，减少 I/O 开销
- **类型安全**：禁用 any/unknown，使用严格类型定义
- **分级错误码**：1xxx（播放）、2xxx（字幕）、3xxx（扫描）

## 事件类型定义

### 1. 播放相关事件

#### 1.1 播放开始 (play_start)

**触发时机**：用户点击播放，播放器开始初始化

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "play_start" | "play_start" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID，由管理器自动生成 | "1709097600000_abc123" |
| mediaId | string | 媒体ID（文件路径或唯一标识） | "/storage/video.mp4" |
| sourceType | string | 来源类型：url/local/webdav/unknown | "local" |
| duration | number | 视频时长（毫秒），可选 | 120000 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.PLAY_START,
  mediaId: '/storage/movies/example.mp4',
  sourceType: SourceType.LOCAL,
  duration: 120000
});
```

#### 1.2 播放准备成功 (play_prepared)

**触发时机**：播放器完成准备，进入 PREPARED 状态

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "play_prepared" | "play_prepared" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600500 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| mediaId | string | 媒体ID | "/storage/video.mp4" |
| sourceType | string | 来源类型 | "local" |
| prepareTime | number | 准备耗时（毫秒） | 500 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.PLAY_PREPARED,
  mediaId: '/storage/movies/example.mp4',
  sourceType: SourceType.LOCAL,
  prepareTime: 500
});
```

#### 1.3 播放失败 (play_failed)

**触发时机**：播放初始化、准备或播放过程中发生错误

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "play_failed" | "play_failed" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| mediaId | string | 媒体ID | "/storage/video.mp4" |
| sourceType | string | 来源类型 | "local" |
| errorCode | string | 错误码，见错误码表 | "1001" |
| errorMessage | string | 错误信息 | "AVPlayerAdapter init failed: ..." |
| errorLevel | string | 错误级别：info/warning/error/critical | "error" |

**错误码表（播放相关）**：

| 错误码 | 说明 |
|--------|------|
| 1001 | 播放器初始化失败 |
| 1002 | 播放准备失败 |
| 1003 | 播放源无效 |
| 1004 | 网络错误 |
| 1005 | 解码错误 |
| 1099 | 未知播放错误 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.PLAY_FAILED,
  mediaId: '/storage/movies/example.mp4',
  sourceType: SourceType.LOCAL,
  errorCode: ErrorCode.PLAY_INIT_FAILED,
  errorMessage: 'AVPlayerAdapter init failed: Invalid media source',
  errorLevel: ErrorLevel.ERROR
});
```

#### 1.4 首帧渲染 (play_first_frame)

**触发时机**：播放器首次进入 PLAYING 状态，首帧渲染完成

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "play_first_frame" | "play_first_frame" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097601200 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| mediaId | string | 媒体ID | "/storage/video.mp4" |
| sourceType | string | 来源类型 | "local" |
| firstFrameTime | number | 首帧耗时（毫秒），从 init 开始计时 | 1200 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.PLAY_FIRST_FRAME,
  mediaId: '/storage/movies/example.mp4',
  sourceType: SourceType.LOCAL,
  firstFrameTime: 1200
});
```

### 2. 字幕相关事件

#### 2.1 字幕切换 (subtitle_switch)

**触发时机**：用户切换字幕轨道（包括关闭字幕）

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "subtitle_switch" | "subtitle_switch" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| mediaId | string | 媒体ID | "/storage/video.mp4" |
| fromTrackIndex | number | 原字幕轨道索引，-1表示关闭，可选 | 0 |
| toTrackIndex | number | 目标字幕轨道索引，-1表示关闭 | 1 |
| subtitleFormat | string | 字幕格式：embedded/srt/ass/vtt/unknown | "srt" |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.SUBTITLE_SWITCH,
  mediaId: '/storage/movies/example.mp4',
  fromTrackIndex: 0,
  toTrackIndex: 1,
  subtitleFormat: SubtitleFormatType.SRT
});
```

#### 2.2 字幕加载成功 (subtitle_load_success)

**触发时机**：字幕文件加载并解析成功

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "subtitle_load_success" | "subtitle_load_success" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| mediaId | string | 媒体ID | "/storage/video.mp4" |
| trackIndex | number | 字幕轨道索引 | 0 |
| subtitleFormat | string | 字幕格式 | "srt" |
| loadTime | number | 加载耗时（毫秒） | 300 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.SUBTITLE_LOAD_SUCCESS,
  mediaId: '/storage/movies/example.mp4',
  trackIndex: 0,
  subtitleFormat: SubtitleFormatType.SRT,
  loadTime: 300
});
```

#### 2.3 字幕加载失败 (subtitle_load_failed)

**触发时机**：字幕文件加载或解析失败

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "subtitle_load_failed" | "subtitle_load_failed" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| mediaId | string | 媒体ID | "/storage/video.mp4" |
| trackIndex | number | 字幕轨道索引，可选 | 0 |
| subtitleFormat | string | 字幕格式 | "srt" |
| errorCode | string | 错误码，见错误码表 | "2001" |
| errorMessage | string | 错误信息 | "Failed to parse subtitle file" |
| errorLevel | string | 错误级别 | "warning" |

**错误码表（字幕相关）**：

| 错误码 | 说明 |
|--------|------|
| 2001 | 字幕解析失败 |
| 2002 | 字幕加载失败 |
| 2003 | 字幕格式不支持 |
| 2004 | 字幕文件不存在 |
| 2099 | 未知字幕错误 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.SUBTITLE_LOAD_FAILED,
  mediaId: '/storage/movies/example.mp4',
  trackIndex: 0,
  subtitleFormat: SubtitleFormatType.SRT,
  errorCode: ErrorCode.SUBTITLE_PARSE_FAILED,
  errorMessage: 'Failed to parse subtitle file',
  errorLevel: ErrorLevel.WARNING
});
```

### 3. 扫描相关事件

#### 3.1 扫描完成 (scan_completed)

**触发时机**：文件源扫描完成（每个文件源单独记录）

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "scan_completed" | "scan_completed" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| sourceId | string | 文件源ID | "1" |
| sourceName | string | 文件源名称 | "本地视频" |
| totalFiles | number | 扫描总文件数 | 100 |
| successFiles | number | 成功处理文件数 | 98 |
| failedFiles | number | 失败文件数 | 2 |
| scanTime | number | 扫描总耗时（毫秒） | 5000 |
| coverageRate | number | 扫描覆盖率（0-1） | 0.98 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.SCAN_COMPLETED,
  sourceId: '1',
  sourceName: '本地视频',
  totalFiles: 100,
  successFiles: 98,
  failedFiles: 2,
  scanTime: 5000,
  coverageRate: 0.98
});
```

#### 3.2 扫描失败 (scan_failed)

**触发时机**：扫描过程中发生错误

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|-----|------|------|------|
| eventType | string | 事件类型，固定为 "scan_failed" | "scan_failed" |
| timestamp | number | 事件发生时间戳（毫秒） | 1709097600000 |
| sessionId | string | 会话ID | "1709097600000_abc123" |
| sourceId | string | 文件源ID | "1" |
| sourceName | string | 文件源名称 | "WebDAV" |
| failedFilesList | string[] | 失败文件列表（路径） | ["/dir1/file1.mp4"] |
| errorCode | string | 错误码，见错误码表 | "3001" |
| errorMessage | string | 错误信息 | "Access denied" |
| errorLevel | string | 错误级别 | "error" |

**错误码表（扫描相关）**：

| 错误码 | 说明 |
|--------|------|
| 3001 | 扫描访问被拒绝 |
| 3002 | 扫描网络错误 |
| 3003 | 扫描路径不存在 |
| 3004 | 扫描超时 |
| 3099 | 未知扫描错误 |

**示例代码**：

```typescript
analyticsManager.track({
  eventType: EventType.SCAN_FAILED,
  sourceId: '1',
  sourceName: 'WebDAV',
  failedFilesList: ['/movies/dir1/video.mp4'],
  errorCode: ErrorCode.SCAN_ACCESS_DENIED,
  errorMessage: 'Access denied to remote directory',
  errorLevel: ErrorLevel.ERROR
});
```

## 使用指南

### 1. 初始化埋点管理器

在应用启动时初始化埋点管理器：

```typescript
import { AnalyticsManager } from '../analytics/AnalyticsManager';

// 在 EntryAbility 的 onCreate 中初始化
async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
  const analyticsManager = AnalyticsManager.getInstance();
  await analyticsManager.init(this.context, {
    maxQueueSize: 1000,          // 最大队列大小
    flushInterval: 30000,        // 刷新间隔 30秒
    batchSize: 50,               // 批量上传大小
    enableLocalStorage: true,    // 启用本地存储
    enableConsoleLog: false      // 禁用控制台日志（生产环境）
  });
}
```

### 2. 记录埋点事件

在代码中记录埋点事件：

```typescript
import { AnalyticsManager } from '../analytics/AnalyticsManager';
import { EventType, SourceType, ErrorCode, ErrorLevel } from '../analytics/AnalyticsTypes';

const analyticsManager = AnalyticsManager.getInstance();

// 记录播放开始
analyticsManager.track({
  eventType: EventType.PLAY_START,
  mediaId: videoData.videoSrc,
  sourceType: SourceType.LOCAL,
  duration: videoData.duration
});

// 记录播放失败
analyticsManager.track({
  eventType: EventType.PLAY_FAILED,
  mediaId: videoData.videoSrc,
  sourceType: SourceType.LOCAL,
  errorCode: ErrorCode.PLAY_INIT_FAILED,
  errorMessage: `Init failed: ${err.message}`,
  errorLevel: ErrorLevel.ERROR
});
```

### 3. 查询埋点数据

```typescript
// 获取所有事件
const allEvents = await analyticsManager.getAllEvents();

// 按事件类型查询
const playStartEvents = await analyticsManager.getEventsByType(EventType.PLAY_START);

// 按时间范围查询
const startTime = Date.now() - 24 * 60 * 60 * 1000;  // 24小时前
const endTime = Date.now();
const events = await analyticsManager.getEventsByTimeRange(startTime, endTime);

// 导出所有事件为 JSON
const jsonData = await analyticsManager.exportEvents();
console.log(jsonData);
```

### 4. 生成指标报告

```typescript
import { AnalyticsReporter } from '../analytics/AnalyticsReporter';

const reporter = new AnalyticsReporter();

// 生成最近24小时报告
const report24h = await reporter.generateLast24HoursReport();

// 生成最近7天报告
const report7d = await reporter.generateLast7DaysReport();

// 生成自定义时间范围报告
const startTime = Date.now() - 7 * 24 * 60 * 60 * 1000;
const endTime = Date.now();
const customReport = await reporter.generateReport(startTime, endTime);

// 格式化报告为可读字符串
const formatted = reporter.formatReport(customReport);
console.log(formatted);

// 导出报告为 JSON
const jsonReport = await reporter.exportReportAsJson(startTime, endTime);

// 检查指标是否达标
const targets = reporter.checkMetricsTargets(customReport);
if (targets.allTargetsMet) {
  console.log('所有指标都达标！');
} else {
  console.log('部分指标未达标：');
  console.log(`播放成功率：${targets.playSuccessRateOk ? '达标' : '未达标'}`);
  console.log(`首帧时间P50：${targets.firstFrameP50Ok ? '达标' : '未达标'}`);
  console.log(`首帧时间P95：${targets.firstFrameP95Ok ? '达标' : '未达标'}`);
  console.log(`字幕可用率：${targets.subtitleAvailabilityOk ? '达标' : '未达标'}`);
  console.log(`扫描覆盖率：${targets.scanCoverageOk ? '达标' : '未达标'}`);
}
```

### 5. 清理数据

```typescript
// 清空所有事件
await analyticsManager.clearAllEvents();

// 清除7天前的数据
const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
await analyticsManager.clearEventsBefore(sevenDaysAgo);
```

## 报告示例

### 文本格式报告

```
=== 播放指标埋点报告 ===

报告生成时间: 2026-02-28 16:00:00
统计时间范围: 2026-02-27 16:00:00 - 2026-02-28 16:00:00

--- 播放指标 ---
总播放尝试次数: 120
成功播放次数: 115
失败播放次数: 5
播放成功率: 95.83% (目标: ≥95%)
首帧时间 P50: 1200ms (目标: <1500ms)
首帧时间 P95: 2800ms (目标: <3000ms)
首帧平均时间: 1500ms

--- 字幕指标 ---
总加载尝试次数: 80
成功加载次数: 77
失败加载次数: 3
字幕可用率: 96.25% (目标: ≥95%)
平均加载时间: 250ms

--- 扫描指标 ---
总扫描次数: 5
总文件数: 500
成功处理文件数: 495
失败文件数: 5
扫描覆盖率: 99.00% (目标: ≥98%)
平均扫描时间: 4500ms
```

### JSON格式报告

```json
{
  "reportTime": 1709118000000,
  "timeRange": {
    "startTime": 1709031600000,
    "endTime": 1709118000000
  },
  "playMetrics": {
    "totalPlayAttempts": 120,
    "successfulPlays": 115,
    "failedPlays": 5,
    "successRate": 0.9583,
    "firstFrameTimeP50": 1200,
    "firstFrameTimeP95": 2800,
    "avgFirstFrameTime": 1500,
    "firstFrameTimes": [800, 1000, 1200, ...]
  },
  "subtitleMetrics": {
    "totalLoadAttempts": 80,
    "successfulLoads": 77,
    "failedLoads": 3,
    "availabilityRate": 0.9625,
    "avgLoadTime": 250
  },
  "scanMetrics": {
    "totalScans": 5,
    "totalFiles": 500,
    "successFiles": 495,
    "failedFiles": 5,
    "coverageRate": 0.99,
    "avgScanTime": 4500
  }
}
```

## 注意事项

1. **性能影响**：埋点操作是异步的，不会阻塞主流程，对性能影响极小
2. **存储容量**：默认最多存储 2000 个事件，超过后会删除最旧的事件
3. **数据隐私**：埋点数据仅存储在本地，不会自动上传到服务器
4. **错误处理**：埋点失败不会影响应用正常功能，所有错误都会被捕获并记录
5. **类型安全**：严格遵循 TypeScript 类型定义，禁止使用 any/unknown

## 常见问题

### Q: 如何手动触发数据刷新？

A: 调用 `analyticsManager.flush()` 方法即可手动刷新队列到本地存储。

### Q: 如何禁用埋点？

A: 在初始化时不调用 `analyticsManager.init()`，或者不调用 `track()` 方法即可。

### Q: 如何在测试环境中查看埋点日志？

A: 在初始化时设置 `enableConsoleLog: true`，埋点事件会输出到控制台。

### Q: 埋点数据会占用多少存储空间？

A: 每个事件约 200-500 字节，默认最多 2000 个事件，总计约 0.4-1MB 存储空间。

### Q: 如何导出埋点数据用于分析？

A: 使用 `analyticsManager.exportEvents()` 导出 JSON 格式数据，可以保存到文件或发送到服务器。

## 版本历史

- **v1.0.0** (2026-02-28)
  - 初始版本
  - 实现播放、字幕、扫描埋点
  - 实现本地存储和查询
  - 实现聚合报表功能
