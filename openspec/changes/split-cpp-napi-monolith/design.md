# 设计：拆分 C++ NAPI 单体

## 目标

把 5501 行的 `vidall_core_player_napi.cpp` 拆成 9 个职责单一模块 + 共享头，保持对外 NAPI 接口与运行时行为不变。

## 现状行区间映射

| 行区间 | 职责 | 行数 |
|---|---|---|
| 1~70 | #include + 条件编译宏兜底 | 70 |
| 71~545 | SMB URL/percent、错误、JSON、curl 工具 | ~475 |
| 546~853 | ffprobe | ~308 |
| 854~1398 | 字幕提取 | ~545 |
| 1399~3130 | 播放器核心（AVPlayer 代理） | ~1732 |
| 3130~3460 | WebDAV | ~330 |
| 3461~3597 | 音频能力查询 | ~137 |
| 3598~4013 | VPE 画质增强 | ~416 |
| 4022~5408 | SMB 操作 | ~1387 |
| 5409~5501 | Init + 模块注册 + 析构 | ~93 |

## 依赖图谱（grep 逐符号确认）

- **错误抛出**（`ThrowTypeError`/`ThrowRangeError`/`ReadUtf8String`）：被**所有域**使用 → 共享。
- **JSON 工具**（`JsonEscape`/`AppendJson*Field`/`FfmpegErrorToString`）：ffprobe + 字幕 + SMB → 共享。
- **SMB URL**（`SmbUrlComponents`/`ParseSmbUrl`/`Percent*`/`SmbAVIOContext`）：player core + smb ops → 共享。
- **curl**（`RunCurlRequest`/`RunCurlDownloadToFile`/`FormatCurlError` 等）：**仅 WebDAV** → 归入 `webdav.cpp`。
- **FFmpeg 网络全局**（`EnsureAvNetworkInit`/`g_avNetworkReady`/`g_ffmpegNetworkMutex`）：ffprobe + 字幕 + 析构函数 → 共享（通过访问函数暴露）。
- **VPE 全局**（`g_vpe*`）：仅在 3598~3992 内部，**零跨域引用** → 独立叶子。
- **player core**：不引用 curl / VPE / EnsureAvNetworkInit，仅引用 SMB URL + 错误工具。

## 决策记录

### D1：共享工具抽到 `napi_common.h/.cpp`

`napi_common.h` 声明、`napi_common.cpp` 定义：`SmbUrlComponents`、`SmbAVIOContext`、`PercentDecode`、`PercentEncodePathSegment`、`PercentEncodePath`、`ParseSmbUrl`、`ThrowTypeError`、`ThrowRangeError`、`ReadUtf8String`、`JsonEscape`、`AppendJsonStringField`、`AppendJsonIntField`、`FfmpegErrorToString`，以及 FFmpeg 网络访问函数（`VidAllEnsureAvNetworkInit` / `VidAllAvNetworkReady` / `VidAllDeinitAvNetwork`）。

条件编译宏兜底（`VIDALL_HAS_LIBCURL` / `VIDALL_HAS_LIBSMB2` / `VIDALL_HAS_VPE` 等 `#if !defined`）上移到 `napi_common.h`，所有 `.cpp` 先 include 它。

### D2：各域 `.cpp` 保持独立匿名命名空间，仅暴露 NAPI 入口

每个域文件保留自己的 `namespace { ... }`（内部实现仍 `static`），仅把 `Init` 需要的 NAPI 入口函数改为模块级外部链接并在头文件声明，例如 `napi_value Ffprobe(napi_env, napi_callback_info);`。

### D3：curl 工具并入 `webdav.cpp`

curl 仅 WebDAV 使用，`CurlRequestResult`/`CurlDownloadResult`/`RunCurlRequest`/`RunCurlDownloadToFile`/`SplitHeaderLines`/`FormatCurlError` 等随 `webdav.cpp` 一起搬迁，`#if VIDALL_HAS_LIBCURL` 守卫保持。

### D4：`Init` 留在主文件，引用各域 NAPI 入口

`vidall_core_player_napi.cpp` 瘦身为：include 各域头 + `Init`（descriptors 数组引用各域入口）+ `OnNapiModuleUnload` 析构 + `napi_module` + `RegisterVidallCorePlayerModule`。`OnNapiModuleUnload` 改用 `VidAllDeinitAvNetwork()`。

### D5：CMakeLists.txt 源文件列表扩展

`add_library(vidall_core_player_napi SHARED ...)` 的源文件从单个扩展为 9 个 `.cpp`（`napi_common.cpp`、`ffmpeg_probe.cpp`、`subtitle_extract.cpp`、`webdav.cpp`、`audio_capability.cpp`、`vpe.cpp`、`smb_ops.cpp`、`player_core.cpp`、`vidall_core_player_napi.cpp`）。include 目录与链接库不变。

### D6：验证策略

- 编译 + 链接验证：`hvigorw assembleHap`（`--no-daemon`），C++ 通过 CMake 编译进 HAP。
- 行为验证：真机安装启动冒烟；NAPI 各入口（ffprobe / 字幕 / WebDAV / SMB / 播放 / VPE）由用户侧功能冒烟确认。
- 不新增单测（纯重构）。

## 迁移计划（增量，逐步构建）

1. 抽 `napi_common.h/.cpp`（共享工具 + 宏兜底）→ 主文件 include 它 → 构建。
2. 抽 `ffmpeg_probe`、`subtitle_extract`、`webdav`（含 curl）、`audio_capability`、`vpe`、`smb_ops`（叶子域）→ 构建。
3. 抽 `player_core`（最复杂）→ 构建。
4. 主文件瘦身为 Init + 注册 + 析构。
5. 更新 `CMakeLists.txt`。
6. 全量构建 + 真机冒烟。

## 风险与回滚

- 风险较高（C++ 链接可见性 + 条件编译 + 头文件依赖），但机械性搬迁 + 构建兜底可捕获绝大多数问题。
- 最大风险：`static` → 外部链接时漏改/漏声明导致 link error；`#include` 分布遗漏导致 compile error。
- 回滚：revert 单次 commit。
