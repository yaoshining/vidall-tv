# audio-decoder-capability-service Specification

## Purpose
Centralize device audio decoding capability queries — codec support, hardware flag, and max channel count — with caching, deduplication, and device/firmware corrections, as the single source of truth for audio routing decisions.

## Requirements

### Requirement: Audio decoding capability SHALL be queried via device capability
系统 SHALL 通过工程现有 NAPI `queryAudioDecoderCapability()`（底层基于 `OH_AVCodec_GetCapability()` / `OH_AVCodec_GetCapabilityByCategory()`）查询设备对归一化 codec 的解码支持与最大声道数，作为音频路由决策的能力真值来源。

#### Scenario: Query decoder support and max channels
- **WHEN** 路由决策需要判定某归一化 codec 是否可用
- **THEN** 系统 SHALL 查询该 codec 的解码器是否存在、是否硬件解码、以及最大声道数
- **AND** 结果 SHALL 包含 `supported`、`isHardware`、`maxChannels` 与能力是否已知的标记

#### Scenario: 解码器不存在视为明确不支持
- **WHEN** 查询返回解码器不存在
- **THEN** 系统 SHALL 将能力标记为"已知不支持"（`capabilityKnown=true, supported=false`）
- **AND** 该 codec 的音轨 SHALL 判为不兼容

### Requirement: Audio decoding capability SHALL be cached and deduplicated
系统 MUST 缓存能力查询结果；缓存键至少包含设备型号、系统版本、归一化 codec 与声道数，系统版本变化后旧缓存自然失效。同一媒体内多条相同编码的音轨 SHALL 去重后查询，不重复发起能力查询。

#### Scenario: 缓存命中复用查询结果
- **WHEN** 相同设备型号、系统版本、codec 与声道数的能力查询已缓存
- **THEN** 系统 SHALL 直接复用缓存结果，不重复调用 NAPI

#### Scenario: 系统升级后旧缓存失效
- **WHEN** 设备系统版本变化
- **THEN** 缓存键 SHALL 因系统版本变化而不命中旧条目
- **AND** 系统 SHALL 重新查询当前系统版本下的解码能力

#### Scenario: 多条相同 codec 去重查询
- **WHEN** 媒体存在三条音轨但只有两种唯一归一化 codec
- **THEN** 系统 SHALL 最多发起两次设备能力查询

### Requirement: Device/firmware correction SHALL override declared capability
系统 MUST 支持设备/固件纠偏结果，纠偏结果 SHALL 优先于系统声明能力；当 AVPlayer 明确播放失败时，系统 SHALL 动态降级并记录可复用的纠偏结果。

#### Scenario: 纠偏结果优先于系统声明
- **WHEN** 存在针对当前设备型号、系统版本与 codec 的纠偏结果（标记为不支持）
- **THEN** 系统 SHALL 以纠偏结果为准判该 codec 不兼容
- **AND** 即使系统声明支持该 codec，也不判为兼容

#### Scenario: AVPlayer 明确失败时记录纠偏
- **WHEN** AVPlayer 对某 codec 报告格式不支持（如错误码 5400106 / 5400103）或触发 unsupported format fallback
- **THEN** 系统 SHALL 记录该 codec 的设备/固件纠偏结果
- **AND** 后续会话 SHALL 复用该纠偏结果

#### Scenario: 纠偏结果可跨会话复用
- **WHEN** 已记录的纠偏结果被持久化
- **AND** 设备型号与系统版本未变化
- **THEN** 后续播放会话 SHALL 读取并应用该纠偏结果
