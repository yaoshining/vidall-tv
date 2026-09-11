# 实现验证：local-search-suggestion-preview

验证日期：2026-09-11。主规格已同步；用户在 PR #331 合并后明确要求归档，已于 2026-09-11 归档。下文未归档表述为各阶段的历史记录。

## 完整性

当前进度为 10/10：实现与主机回归通过，用户于 2026-09-11 明确确认“模拟器验收通过”。以下早期记录保留当时的验证边界；此前设备验收待办已由用户确认关闭，最新正式核验结论见文末。提案、设计、增量规格、任务和验证记录齐备。

## 正确性与设计一致性

| 行为 | 实现证据 | 验证 |
| --- | --- | --- |
| 单首字母前缀，大小写兼容，不匹配任意中段 | LocalSearchQuery.ets:105 | 真实 SQLite 验证 H/h 命中花开锦绣、花儿与少年，h 不命中上海故事；原排序、过滤和迁移回归通过 |
| 真实片名候选、去重与上限 | SearchSuggestions.ets:5 | 当前来源隔离、去重、稳定顺序与 20 项上限测试通过 |
| 原输入与候选保留、首项自动查询 | SearchWorkspacePage.ets:583 | 页面真实方法测试验证两阶段查询、首项结果及自动写入片名历史 |
| 主动选择与提交使用片名历史 | SearchWorkspacePage.ets:616 | 页面逻辑与真实 SQLite 历史隔离、插入更新和清空回归通过 |
| 输入、清空、换源、离页、错误与重试 | SearchWorkspacePage.ets:439 | 迟到响应和来源往返连续链通过；候选结果错误保留所选词重试 |
| TV 横向联想词及焦点、空输入历史 | SearchWorkspacePage.ets:976 | ArkTS 构建通过；代码核对焦点与选中样式、滚动及结果上行返回路径，实机见下方限制 |

符合设计：250ms 本地防抖、服务器 800ms 不变；沿用 SearchSession 请求失效及 scoped history；没有新增依赖或数据库迁移。候选取自最多 200 项现有搜索结果，最多展示 20 个去重标题，不承诺全量。

## 已执行检查

- `devecocli build`：最终构建成功（6.150s），生成签名 HAP；有项目及依赖原有告警，无编译错误。
- `local_pinyin_search_test.cjs`：通过，真实 SQLite 查询、写入、排序及迁移。
- `search_suggestions_test.cjs`：通过，候选和页面逻辑及真实历史存储。
- `search_scope_test.cjs --integration --server-search`：主机集成连续链通过；Hypium 59 个用例全部通过，0 failure / 0 error。
- `openspec validate local-search-suggestion-preview --strict`：通过。
- `git diff --check`：通过。

测试使用 Node.js v26.4.0 及 DevEco Studio 自带 TypeScript。

## 验证限制

首次验证时没有运行中的设备；继续验收时启动了本机已有的两个 TV 模拟器，使用同一个构建执行 `devecocli run --device <名称> --skip-build`。

| 模拟器 | 安装与启动结果 | 证据与限制 |
| --- | --- | --- |
| Huawei_TV，HarmonyOS 5.1.1(19)，127.0.0.1:5555 | 安装成功，启动后立即崩溃 | 2026-09-11 03:14:43 崩溃：`Cannot read property DatabaseObject of undefined`；定位 `db/models/UserAccount.ets:9`。日志显示缺少 cloudDatabase 系统模块。该账号模型本次未修改，尚未进入搜索页。 |
| Huawei_TV_6_1_1，HarmonyOS 6.1.1(24) Beta1，127.0.0.1:5557 | 安装成功，启动后可读取存活进程日志（PID 2626） | 03:17:30 仍有进程日志；出现网络 CURLcode 60 与系统 QoS 错误，不能据此声明界面或网络加载已通过。 |

WARNING：当前 CUA 应用列表不提供模拟器窗口；按名称 Emulator 和已安装可执行文件路径连接均返回 Invalid app，无法完成视觉及遥控器操作验收。TV 实际布局、候选横向滚动、焦点与真实媒体库仍待设备/UI 验证。不能把安装启动成功当作联想词交互通过。

建议后续在可操作的 HarmonyOS 6.1.1 模拟器或真机上按 entry/src/test/README.md 手动验收。旧模拟器启动兼容问题属于账号云数据库初始化链，未在本搜索变更中扩展修改。

无发现的实现阻断项。按用户要求，不执行归档，等待另行通知。

## 历史删除入口前置

按用户补充要求，清空当前来源历史按钮已移至所有历史词之前。渲染顺序检查通过，确认按钮仅出现一次且保留 clearAllHistory 处理；devecocli build 构建成功，OpenSpec 严格校验及 diff 检查通过。此次未重新安装模拟器，未归档。

## 自动首项历史记录调整

按最新要求，接受有效候选后自动选中首项时调用来源内历史写入；继续输入失效、清空和无候选不会把迟到候选写入历史。重复片名沿用 upsert 去重。页面逻辑回归、来源集成连续链及 59 个 Hypium 用例通过；devecocli build 和 OpenSpec 严格校验通过。

## 最新布局文档同步

已将确认的第二版横向本地布局和服务器系统键盘布局补入 proposal、design、增量规格及 tasks。参考图保存到 references/search-layout-horizontal.png。此次仅修改文档与参考图，新增任务尚未实现、未部署，未同步主规格，也未归档。


## 紧凑布局实现及主机验证

- 已实现单行顶部栏、三行键盘、横向词条与剩余空间结果区；服务器不渲染自定义键盘，历史与结果随剩余高度排布。
- `search_suggestions_test.cjs`：通过。新增真实页面方法检查覆盖所有底行按键一次 DOWN、UP 返回原键、20 个候选末项定位、15 条历史、删除后索引收敛、无候选/结果回退及服务器不聚焦本地候选。
- 以 912×234、1232×432、1872×720 的结果视口检查海报六列和完整标题/元数据可容纳；这只是尺寸算法验证，不是 UI 截图。
- `search_scope_test.cjs --integration --server-search`：连续链通过，Hypium 59/59，0 failure / 0 error；原生布局和滚动不由这些主机替身验证。
- `devecocli build`：通过。`devecocli run --device Huawei_TV_6_1_1 --skip-build` 安装、启动成功。
- 03:57:54 读取到应用 PID 13837 的运行日志，仍有系统 QoS 报错；不能以进程存活替代搜索页面运行/视觉验收。
- 当前模拟器窗口仍不能通过 CUA 连接，未取得本地或服务器搜索页截图；3.1、3.2、3.4 的设备验收部分未完成。请按下述路径检查后再勾选。

### 待执行设备检查

1. 本地输入得到至少六条结果：首屏看到完整三行键盘、横向候选、一排六张海报和标题；无需滚动整页。
2. 依次从 Z、M、退格、9、0 按 DOWN 进入候选，左右访问第 20 项，UP 返回键盘，DOWN 进入结果，首排 UP 回到选中词。
3. 测试超长片名聚焦滚动、清空后 15 条历史横向显示、第一项清空、单项删除及空列表焦点。
4. 在 Jellyfin/Emby/Plex 当前实例主动打开和收起系统键盘，检查无本地键盘占位、历史与结果上移、长来源名不换行、实例切换隔离。

变更继续保留，未归档，未同步主规格。


## OpenSpec 正式核验（2026-09-11）

核验对象：`local-search-suggestion-preview`；schema：`spec-driven`；范围：`repo-local`。核验代码提交为 `062ce4ce4`，本轮仅更新验收文档。读取了 proposal、design、tasks 和两个增量规格，未跳过完整性、正确性或一致性核对。

### 总览

| 维度 | 结果 |
| --- | --- |
| 完整性 | 10/10 任务完成，4 项需求均有实现 |
| 正确性 | 4/4 需求、19 个场景完成实现映射；主机回归通过，模拟器验收由用户确认 |
| 一致性 | 符合两阶段本地查询、来源隔离、紧凑横向布局及服务器输入能力分支设计 |

### 需求与场景映射

以下源码路径均相对 `entry/src/main/ets/`。

| 需求及场景 | 实现证据 | 验证证据 |
| --- | --- | --- |
| 首字母完整词、前缀、单字母大小写（3 个场景） | `services/search/LocalSearchQuery.ets:105`；入库字段 `db/files/MediaContentDao.ets:183`、`:272`、`:360`、`:392` | `local_pinyin_search_test.cjs` 真实 SQLite 查询及写入回归 |
| 同词不同来源、选建议和换源、建议内容边界（3 个场景） | `services/search/SearchSuggestions.ets:5`；`pages/search/SearchWorkspacePage.ets:477`、`:563`、`:697` | 建议去重/上限、来源连续切换及真实历史 DAO 测试 |
| 首项自动预览、主动选择历史（2 个场景） | `pages/search/SearchWorkspacePage.ets:638`、`:675`、`:691` | 两阶段查询、原输入保留、自动与主动历史断言 |
| 空输入/无匹配、过期响应（2 个场景） | `pages/search/SearchWorkspacePage.ets:497`、`:579`、`:638` | 空匹配、迟到候选无历史、清空/切源/离页与失败重试测试 |
| 遥控器候选、删除入口优先（2 个场景） | `pages/search/SearchWorkspacePage.ets:831`、`:1068`、`:1094`、`:1182` | 焦点方法与渲染顺序回归；用户模拟器验收确认 |
| 首屏完整结果、约六项候选、长词/不足、本地历史替换（4 个场景） | `pages/search/SearchWorkspacePage.ets:276`、`:870`、`:1068`、`:1094`、`:1182`、`:1243` | 几何边界、空列表与焦点回退主机测试；用户模拟器验收确认 |
| 服务器主动编辑/收起、历史来源一致、无历史/长名称（3 个场景） | `pages/search/SearchWorkspacePage.ets:888`、`:1094`、`:1243` | 系统输入回调和实例隔离主机测试；用户模拟器验收确认 |

### 本轮复核

- 重新运行 `local_pinyin_search_test.cjs`：通过。
- 重新运行 `search_suggestions_test.cjs`：通过。
- 重新运行 `search_scope_test.cjs --integration --server-search`：通过，Hypium 59/59，0 failure / 0 error。
- `openspec validate local-search-suggestion-preview --strict`：通过。
- 构建沿用同一代码版本此前的 `devecocli build` 成功记录；本轮无代码修改，未重复构建或安装。
- 用户明确回复“模拟器验收通过”，关闭原剩余设备验收项。此为用户验收证据，不是代理自动化截图或逐场景设备实测记录。

### 按优先级的问题

- **CRITICAL：0**。用户确认设备验收后，无未完成任务或未找到实现的需求。
- **WARNING：0**。未发现明确的规格或设计偏离。
- **SUGGESTION：1**。后续可在 `references/` 补存本地及服务器搜索页截图，便于复查六列海报、长词和键盘收起状态；当前未收集截图附件。

### 结论

当前修复的代码核对、主机回归及构建已通过。此前用户确认的模拟器验收仅针对 PR 修复前版本，不作为当前修复的设备验收结论；当前修复未重新执行模拟器交互，仍待设备复验。本次不归档，主规格已同步。保留此前失败的旧版本模拟器记录，不能据本次用户反馈推断该兼容问题已修复。


## 主规格同步记录（2026-09-11）

用户明确要求执行 openspec-sync-specs，本轮已将增量规格合并至主规格：

- `openspec/specs/media-search/spec.md`：在首字母匹配需求下新增单首字母场景。
- `openspec/specs/source-scoped-search/spec.md`：在来源内历史与建议需求下新增 6 个场景；新增紧凑搜索首屏布局、影视服务器搜索布局按输入能力适配两项需求（共 7 个场景）。
- 保留所有未涉及的主规格内容，重复合并不会重复添加需求或场景。
- 此记录更新此前“未同步主规格”的历史状态；变更仍未归档。

## PR 评审修复验证

三条评审意见经当前代码核对均成立，已完成最小修复。新增测试验证非空输入期间保留原结果和 refreshing 状态、迟到结果不覆盖、清空输入移除结果；立即确认 HKJX 只写入实际候选片名，无匹配不写原输入。服务器原输入历史行为不变。主规格和增量规格统一使用每字一个拼音首字母，重庆森林对应 cqsl。

修复后 search_suggestions_test.cjs、search_scope_test.cjs --integration --server-search 均通过，Hypium 59/59；devecocli build 成功。本轮未重新执行模拟器交互，之前的用户验收记录不代表本次修复经过设备复验。当前任务共 13/13 完成，仍未归档。


## 归档记录（2026-09-11）

用户确认 PR #331 已合并并明确要求归档。已核对 main 合并提交 832817716、13/13 已完成任务及两份主规格同步状态，归档至 archive/2026-09-11-local-search-suggestion-preview。保留全部设计、参考图、增量规格与验证记录。本次归档不代表补做了设备验收；PR 修复后的设备复验仍未执行。
