# Metrics Instrumentation

## 实现的组件

### 核心接口和实现
- `MetricsReporter.ets` - 指标报告接口
- `LocalFileReporter.ets` - 本地文件实现（JSON存储）
- `MetricsService.ets` - 全局单例服务

### 应用生命周期集成
- `EntryAbility.ets` - 在 onCreate 初始化，在 onBackground/onDestroy 调用 flush

## 待埋点的组件

### 播放器埋点（任务 4）
需要在以下位置添加埋点：

**文件:** `entry/src/main/ets/components/core/player/VideoPlayer.ets` 或 `VideoPlayerController.ets`

**埋点位置:**
1. 播放成功（首帧渲染）:
   ```typescript
   // 在播放器首帧回调中
   const firstFrameTime = Date.now() - this.playStartTime;
   if (MetricsService.isInitialized()) {
     MetricsService.getInstance().recordPlaybackAttempt(true, firstFrameTime);
   }
   ```

2. 播放失败:
   ```typescript
   // 在播放器错误处理中
   if (MetricsService.isInitialized()) {
     MetricsService.getInstance().recordPlaybackAttempt(false, 0);
   }
   ```

**首帧时间测量:**
- 在用户点击播放时记录 `this.playStartTime = Date.now()`
- 在 AVPlayer `onVideoSizeChanged` 或首次 `onTimeUpdate > 0` 回调中计算差值

### 字幕埋点（任务 5）

**文件:** `entry/src/main/ets/subtitle/SubtitleLanguagePreference.ets` 或字幕选择组件

**埋点位置:**
```typescript
// 用户选择字幕语言时
if (MetricsService.isInitialized()) {
  MetricsService.getInstance().recordSubtitleUsage(selectedLanguage); // 'zh', 'en', etc.
}

// 播放开始时无字幕
if (MetricsService.isInitialized()) {
  MetricsService.getInstance().recordSubtitleUsage(null);
}
```

### 扫描器埋点（任务 6）

**文件:** `entry/src/main/ets/utils/VideoScannerUtil.ets` 或扫描服务

**埋点位置:**
```typescript
// 扫描完成时
const itemsWithMetadata = scannedItems.filter(item => item.hasMetadata).length;
const totalScanned = scannedItems.length;

if (MetricsService.isInitialized()) {
  MetricsService.getInstance().recordScanCoverage(itemsWithMetadata, totalScanned);
}
```

## 测试

测试文件已创建于 `entry/src/test/ets/services/metrics/`：
- `MetricsReporter.test.ets` - 接口契约测试
- `LocalFileReporter.test.ets` - 本地存储实现测试

## 性能要求

- 记录操作必须 < 1ms（已实现：内存操作）
- 持久化异步非阻塞（已实现：flush() 使用 Promise）
- 线程安全（已实现：Promise 锁机制）

## 数据格式

**JSON Schema (YYYY-MM-DD.json):**
```json
{
  "schema_version": 1,
  "date": "2024-05-01",
  "playback": {
    "attempts": 120,
    "success": 118,
    "failures": 2,
    "firstFrameTimeMs": { "p50": 420, "p90": 850, "p99": 1200 }
  },
  "subtitles": {
    "total_playbacks": 118,
    "with_subtitles": 85,
    "languages": { "zh": 60, "en": 25 }
  },
  "scanning": {
    "scans_triggered": 5,
    "items_scanned": 450,
    "items_available": 500,
    "coverage_pct": 90.0
  }
}
```

## 保留策略

- 自动删除 30 天前的指标文件
- 在 LocalFileReporter 初始化时执行清理
