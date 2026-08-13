## 1. 收敛后端模型与回退决策

- [x] 1.1 从播放后端类型、adapter 工厂和 service 编排中删除 IJK 值、context 与字幕桥接类型
- [x] 1.2 将 AVPlayer unsupported/init failure 的唯一回退目标设为 MPV，并让 MPV 失败进入统一错误处理
- [x] 1.3 将兼容保留的 native/ffmpeg 标识映射到 MPV，验证不再生成 IJK 运行时状态
- [x] 1.4 保留并验证 AVPlayer→MPV 切换时的续播位置、单次恢复 token 与自动播放意图

## 2. 删除 IJK 依赖与独占实现

- [x] 2.1 从 `oh-package.json5` 删除 `@yaoshining/ijkplayer`，使用 OHPM 刷新锁文件并确认 IJK HAR/NAPI 条目消失
- [x] 2.2 删除 `package/ijkplayer.har`、IJK adapter 与 IJK 独占说明文件
- [x] 2.3 删除 IJK 专属 DAR/布局工具和硬解决策工具，并在无其他调用时同步删除原生解码能力查询导出
- [x] 2.4 删除 IJK 字幕 bridge，保留 AVPlayer、SMB AVPlayer 与 MPV 字幕实现

## 3. 清理播放器 UI 与设置入口

- [x] 3.1 从播放器组件删除 `ijkplayer_napi` libraryname XComponent、IJK viewport/DAR modifier、timer 与遮罩逻辑
- [x] 3.2 保留 MPV `XComponentController` surface 绑定和 AVPlayer 显示路径，并验证 surface 生命周期
- [x] 3.3 删除播放控制中的 IJK/MPV 手动切核入口和双内核失败提示
- [x] 3.4 删除回退内核设置项及 `PLAYER_FALLBACK` 偏好读写，确认旧偏好数据不会影响运行时
- [x] 3.5 清理页面参数和播放入口中的 IJK 分支，将兼容保留的 ffmpeg/native 参数解析为 MPV

## 4. 收敛 SMB 代理与通用数据边界

- [x] 4.1 删除仅供 IJK 接管使用的 keep-proxy、releaseKeepProxy 与 orphan proxy 生命周期
- [x] 4.2 保留 AVPlayer、ffprobe 和 SMB 字幕所需的 `getProxyUrl` 与普通 HTTP 代理能力
- [x] 4.3 验证 MPV 通过无 userinfo SMB URI 与 Authorization header 直连且不启动 HTTP 代理
- [x] 4.4 保留 `presetAudioTracks`、`presetSubtitleTracks` 和通用 `RenderFit` 映射，仅修正 IJK 专属注释

## 5. 更新测试、文档与规格

- [x] 5.1 删除 IJK DAR、字幕 bridge 测试及测试注册，重构通用布局测试以只覆盖保留行为
- [x] 5.2 将 controller、fallback、续播与来源解析测试改为 AVPlayer→MPV 单向链路，并补充 MPV 终态失败断言
- [x] 5.3 更新 README 和代码注释，说明 AVPlayer 主路径与 MPV 唯一回退架构
- [x] 5.4 按 OpenSpec 流程同步本 change 的 delta specs，确保主规格不再声明 IJK 能力

## 6. 验证与验收

- [x] 6.1 运行仓库已有 format 与 lint 任务；若不存在则记录缺失，不新增工具（当前仓库未定义可执行的 format/lint 任务）
- [x] 6.2 执行播放器相关单测编译/测试与当前 worktree 的 `assembleHap`，确认退出码为 0 且日志包含 `BUILD SUCCESSFUL`
- [x] 6.3 全仓搜索 `ijkplayer|Ijk|IJK|ijkplayer_napi|@yaoshining/ijkplayer`，除 OpenSpec 变更历史外无运行时代码、依赖或文档残留
- [x] 6.4 确认 `entry/libs/vidall_player.har`、项目自有 `libav*.so` 和所有非 IJK SMB 代理调用均未被误删
- [x] 6.5 检查最终 diff 仅包含本 change 范围，并记录不兼容架构下 MPV 失败进入统一错误处理的残余限制
