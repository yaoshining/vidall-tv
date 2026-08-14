# 任务：修复 C++ NAPI 边界与竞态问题

## 1. napi_common

- [x] 1.1 FFmpeg 网络 init 改为可重置的 mutex 保护 bool

## 2. ffmpeg_probe

- [x] 2.1 异步取消/失败时兜底错误消息并 reject

## 3. subtitle_extract

- [x] 3.1 OOM 上限改用实际写入条目计数

## 4. webdav

- [x] 4.1 Promise 创建后失败路径先 reject deferred
- [x] 4.2 libcurl 禁用分支补 (void)allowSelfSigned

## 5. smb_ops

- [x] 5.1 timeout 增加 1s 下限
- [x] 5.2 libsmb2 禁用分支 reject Error 对象
- [x] 5.3 非 445 端口连接复用 BuildSmbConnectHost

## 6. vpe

- [x] 6.1 dlclose 后重置符号表
- [x] 6.2 OH_AVFormat_Create 判空（2 处）
- [x] 6.3 napi_get_cb_info 状态检查（2 处）
- [x] 6.4 quality 越界统一回退 MEDIUM
- [x] 6.5 surfaceId 解析校验截断/溢出

## 7. player_core

- [x] 7.1 SMB 代理 handler 线程运行期回收
- [x] 7.2 surface 字段用 stateMutex 保护
- [x] 7.3 Range 起点越界显式返回 416

## 8. 验证

- [x] 8.1 assembleHap 构建通过
- [x] 8.2 真机安装启动冒烟通过
- [x] 8.3 openspec validate

## 9. 复核新增修复

- [x] 9.1 vpe.cpp 未初始化 napi_value 全部初始化 + 返回值检查（含桩函数）
- [x] 9.2 player_core.cpp napi_create_threadsafe_function 返回值检查（6 处）
