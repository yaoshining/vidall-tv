# 任务：拆分 C++ NAPI 单体

## 1. 共享工具模块

- [x] 1.1 新建 `napi_common.h`（声明 + 结构体 + 条件编译宏兜底）
- [x] 1.2 新建 `napi_common.cpp`（SMB URL/percent、错误、JSON、FFmpeg 网络全局）
- [x] 1.3 主文件 include `napi_common.h` 并删除已搬迁代码

## 2. 叶子域拆分

- [x] 2.1 `ffmpeg_probe.h/.cpp`（Ffprobe）
- [x] 2.2 `subtitle_extract.h/.cpp`（ExtractSubtitleEntries）
- [x] 2.3 `webdav.h/.cpp`（WebdavRequest/DownloadToFile + curl 工具）
- [x] 2.4 `audio_capability.h/.cpp`（QueryAudioDecoderCapability/GetNativeCapabilities）
- [x] 2.5 `vpe.h/.cpp`（VPE 4 个入口 + 桩）
- [x] 2.6 `smb_ops.h/.cpp`（SmbTestConnection/List/Shares/Discover/Read/Download）

## 3. 播放器核心拆分

- [x] 3.1 `player_core.h/.cpp`（CreatePlayer~FfmpegSelfCheck 全部入口）
- [x] 3.2 各 NAPI 入口改为外部链接并在头文件声明

## 4. 主文件瘦身 + 构建

- [x] 4.1 `vidall_core_player_napi.cpp` 瘦身为 Init + 注册 + 析构
- [x] 4.2 `CMakeLists.txt` 源文件列表扩展为 9 个 `.cpp`
- [x] 4.3 `hvigorw assembleHap` 编译 + 链接通过
- [x] 4.4 真机安装启动冒烟
- [x] 4.5 `openspec validate split-cpp-napi-monolith` 通过
