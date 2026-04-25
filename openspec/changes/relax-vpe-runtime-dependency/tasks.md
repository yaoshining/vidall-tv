## 1. 原生加载兼容

- [x] 1.1 调整 `entry/src/main/cpp/CMakeLists.txt`，移除 `libvideo_processing.so` 对主 NAPI 的运行时硬依赖。
- [x] 1.2 更新 `vidall_core_player_napi.cpp` 的 VPE 相关初始化与导出逻辑，使无 VPE 运行库环境返回稳定的“不支持”结果而不是导致模块加载失败。
- [x] 1.3 为原生层补充日志，明确区分“VPE 可用”与“VPE 已降级禁用”的运行状态。

## 2. ArkTS 降级与界面收敛

- [ ] 2.1 调整 `VpeEnhancerUtil` 或相关能力桥接，统一以运行时探测结果驱动 VPE 启用判断。
- [ ] 2.2 更新播放器设置页与相关控制逻辑，在 VPE 不可用时隐藏或禁用 VPE 入口，并确保历史状态自动回退。
- [ ] 2.3 复核播放器主流程，确保无 VPE 时仍走标准播放链路，不影响 WebDAV、SMB、ffprobe 与基础播放能力。

## 3. 验证与回归

- [ ] 3.1 在缺少 `libvideo_processing.so` 的模拟器环境验证应用可启动、首页可进入、主 NAPI 可正常加载。
- [ ] 3.2 在支持现有播放能力的环境验证基础播放链路无回归，且 VPE 不可用时不会暴露错误功能。
- [ ] 3.3 在具备 VPE 条件的环境验证原有 VPE 功能仍可按预期启用。
