# #316 服务器搜索支持矩阵与验证限制

## 范围与基线

本文记录实现基线 `1f586f93e5436889a8d04d698c2fe66988a72af4` 的能力及证据边界，不代表 #316 已完成全部验收。身份隔离实现已通过独立 QA 与增量复审；本次仅补文档，不改业务、不重新构建。

搜索针对当前选中的一个具体服务器实例，不聚合多个服务器，不搜索本地媒体库，不在来源失效时回退本地。既有 `.plans/reference/` 文档涉及其他主题，因此本文件作为该矩阵的单一入口。

## 三协议支持矩阵

“已接入”仅表示源码与自动化覆盖，不表示已完成真实服务器或 TV 验收。

| 能力 | Jellyfin | Emby | Plex |
| --- | --- | --- | --- |
| 搜索适配 | `JellyfinClient.searchItems` | 复用 `JellyfinClient.searchItems` | `PlexClient.searchItems` |
| 请求路径 | `/Users/{userId}/Items` | `/Users/{userId}/Items` | `/hubs/search` |
| 关键词参数 | `SearchTerm`，URL 编码 | `SearchTerm`，URL 编码 | `query`，URL 编码 |
| 请求范围 | `Recursive=true`，`IncludeItemTypes=Movie,Series,Episode`，`Limit=100` | 同 Jellyfin，仍需验证实际版本兼容 | `limit=100`，`includeExternalMedia=0`；仅接收 movie/show/episode hub |
| 电影 | Movie 归一为 `movie` | Movie 归一为 `movie` | movie 归一为 `movie` |
| 剧集整体 | Series 归一为 `series` | Series 归一为 `series` | show 归一为 `series` |
| 单集 | Episode 归一为 `episode` | Episode 归一为 `episode` | episode 归一为 `episode` |
| 季独立搜索 | 未请求 Season，归一层不接收 season | 同 Jellyfin | season hub 不接收，归一层不接收 season |
| 剧集详情中的季/集 | 既有详情链调用季列表、下一集及季详情入口 | 同 Jellyfin | 使用 Plex 季列表、下一集及既有详情入口 |
| 真实 HTTP 搜索→详情→返回→再搜 | 尚未验证 | 尚未验证 | 尚未验证 |
| TV 遥控器与系统键盘闭环 | 尚未验证 | 尚未验证 | 尚未验证 |

电影与剧集整体使用各自媒体 ID 打开服务器详情。单集结果保留原始 `mediaId`；若存在 `seriesId`，详情目标 `detailItemId` 使用该剧集 ID，否则使用单集自身 ID。进入剧集详情不承诺自动定位或播放搜索命中的那一集：既有主播放目标为 `nextUp`，需按季/集入口选择目标。缺少父级元数据时的实际展示需用真实样本验收。

剧集详情获取季列表/下一集失败时，当前实现保留已获取的基本详情，相关内容可能为空；这不是“详情完全加载成功”的保证，也没有独立的季列表重试承诺。

## 结果、输入与容量限制

- 搜索服务只保留 `movie`、`series`、`episode`，使用来源 scope 与编码后的媒体 ID 生成 key 并去重，不把季、人物、音乐等扩展为搜索结果类型。
- 最终归一结果最多 100 项，界面明确显示“首批结果（最多 100 项，可能更少）”。Plex 请求限制不等于聚合 hub 后的统一总数；归一层仍截断至 100。
- DTO 没有 `total`、`hasMore` 或分页游标，没有加载下一页能力。少于 100 项可能来自服务端返回、类型过滤或去重；恰好 100 项也不能证明仍有下一页。不得显示为完整命中总数。
- 使用真实 `TextInput` 文本，输入变更防抖 800ms，提交可直接搜索；空白关键词不发搜索请求。服务器输入不依赖本地拼音索引，不承诺拼音、首字母、分词、模糊搜索或跨语言匹配，匹配能力以服务器为准。
- 服务器搜索不读写本地搜索历史。系统键盘的实际弹出、中文输入和遥控器焦点行为仍需设备验证，组件接线或 host 测试不替代该证据。

## 身份路由与异步隔离

路由携带 `serverId`、`serverType`、`mediaId`、`mediaType`、详情目标 `itemId` 和标题，进入既有 `ServerMediaDetailPage`，不跳转本地电影/剧集详情。点击结果前校验来源快照，来源或同 ID 配置变化时拒绝旧结果并提示重新选择或搜索。

搜索快照对外只有 scope/实例 ID/类型；原始配置比较保存在模块私有状态。详情首次 await 前固定配置修订校验依据；正常冷缓存初始化自动且恰好请求一次详情，不能将真实修改当作初始化认领。模型在 update/delete 的 DB 写入 pending 前同步发布修订，阻止迟到 load 用旧 DB 快照覆盖修改或删除。

详情成功后仍在整个可见期监听修订；隐藏/离页解除监听并使请求、播放失效，显示时恢复监听与合法加载。播放开始捕获身份和修订，各 await 后及导航前复核 active、generation、身份、revision。旧成功、失败和 finally 不得回填详情、发起播放器或解除新请求的防重入锁。

写失败也保守失效，旧详情/播放不会自动复活；待写入结束后通过新加载/重试重新校验，已删除或不可用来源需返回选择。模型修订是保守失效依据，不承诺其他实例修改完全不影响当前操作。

不得将配置或凭据加入 DTO、路由、key、验证截图或日志。注意既有图片 URL 沿用客户端鉴权，可能包含认证参数；不能据此宣称整个结果对象无敏感信息，禁止记录完整结果或认证 URL。

## 状态与恢复

| 场景 | 当前行为与恢复方式 |
| --- | --- |
| 请求中 | 显示 loading；新关键词或失效使旧响应不能覆盖新状态 |
| 无匹配 | 显示当前服务器未找到匹配内容；不是网络失败 |
| 认证失败 | 归类 `auth`，提示检查来源配置后重试；重试本身不会修复凭据 |
| 超时、网络、无效响应 | 分别归类 `timeout`、`network`、`invalidResponse`，显示可重试反馈 |
| 来源不可用 | `unavailable`，返回重新选择来源；不回退本地 |
| 搜索重试 | 按当前文本与来源重新请求，不复用失效结果 |
| 详情失败/配置失效 | 显示错误及重试入口；成功和失败后均释放当前请求锁，失效旧 finally 不释放新锁 |
| 返回再次搜索 | 重新校验当前来源再搜索；自动测试覆盖迟到响应隔离，真实设备返回顺序待验收 |

错误分类是客户端归一结果，不是完整 HTTP 故障诊断；真实 401/403、超时、下线与异常响应尚需各协议实例验证。

## 分层验证与原始证据

最终 QA 在 `420c8856f53feb94b8af8a8d36bc11eea304142c` 上验证冻结 diff，随后原样提交为本文基线 `1f586f93e`。完整 diff SHA256：`da380c1a4e58248a5a5f428407f539cf2af6845f75ce5f8e7ca52085f7d39768`。903 个受跟踪及非忽略新增文件前后 hash 一致；最终三文件 hash 与冻结一致。

| 层级 | 已有结果 | 能证明 / 不能证明 |
| --- | --- | --- |
| Hypium 用例 | 59 项通过，host runner 执行 | 断言与协议替身覆盖；不是 59 项真机测试 |
| host 方法回归 | 冷入口 12 组、pending update/delete 8 组、loaded revision 8 组、stream/directory 隐藏与导航 12 组，另有首次 await、旧 catch/finally、重试等断言 | 转译真实模型、提取真实页面方法；DB、transport、navigation、context builder 为替身；上述组数不累加到 59 |
| 原独立失败探针复验 | update/delete DB pending 均 `pushes=[]`、`hasDetail=false`，exit 0 | 原旧 stream 导航阻断已不再复现；非真实网络播放 |
| 独立 QA 生产编译 | `devecocli build --modules entry@default --product default` exit 0；实际 CompileArkTS 3s934ms，BUILD SUCCESSFUL 7s162ms | 页面及模型进入非 ohosTest 生产图；HAP 中 ABC 与当前产物一致；有警告及其他缓存任务，不是 clean build |
| 工程生产编译 | 实际 CompileArkTS 5s594ms | 工程中间证据，不替代独立 QA |
| 工程后续缓存构建 | 634ms 缓存 build | 不计为重新实编译源码的证据 |
| lint | SDK 22 / 6.0.2 找不到；工具虽 exit 0，结果不完整 | 未通过，不能用空 defects 声称合规 |
| format | `format.sh -h` exit 1，IDE 单实例限制 | 未成功执行代码格式化，不声称通过 |
| 真实 HTTP | 无本轮真实三协议闭环证据 | 服务器版本、数据/权限、故障码等仍待确认 |
| TV | 未部署验收 | D-pad、OK、返回、键盘、保栈生命周期顺序、实际播放及性能均待验证 |

原始日志由交付会话保留，不把不可移植的本机绝对路径作为项目链接：

- 最终 QA 前缀 `issue316-loaded-revision-recovery-qa-`：`report.txt`、`verification.json`、`search.log`、`independent-probe.log`、`build.log`、`artifacts.json`、前后 manifest、lint/format 日志及退出码。
- 工程实际编译：`issue316-loaded-revision-engineer-build-before-duplicate-check.log`；后续缓存构建：`issue316-loaded-revision-engineer-build.log`。
- 原失败探针：`issue316-model-revision-final-qa-independent-probe.cjs`；历史失败日志同前缀 `.log`，修后原样运行的输出见最终 QA `independent-probe.log`。

已有定向自动验证命令（需本地现有 TypeScript/依赖；仅供复验，本次文档修改不执行）：

```bash
TYPESCRIPT_PATH=/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript/lib/typescript.js \
pnpm --config.manage-package-manager-versions=false --config.verify-deps-before-run=false \
  --dir proxy/opensubtitles-worker exec \
  node ../../entry/src/test/search_scope_test.cjs --server-search --integration
```

## 待完成验收与可执行步骤

本会话没有确认当前存在可用的真实三协议实例或 TV，亦没有确认它们一定不存在；连接、授权和设备可用性均待协调核实。不能将“尚无证据”改写为“已验证”或“设备缺失”。未输出或探测连接凭据。

1. 准备获授权的 Jellyfin、Emby、Plex 测试实例，记录脱敏版本、媒体类型/父级关系、权限及是否可达；各含电影、剧集、季/集和空结果样本。未具备任一实例时，该协议 HTTP 验收阻塞。
2. 每协议依次用中文/英文真实文本搜索，点击电影及单集结果、检查实例与剧集目标、进入季/集、返回再搜；检查首批提示，不以结果数量冒充总数。保存脱敏请求状态与界面记录，不保存 token、配置或完整认证 URL。
3. 用获授权测试环境验证 401/403、超时、空结果、下线与恢复重试；在请求/播放 pending 时修改同 ID 配置或删除，验证旧响应无回填、无误导航，写失败后仅新重试恢复。
4. 准备已配对、可安装签名 HAP 的 TV，按仓库局域网部署指令使用待验 worktree 构建安装；未具备设备/签名条件时，TV 验收阻塞。记录提交、产品、系统版本和包 hash。
5. 在 TV 验证系统键盘中文输入、D-pad 聚焦结果/重试、OK 触发、返回再搜；播放 pending 时压入季/人物详情，确认隐藏旧页不能迟到 push，重新显示及正常播放器返回不破坏状态，正常播放只导航一次。
6. 保存协议与设备分开的逐项结果，失败保持未通过；补齐 lint/format 环境验证。本轮不自动扩展修复范围。

本文完成支持矩阵/限制说明最小项；真实协议与 TV 验收、代码规范工具缺口、全部 Issue 验收确认及 PR 合并仍未完成。独立复审接受实现不等于 #316 DONE；不在本任务创建 PR、合并、关闭或归档。

## #317：3.1 输入能力映射与切换回归

本节以已合并 #322 为来源搜索基线；#323 的后续缩略图变更不属于 #316 原验收范围。复核现有生产方法后，3.1 无需新增业务实现，仅补能力切换回归。

| 当前来源 | 输入能力 | 搜索执行路径 | 切换约束 |
| --- | --- | --- | --- |
| 本地配置文件源聚合 | 首字母、全拼、中文 | 本地数据库搜索 | 返回本地时恢复能力并清除服务器结果 |
| 单个视频服务器实例 | 真实文本；服务器拼音不是前置条件 | 当前实例服务器搜索 | 清除本地结果与数据库引用，不进入本地搜索/拼音索引路径 |
| 已失效来源 | 无 | 不发起搜索 | 保持 unavailable，不自动回退本地或其他服务器 |

沿用 `SearchWorkspacePage` 的既有 TextInput、屏幕键盘、页面状态与详情导航；结果仍使用既有本地/服务器分支，不声称已统一所有状态展示或完整交互。系统键盘输入与遥控器焦点需另行设备验证。

新增 host 场景使用真实 `SourceSwitchModel`、`VideoServerModel`、`getSearchCapabilities`、页面 `currentContext` 和搜索方法，覆盖本地 → 服务器 A → 服务器 B → 本地以及当前服务器删除。验证真实中文传至所选实例、旧模式结果清理，以及服务器和 unavailable 即使直接调用本地执行方法也不访问本地数据库。

数据库、HTTP、ArkUI 存取和计时器仍为边界替身：断言证明本地索引入口隔离，不代表真实拼音算法、原生数据库、系统键盘或真实服务器已经验证。新增场景共 42 个断言，可用现有 runner 的 `--search-chains` 复验；上文 `--server-search --integration` 可组合复验相关既有用例。

本节仅对应 OpenSpec 3.1；3.2 全量交互、3.3 TV 路径以及性能、算法和历史迁移均不在本轮范围，OpenSpec 状态由协调分支维护。

## #317：3.2 提交、清空、返回与重入

本地提交现先取消待执行防抖，再搜索并保存历史。修前真实方法连续链记录为提交后「1 个计时器、1 次搜索、1 次历史写入」，排空计时器后变成「0、2、1」；修后为「0、1、1」。服务器提交保持「0、1、0」，不访问本地数据库。

| 操作 | 本地 / 服务器既有行为与回归证据 |
| --- | --- |
| 提交 | 加载真实 TextInput onSubmit 回调，消费待执行防抖，只搜索一次；仅本地写历史 |
| 清空 | clearSearch 清空输入及两种结果，取消防抖并结束 loading |
| 取消等待 / 返回 | 加载真实返回按钮、onBackPressed 及 onWillHide 回调；取消待执行搜索，每次返回仅 pop 一次，硬件返回处理函数返回 true |
| 重入 | 加载真实 onShown 回调；保留关键词，重复 shown 不重复安排搜索；空输入重入不搜索 |

沿用既有结果与状态组件，不新增独立“取消”按钮。上述是 host 方法链及边界替身验证，并非原生系统键盘、生命周期触发时机或遥控器验证；3.3 TV 路径另行验收。精确历史清空早于 load 返回、历史写交叠及全量异步竞态保留给 #318，本项未调整历史异步策略、算法或迁移。OpenSpec 仍由协调分支维护。

## 源码与测试依据

- [搜索归一、身份快照与容量](../entry/src/main/ets/services/search/VideoServerSearchService.ets)
- [Jellyfin / Emby 请求](../entry/src/main/ets/lib/JellyfinClient.ets)
- [Plex 请求及媒体映射](../entry/src/main/ets/lib/PlexClient.ets)
- [输入、状态、重试与详情路由](../entry/src/main/ets/pages/search/SearchWorkspacePage.ets)
- [详情、季入口与播放生命周期](../entry/src/main/ets/pages/detail/ServerMediaDetailPage.ets)
- [配置修订及真实写入链](../entry/src/main/ets/stores/servers/VideoServerModel.ets)
- [服务器搜索用例](../entry/src/test/VideoServerSearch.test.ets)
- [实际方法 host 回归入口](../entry/src/test/search_scope_test.cjs)
