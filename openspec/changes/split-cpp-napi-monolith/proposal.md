# 拆分 C++ NAPI 单体 vidall_core_player_napi.cpp

## Why

`entry/src/main/cpp/vidall_core_player_napi.cpp`（5501 行）是全仓库最大文件，把 ~30 个 NAPI 入口及 11 个职责域塞进单一匿名命名空间：SMB URL 解析、错误/JSON 工具、curl、ffprobe、字幕提取、播放器核心、WebDAV、音频能力查询、VPE 画质增强、SMB 操作、模块注册。任何一处修改都会触发整文件重编译，且职责边界无法一眼看清。应拆分为单一职责的源文件 + 共享头，提升可维护性与增量编译效率。

## What Changes

按职责拆分为 **9 个模块 + 共享头**（纯代码搬迁 + 链接可见性调整，零行为变更）：

| 文件 | 内容 |
|---|---|
| `napi_common.h/.cpp` | 共享工具：SMB URL 解析、percent 编解码、错误抛出、JSON 构建、FFmpeg 网络全局 |
| `ffmpeg_probe.h/.cpp` | ffprobe 探测 |
| `subtitle_extract.h/.cpp` | 字幕提取 |
| `webdav.h/.cpp` | WebDAV + curl 工具（curl 仅 WebDAV 使用） |
| `audio_capability.h/.cpp` | 音频解码能力查询 |
| `vpe.h/.cpp` | VPE 画质增强（零跨域引用的独立叶子） |
| `smb_ops.h/.cpp` | SMB 操作（list/read/download/discover/test） |
| `player_core.h/.cpp` | 播放器核心（AVPlayer 代理，~1700 行） |
| `vidall_core_player_napi.cpp` | 瘦身为 `Init` + 模块注册 + 析构 |

- 各 NAPI 入口函数由 `static`（匿名命名空间）改为模块级外部链接，在各自头文件中声明，供 `Init` 引用。
- `CMakeLists.txt` 的 `add_library` 源文件列表从 1 个扩展为 9 个 `.cpp`。
- 条件编译宏 `VIDALL_HAS_*` 的兜底定义上移到 `napi_common.h`，各域共享。

## Capabilities

### New Capabilities

<!-- 无：纯重构 -->

### Modified Capabilities

<!-- 无：无 spec 级行为变更 -->

> `.openspec.yaml` 设置 `skip_specs: true`，不产生 spec delta。

## Impact

- 受影响文件：`entry/src/main/cpp/` 下 9 组新 `.h/.cpp` + 瘦身后的 `vidall_core_player_napi.cpp` + `CMakeLists.txt`。
- 对外 NAPI 接口（模块名、导出函数名、签名）完全不变。
- 无 API / 依赖 / 资源变更。
- 无 breaking change。
