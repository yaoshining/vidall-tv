## 1. 类型契约与配置

- [x] 1.1 在 `SubtitleAcquisitionTypes.ets` 统一定义 `SubtitleSearchResult`（新增 `source`、`subtitleRef?`、`fileId?`），停止直接 re-export `OpenSubtitlesClient.SubtitleSearchResult`
- [x] 1.2 扩展 `SubtitleDownloadInput`（新增 `source` 与 `subtitleRef?`，供下载分支判定）
- [x] 1.3 扩展 `SubtitleAcquisitionErrorKind`，新增 `subhub_auth_invalid` / `subhub_quota_exhausted` / `subhub_unavailable` / `subhub_not_found`
- [x] 1.4 扩展 `classifyAcquisitionError`，映射 `SubHubApiError` / `SubHubNetworkError` 到 4 个新 kind
- [x] 1.5 `AppEnv` 新增 `SUBHUB_API_KEY` 常量；`SubHubClient` 构造默认 Caller Key 改为 `AppEnv.SUBHUB_API_KEY`

## 2. Provider 抽象与解析

- [x] 2.1 新建 `providers/SubtitleProvider.ets`：定义 `SubtitleProvider` 接口与下载上下文类型
- [x] 2.2 新建 `providers/OpenSubtitlesSubtitleProvider.ets`：包装 `OpenSubtitlesClient` + `SubtitleDownloader`，映射为 `source=opensubtitles` 统一结果
- [x] 2.3 新建 `providers/SubHubSubtitleProvider.ets`：包装 `SubHubClient`，search 字段映射为 `source=subhub`；download 走 `SubHubClient.download` + 落盘
- [x] 2.4 抽取共享写盘 helper（mkdir + 写 ArrayBuffer + close），供 OS 与 SubHub 两路复用
- [x] 2.5 新建 `providers/SubtitleProviderResolver.ets`：按 `OPENSUBTITLES_API_KEY` 是否为空返回 `[OpenSubtitles, SubHub]` 或 `[SubHub]`
- [x] 2.6 新建 `providers/SubtitleDeduplicator.ets`：内容指纹去重，碰撞时保留 OpenSubtitles 结果

## 3. Service 聚合与下载分支

- [x] 3.1 `SubtitleAcquisitionService.search` 改为并发聚合：`Promise.all` + 单 provider 独立降级，OS 在前、SubHub 在后，去重后返回，全部失败才抛错
- [x] 3.2 `SubtitleAcquisitionService.download` 按 `source` 分支：`opensubtitles` 走 `SubtitleDownloader`，`subhub` 走 `SubHubSubtitleProvider`，两者都写缓存（`source` 分别标记）

## 4. UI 与设置

- [x] 4.1 `SubtitleSelectorDrawerDialog` 结果行新增来源 chip（`直连` / `SubHub`，不同颜色）
- [x] 4.2 下载进行态由 `downloadingFileId: number` 改为按 `subtitleId: string` 跟踪
- [x] 4.3 `toastMessageForAcquisitionError` 新增 4 个 subhub kind 的 Toast 文案
- [x] 4.4 `OpenSubtitlesConfigBuilder` 默认状态文案由「官方代理 · 推荐」改为「SubHub · 推荐」

## 5. 测试

- [x] 5.1 `SubtitleProviderResolver` 单测：有/无 Key 两种返回
- [x] 5.2 `SubtitleDeduplicator` 单测：去重、OS 优先、normalize 规则
- [x] 5.3 `SubHubSubtitleProvider` 单测：字段映射与下载（注入 mock `SubHubClient`）
- [x] 5.4 `classifyAcquisitionError` 单测：SubHub 各错误码到 kind 的映射
- [x] 5.5 `SubtitleAcquisitionService` 单测：聚合顺序与「单 provider 失败不阻塞」

## 6. 验证

- [x] 6.1 `openspec validate enable-subhub-subtitle-aggregation` 通过
- [x] 6.2 `hvigorw assembleHap` 编译通过
- [x] 6.3 装电视验证：无 Key 仅 SubHub；有 Key 时 OS 直连优先 + SubHub 拼接 + 来源 chip 正确
