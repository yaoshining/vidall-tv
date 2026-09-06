## Why

#314 的搜索优化已分阶段实施，但缺少统一 OpenSpec 记录。搜索必须跟随媒体库顶部当前来源，避免本地库与影视服务器混搜，并为六个子项提供可追踪的行为与验收契约。

## What Changes

- #315 统一来源身份、能力与旧路由兼容；WebDAV/SMB 聚合为本地配置文件源，每个影视服务器配置独立。
- #316 接入 Jellyfin/Emby/Plex 单实例搜索、状态和正确的服务器详情路由。
- #317 按来源适配拼音或真实文本输入，共享结果框架。
- #318 统一请求失效、错误重试、TV 焦点和性能验收。
- #319 改善仅本地库的拼音召回、规范化和相关度。
- #320 隔离来源历史与建议词，不引入外部热搜或 AI。
- 本次只补流程产物；已有跨分支实现不等于当前分支代码已集成。禁止归档，等待用户另行通知。

## Capabilities

### New Capabilities
- `source-scoped-search`: 来源身份、服务器检索与详情、输入和异步状态、焦点、来源历史及建议词。

### Modified Capabilities
- `media-search`: 明确拼音与排序仅用于本地文件源，补充规范化、多音词和短首字母质量约束。

## Impact

涉及 SearchScope、SourceSwitchModel、VideoServerModel、SearchWorkspacePage、MediaResultPage、VideoServerSearchService、SearchWorkspaceSession、协议客户端、MediaQueryDao、SearchHistoryDao 和 PinyinUtil，以及对应测试。历史来源隔离可能需要数据库迁移，迁移策略在 #320 实施前确定。无新增运行时依赖要求，不实现网盘、跨源混搜、服务器拼音索引或服务器在线补全。
