# Umami Analytics 集成设计

## 背景

Issue #201 已从 AGC Analytics 调整为接入自建 Umami 实例。仓库当前已具备本地指标基础设施：

- `MetricsReporter`：统一埋点接口
- `LocalFileReporter`：按天写入本地 JSON
- `MetricsService`：全局单例入口

本次范围仅包含 **App 侧集成**，不包含 EdgeOne Pages / Umami 服务端部署。

## 目标

在不改动现有业务埋点调用方式的前提下，为播放器与扫描相关指标增加 Umami 云端上报能力，并保留本地 JSON 作为兜底备份。

## 已确认约束

- Umami 实例地址：`https://analytics.yaoshining.space`
- Website ID：`a212474c-ad81-4e9e-80a0-39d735941f44`
- App 事件映射：
  - `hostname = vidall-tv`
  - `url = app://vidall-tv/<feature>/<event>`
- 默认策略：**双写**
  - 本地：`LocalFileReporter`
  - 云端：`UmamiReporter`
- 设备 UUID：使用 `AppPreferences` 持久化，并以 Umami `identify` 维度上报
- HarmonyOS 侧上报方式：`@ohos.net.http`
- 不采用 `hiAppEvent` 作为本次 Umami 上报方案

## 本地验证结论

已确认 `https://analytics.yaoshining.space` 可访问，且实例接受当前版本 Umami `/api/send` 协议：

```json
{
  "type": "event",
  "payload": {
    "website": "a212474c-ad81-4e9e-80a0-39d735941f44",
    "name": "copilot_probe",
    "data": {
      "source": "local_validation",
      "kind": "connectivity_test"
    },
    "url": "app://vidall-tv/local-test",
    "hostname": "vidall-tv"
  }
}
```

测试返回 `200`，响应体为 `{"beep":"boop"}`。

## 架构设计

### 1. UmamiReporter

新增：

- `entry/src/main/ets/services/analytics/UmamiReporter.ets`

职责：

- 将 `MetricsReporter` 标准接口调用转换成 Umami `/api/send` 请求
- 管理 Umami 配置（base URL / website ID / hostname）
- 管理设备 UUID 的 `identify` 上报
- 维护轻量内存发送队列
- 在 `flush()` 时尝试发送队列中的待发事件

边界：

- 不负责本地 JSON 落盘
- 不直接暴露给业务调用方

### 2. CompositeMetricsReporter

新增一个组合型 reporter，实现 `MetricsReporter`：

- 每次调用同时转发给：
  - `LocalFileReporter`
  - `UmamiReporter`

这样 `MetricsService` 仍只依赖单一 `MetricsReporter`，调用侧完全不需要改。

### 3. MetricsService

保留现有单例入口与对外 API，不改变业务埋点代码。

`initialize(context)` 默认构造：

- `LocalFileReporter`
- `UmamiReporter`
- `CompositeMetricsReporter`

### 4. AppPreferences 扩展

新增设备 UUID 对应 key，用于：

- 首次启动生成并持久化 UUID
- 后续上报复用已有值
- 避免日志打印原始 UUID

## 事件模型

### Identify

用于设备维度关联：

```json
{
  "type": "identify",
  "payload": {
    "website": "<website-id>",
    "hostname": "vidall-tv",
    "url": "app://vidall-tv/system/identify",
    "name": "device_uuid",
    "value": "<persisted-uuid>"
  }
}
```

规则：

- 每次进程生命周期内，`UmamiReporter` 仅在首次成功发送前尝试一次
- 若失败，不阻断 event 上报；在后续发送机会继续尝试

### playback_attempt

来源：`recordPlaybackAttempt(success, firstFrameMs, media, sourceType)`

```json
{
  "type": "event",
  "payload": {
    "website": "<website-id>",
    "hostname": "vidall-tv",
    "url": "app://vidall-tv/player/playback_attempt",
    "name": "playback_attempt",
    "data": {
      "success": true,
      "first_frame_ms": 450,
      "source_type": "network",
      "local_id": 123,
      "provider": "tmdb",
      "provider_id": "550",
      "title": "Fight Club",
      "year": null,
      "file_name": "Fight Club.mkv"
    }
  }
}
```

### subtitle_usage

来源：`recordSubtitleUsage(language)`

```json
{
  "type": "event",
  "payload": {
    "website": "<website-id>",
    "hostname": "vidall-tv",
    "url": "app://vidall-tv/player/subtitle_usage",
    "name": "subtitle_usage",
    "data": {
      "language": "zh",
      "has_subtitle": true
    }
  }
}
```

### scan_coverage

来源：`recordScanCoverage(scanned, total)`

```json
{
  "type": "event",
  "payload": {
    "website": "<website-id>",
    "hostname": "vidall-tv",
    "url": "app://vidall-tv/scanner/scan_coverage",
    "name": "scan_coverage",
    "data": {
      "scanned": 450,
      "total": 500,
      "coverage_pct": 90
    }
  }
}
```

## 数据流

1. 业务代码继续调用 `MetricsService`
2. `MetricsService` 转发到 `CompositeMetricsReporter`
3. `CompositeMetricsReporter` 同时调用：
   - `LocalFileReporter`
   - `UmamiReporter`
4. `LocalFileReporter` 继续本地聚合并按生命周期 flush
5. `UmamiReporter` 将事件转为 Umami payload，写入内存队列并触发异步发送
6. `flush()` 时，`UmamiReporter` 尝试清空当前队列

## 失败处理与重试

本次设计采用轻量策略，不引入复杂离线同步系统。

### 发送失败

- 不抛出异常给调用方
- 不打印设备 UUID、完整媒体标识等敏感值
- 仅记录事件类型、HTTP 状态码、错误类别等摘要
- 失败事件保留在内存队列中

### 重试时机

- 新事件入队且当前无发送任务时，触发一次发送
- `flush()` 时尝试继续发送剩余队列
- 单次发送过程中，每条事件最多尝试一次；失败则留待下次

### 为什么不额外做磁盘级上传队列

因为当前已经有 `LocalFileReporter` 负责本地指标备份，本次卡片的目标是尽快形成 Umami 云端闭环，而不是扩展成通用离线同步框架。若后续确实需要“断网恢复后批量补传”，可在后续 issue 中把 `UmamiReporter` 升级为持久化发送队列。

## 配置方案

先采用集中配置对象/常量方式，避免本次引入环境配置系统：

- `baseUrl = https://analytics.yaoshining.space`
- `websiteId = a212474c-ad81-4e9e-80a0-39d735941f44`
- `hostname = vidall-tv`

后续若需要开发/测试/正式环境区分，再额外抽象配置来源。

## 测试策略

### 单测覆盖

1. `UmamiReporter`
   - 生成 `event` / `identify` payload 正确
   - `playback_attempt` / `subtitle_usage` / `scan_coverage` 字段映射正确
   - 首次无 UUID 时生成并持久化
   - 已有 UUID 时复用
   - 网络失败时事件留在待发队列
   - `flush()` 会尝试发送待发事件

2. `CompositeMetricsReporter`
   - 调用会同时转发到 local + umami 两侧

3. `MetricsService.initialize()`
   - 默认使用双写组合 reporter

### 验证范围

- 本地编译验证
- 本地单测验证
- 手动向 Umami 实例发送事件并在控制台确认可见

## 不在本次范围

- EdgeOne Pages / Umami 服务端部署与运维
- 通用离线持久化上传队列
- 后台任务调度系统
- 复杂指数退避/限流策略
- metrics 配置界面

## 风险与注意事项

- Umami 当前实例使用的 `/api/send` 协议是 `type + payload` 结构，不能按旧版批量 `events[]` 方式实现
- HarmonyOS 端网络失败较常见，`UmamiReporter` 必须保证调用方无感知失败
- 不得在日志中输出设备 UUID 或可直接识别个人/设备的信息
- 事件模型一旦进入 Umami 控制台，后续改名会影响报表连续性，因此事件名与 URL namespace 应尽量一次定稳

## 推荐实施顺序

1. 扩展 `AppPreferences` 设备 UUID key
2. 实现 `UmamiReporter`
3. 实现 `CompositeMetricsReporter`
4. 调整 `MetricsService.initialize()` 默认双写
5. 补单测
6. 手动验证 Umami 控制台可见事件
