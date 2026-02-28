# Analytics 埋点模块

## 简介

本模块为 Vidall TV 提供轻量级的播放指标埋点功能，用于采集和分析以下核心健康指标：

- **播放成功率**（目标 ≥95%）
- **首帧耗时**（P50 <1.5s, P95 <3s）
- **字幕可用率**（目标 ≥95%）
- **扫描覆盖率**（目标 ≥98%）

## 特性

- ✅ **轻量异步**：不阻塞播放主流程
- ✅ **类型安全**：完整的 TypeScript 类型定义
- ✅ **本地存储**：基于 Preferences API 持久化
- ✅ **聚合报表**：支持 P50/P95 百分位计算
- ✅ **错误分级**：三级错误码体系（1xxx/2xxx/3xxx）

## 快速开始

### 1. 初始化

在应用启动时初始化埋点管理器：

```typescript
import { AnalyticsManager } from './analytics/AnalyticsManager';

const analyticsManager = AnalyticsManager.getInstance();
await analyticsManager.init(context, {
  maxQueueSize: 1000,
  flushInterval: 30000,
  batchSize: 50,
  enableLocalStorage: true,
  enableConsoleLog: false
});
```

### 2. 记录事件

```typescript
import { EventType, SourceType } from './analytics/AnalyticsTypes';

// 记录播放开始
analyticsManager.track({
  eventType: EventType.PLAY_START,
  mediaId: 'video.mp4',
  sourceType: SourceType.LOCAL,
  duration: 120000
});

// 记录首帧时间
analyticsManager.track({
  eventType: EventType.PLAY_FIRST_FRAME,
  mediaId: 'video.mp4',
  sourceType: SourceType.LOCAL,
  firstFrameTime: 1200
});
```

### 3. 生成报告

```typescript
import { AnalyticsReporter } from './analytics/AnalyticsReporter';

const reporter = new AnalyticsReporter();
const report = await reporter.generateLast24HoursReport();

console.log(reporter.formatReport(report));
```

## 文件结构

```
entry/src/main/ets/analytics/
├── AnalyticsTypes.ets      # 事件类型定义
├── AnalyticsManager.ets    # 埋点管理器
└── AnalyticsReporter.ets   # 聚合报表工具

entry/src/test/
├── AnalyticsManager.test.ets    # 管理器测试
└── AnalyticsReporter.test.ets   # 报表测试

docs/
└── analytics.md            # 完整文档
```

## 事件类型

### 播放事件
- `PLAY_START` - 播放开始
- `PLAY_PREPARED` - 播放准备成功
- `PLAY_FAILED` - 播放失败
- `PLAY_FIRST_FRAME` - 首帧渲染

### 字幕事件
- `SUBTITLE_SWITCH` - 字幕切换
- `SUBTITLE_LOAD_SUCCESS` - 字幕加载成功
- `SUBTITLE_LOAD_FAILED` - 字幕加载失败

### 扫描事件
- `SCAN_COMPLETED` - 扫描完成
- `SCAN_FAILED` - 扫描失败

## 测试

运行单元测试：

```bash
# 所有测试
npm run test

# 仅埋点测试
npm run test -- --filter Analytics
```

测试覆盖率：≥85%

## 文档

详细文档请参考：[docs/analytics.md](../../docs/analytics.md)

包含：
- 完整的事件字段说明
- 错误码表
- 使用示例
- 报告格式
- 常见问题

## 性能影响

- 事件记录：<0.1ms（异步操作）
- 队列刷新：30秒一次（后台线程）
- 存储空间：~0.5MB（2000个事件）
- 对播放性能的影响：几乎无

## 许可证

MIT
