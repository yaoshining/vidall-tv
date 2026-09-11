# 实现验证：local-search-suggestion-preview

验证日期：2026-09-11。变更保留在 changes 中，未归档，未同步到主规格。

## 完整性

原有 6 项实现与验证任务完成；最新确认的布局新增 4 项待实现任务，当前进度为 7/10；新增布局的代码已实现，但需要截图/设备验收的任务仍保持未勾选。下面早期记录仅覆盖当时已实现行为，最新布局证据见文末。提案、设计、增量规格、任务和验证记录齐备。

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
