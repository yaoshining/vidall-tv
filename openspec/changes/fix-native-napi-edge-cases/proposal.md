# 修复 C++ NAPI 边界与竞态问题

## Why

PR #253 拆分 C++ NAPI 单体后，CodeRabbit 审查指出了原单体中既有的多处边界/竞态隐患：Promise 悬挂、空指针解引用、未初始化读取、线程累积、锁缺失、端口忽略等。这些是拆分前就存在的缺陷，本次作为独立 change 逐项修复。

## What Changes

- `napi_common`：FFmpeg 网络 init 由 `std::once_flag` 改为可重置的 mutex 保护 bool，支持 deinit 后重新 init。
- `ffmpeg_probe`：异步工作取消/失败时兜底错误消息，保证 Promise 一定被 reject。
- `subtitle_extract`：OOM 上限改用「实际写入条目数」计数（原用包数）。
- `webdav`：Promise 创建后的失败路径先 reject deferred；libcurl 禁用分支补 `(void)allowSelfSigned`。
- `smb_ops`：timeout 增加 1s 下限；libsmb2 禁用分支 reject Error 对象；非 445 端口连接复用 `BuildSmbConnectHost`。
- `vpe`：dlclose 后重置符号表；`OH_AVFormat_Create` 判空；`napi_get_cb_info` 状态检查；quality 越界统一回退 MEDIUM；surfaceId 解析校验截断/溢出。
- `player_core`：SMB 代理 handler 线程运行期回收；surface 字段用 `stateMutex` 保护；Range 请求起点越界显式返回 416。

## Capabilities

### New Capabilities

<!-- 无 -->

### Modified Capabilities

<!-- 无：边界/竞态加固，恢复预期行为，无新增能力 -->

> `.openspec.yaml` 设置 `skip_specs: true`。

## Impact

- 受影响文件：`napi_common.cpp/.h`、`ffmpeg_probe.cpp`、`subtitle_extract.cpp`、`webdav.cpp`、`smb_ops.cpp`、`vpe.cpp`、`player_core.cpp`。
- 无对外 NAPI 接口变更。
