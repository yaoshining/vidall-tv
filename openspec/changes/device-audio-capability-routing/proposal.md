## Why

当前 `AVPlayerAdapter.ets` 在 `PREPARED` 阶段通过全局写死的 `UNSUPPORTED_AUDIO_CODECS` 黑名单判断音频兼容性：当全部音轨命中 AC-3、E-AC-3、TrueHD、DTS 等条目时，应用才从 AVPlayer 降级到 MPV。该策略能规避部分设备"AVPlayer 已 prepared 但音频静默无声"的问题，但不同设备与固件实际支持的格式不同：全局写死黑名单会把具备对应解码能力的设备也强制降级，而逐音轨创建播放器试播则会增加初始化时间。

本变更改为使用当前设备的真实音频解码能力（工程现有 NAPI `queryAudioDecoderCapability()`，底层基于 `OH_AVCodec_GetCapability()` / `OH_AVCodec_GetCapabilityByCategory()`）进行路由：在不逐音轨试播的前提下，于启动前选择 AVPlayer 或 MPV，并保留对固件错误报告能力或静默无声问题的纠偏机制。

## What Changes

- 新增 `AudioDecoderCapabilityService`：封装 NAPI 解码能力查询、按设备型号/系统版本/codec/声道数缓存、以及设备/固件纠偏结果的读取与记录。
- 音频路由决策改为按归一化 codec 去重后查询设备能力，逐音轨判定"codec 支持 + 声道数不超设备上限"的兼容性；存在兼容音轨时选 AVPlayer 并预选兼容性最高且符合语言偏好的音轨，无兼容音轨时在创建/prepare AVPlayer 前直接选 MPV。
- 能力查询异常时保守选 MPV，迁移期仅允许把全局 codec 黑名单作为查询异常时的临时兜底，不再作为最终兼容性真值。
- AVPlayer 明确播放失败（unsupported format / 5400106 / 5400103）时动态降级，并把"系统宣称支持但实际失败"记录为可复用的设备/固件纠偏结果，后续会话优先于系统声明能力。
- 移除 `AVPlayerAdapter` PREPARED 阶段基于全局黑名单的"全音轨不支持即 fallback"判定，改为后端创建前已确定的决策驱动。

## Capabilities

### New Capabilities

- `audio-decoder-capability-service`: 设备音频解码能力的查询、去重、缓存与纠偏，作为音频路由决策的唯一能力真值来源。

### Modified Capabilities

- `audio-track-routing-service`: 路由决策与初始选轨由静态 codec 排名改为基于设备真实解码能力（含声道上限）判定，并新增预选最佳兼容音轨的输出。
- `avplayer-codec-detection-fallback`: 将"PREPARED 阶段按全局黑名单判定 fallback"改为"启动前按设备能力判定后端；AVPlayer 显式失败时动态降级并记录纠偏"。
- `playback-backend-service`: `chooseBackend` 的决策可返回 `mpv` 作为主选后端（无兼容音轨时），而非仅作为 AVPlayer 的 fallback。

## Impact

- 影响 `AudioTrackRoutingService`、`VideoPlayerController`、`AVPlayerAdapter` 以及 native `audio_capability.cpp`。
- 新增 `services/audioCapability/` 与 `services/audioRouting/AudioCodecUtil.ets`。
- 复用现有 NAPI `queryAudioDecoderCapability`（仅补 MIME 映射与能力已知语义）、`AppPreferences`（纠偏持久化）与 `@ohos.deviceInfo`（缓存键）。
- 不新增第三方依赖，不改变 MPV / FFmpeg 解码链。
