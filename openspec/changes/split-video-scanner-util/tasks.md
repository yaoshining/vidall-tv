# 任务：拆分 VideoScannerUtil.ets

## 1. 新建共享类型模块

- [x] 1.1 新建 `utils/VideoScannerTypes.ets`
- [x] 1.2 搬入 `VideoFileInfo` / `VideoScrapeContext` / `SourceScanStat` / `ScanResult`
- [x] 1.3 搬入 `ScanMode` / `ScanOptions` / `DEFAULT_SCAN_OPTIONS`
- [x] 1.4 搬入 `ISourceAdapter`

## 2. 新建共享纯函数模块

- [x] 2.1 新建 `utils/VideoScannerHelpers.ets`
- [x] 2.2 搬入 `VIDEO_EXTENSIONS` / `isVideoFile`
- [x] 2.3 搬入 `hasSeasonSiblingDirectory` / `extractLastPathSegment`
- [x] 2.4 搬入 `createVideoScrapeContext` / `classifyVideoScrapeTarget`
- [x] 2.5 搬入 `hasCompleteScrapeAssociation` / `shouldRepairIncompleteTvEpisode`
- [x] 2.6 搬入 `extractEpisodeNumberFromWeakSemanticFileName` / `clearStaleScrapeAssociationsForOverwrite`

## 3. 新建 WebDAVAdapter.ets

- [x] 3.1 新建 `utils/WebDAVAdapter.ets`，搬入 `WebDAVAdapter` 类
- [x] 3.2 重建 import 列表（WebDAVClient/Ffprobe/DB/MediaEntity/MediaTypeClassifier + 共享类型/函数）

## 4. 新建 SMBAdapter.ets

- [x] 4.1 新建 `utils/SMBAdapter.ets`，搬入 `SMBAdapter` 类
- [x] 4.2 重建 import 列表（SMBClient/Ffprobe/DB/MediaEntity/MediaTypeClassifier + 共享类型/函数）

## 5. 瘦身 VideoScannerUtil.ets

- [x] 5.1 保留 `UnsupportedAdapter` / `createAdapter` / `VideoScannerUtil` 主类
- [x] 5.2 重建 import 列表（去除非编排器依赖，补入适配器/类型 import）
- [x] 5.3 加 `export type { ScanMode } from './VideoScannerTypes'` 保持对外路径不变

## 6. 验证

- [x] 6.1 `hvigorw assembleHap`（`--no-daemon`）编译通过
- [x] 6.2 真机安装启动冒烟 + 触发一次媒体库扫描无回归
- [x] 6.3 `openspec validate split-video-scanner-util` 通过
