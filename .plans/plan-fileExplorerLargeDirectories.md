# 文件浏览器大目录优化与验收记录

## 范围与实现

起点为获取到的最新 main：`32f967c9ba2387aac0e4ac129ec508f7b475c743`，独立分支 `codex/file-explorer-large-directories`。检查了 FileExplorer、FileExplorerController、FileThumbnail 以及全部两个使用页面：WebDAV `pages/files/index.ets`、SMB `pages/files/SmbFileExplorerPage.ets`。

- FileExplorer 使用 Repeat 虚拟滚动，key 仍是 `resource.key`，`reusable: false`，List `cachedCount(2)`。关闭跨资源复用，离开窗口后释放节点；不维护全目录组件或复用池。
- `sortedResources` 的 @Computed、目录优先、自然排序、大小/日期排序、隐藏过滤保持原样，控制器没有修改。
- 文件名 Text 是可聚焦叶节点，ListItem 保持原 72vp 行高、两列详情、选择控件、禁用规则及点击回调。实际模拟器证明原来的纯容器 ListItem 不能承接方向焦点，故没有仅替换循环就结束。
- 焦点采用实例唯一前缀和稳定资源 key；滚动到目标再申请焦点。方向键只保留一个最新目标和一个短期定时器，快速长按不排队；慢布局短期重试后等待滚动布局事件继续恢复。排序/刷新按 key 保留，删除/过滤后的缺失项取邻近可用项，目录返回优先找刚离开的子目录，空目录回到返回按钮。
- 悬停只高亮一项；键盘事件、控件获焦、滚动和数据变化清除悬停。获焦/悬停继续使用原来的 MARQUEE，其他项 Ellipsis。

## 缩略图归属与上限

`FileThumbnailLease` 明确移交独占 source 及释放回调；release 幂等，不再通过 `/thumb-` 子串推断文件归属。两个页面分别创建唯一临时文件，下载失败时清理部分文件，成功后移交 lease。WebDAV 等待真实下载 Promise，避免回调包装遗漏拒绝。

组件保持 onVisibleAreaChange 触发加载：离屏、参数变化和卸载清除图片、使当前代际失效并释放 lease；重新进入可加载。迟到成功只释放自己的 lease，迟到失败不能覆盖新图。Image 节点按 source 更新，旧节点的解码失败回调也核查 source。

全应用最多 **4 个在途请求**，无下载队列、无图片缓存。迟到请求完成前仍占名额；可见组件最多保留一个 120ms 重试定时器，离屏取消。保留原大小门槛：已知且不超过 8MiB。下载不能主动取消，名额等待现有网络层结算/超时；不冒充具备请求取消能力。

## 最低 API

项目最低 API 19，target API 22。deveco-cli 本地文档和随 DevEco SDK 的声明核查：Repeat/virtualScroll API 12、`reusable` API 18、UIContext FocusController/requestFocus API 12，均不高于 19。SDK 的另一组 `since 22` 注释标的是 crossplatform 扩展，不能误读成最早支持版本。

参考：[Repeat API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-rendering-control-repeat)、[UIContext](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-arkui-uicontext)。**API 19 设备运行尚未验证**，本地构建并不替代最低版本运行验收。

## 性能证据

环境见 [environment.json](../docs/performance/file-explorer/environment.json)：macOS arm64 主机上的 API 24 TV 模拟器，3840×2160，default/debug。同一临时测试页、同一长文件名数据集、相同布局，分别呈现基线 FileExplorer 与当前 FileExplorer；模拟页面使用生产组件，未用网页或 Node 渲染替代 ArkUI。

| 目录项数 | 优化前首屏挂树 ListItem | 优化后首屏挂树 ListItem | 优化前首个可见回调 | 优化后首个可见回调 |
| --- | ---: | ---: | ---: | ---: |
| 100 | 100 | 7 | 42 ms | 29 ms |
| 1000 | 1000 | 7 | 153 ms | 67 ms |
| 10000 | 10000 | 7 | 2002 ms | 686 ms |

原始 [measure.log](../docs/performance/file-explorer/measure.log) 及对应节点树在同目录。created 统计真实 ListItem onAppear，live 用 onAppear/onDisAppear 计数，是实际挂树数量，不是按可见行公式推算的结果；不宣称是底层内存分配次数。firstVisibleMs 从开始生成目录数据到首个真实可见回调，包含数据生成、@Computed 排序和布局，排除网络下载，不是光子送显时间。表中每组取一次完整对照采样，另一次自动化复跑见 [assertions-results.jsonl](../docs/performance/file-explorer/assertions-results.jsonl)。不报告 P95、FPS、真机性能或总内存下降。

滚动证据：1000 项真实向下重复键 3 秒到第 47 项，当前/峰值挂树 9 项；变更排序/过滤/删除后跳至尾项，再向上 3 秒从 955/955 返回 905/955，当前挂树仍为 9。累计挂树会随着滚动增加，当前挂树不随整个目录规模增长。长按测试由设备 `uinput` 注入实际键事件；deveco-cli UI 尚无键盘命令时仅对指定模拟器使用其 SDK hdc 补足。

## 功能和资源回归

[functional.log](../docs/performance/file-explorer/functional.log) 与各 `*-focus.txt` 保存实际窗口焦点树：

- 方向键跨可见区、快速重复、末尾继续向下不越界、反向长按通过。
- 排序后 `/item-855` 保持相同焦点 key，位置 47→7；隐藏过滤后仍为该资源；删除当前项后转到相邻 `/item-836`；刷新继续保留 `/item-836`。
- 进入 `/item-0`、返回根目录定位 `/item-0`、确认键再进入均通过，没有重复打开导致多进入一级。
- 图片可控成功、部分文件写入后失败、2500ms 迟到、快速长按滚动、切目录、重新进入均执行。第一轮离开时成功资源 18/18 全部释放，pending=0，**应用 tempDir 中实际 `thumb-probe-*` 文件数为 0**；重新进入后再次成功显示。完整自动化复跑最终为 59/59 释放、pending=0、files=0，见 [simulator-assertions.log](../docs/performance/file-explorer/simulator-assertions.log)，所有模拟器断言通过。
- [hover-active.png](../docs/performance/file-explorer/hover-active.png) 显示鼠标悬停第二行、长文件名正在移动；[keyboard-after-hover.png](../docs/performance/file-explorer/keyboard-after-hover.png) 显示切到方向键后只有当前行高亮。奇数资源为红图、偶数为绿图，指定失败资源保留图标；截图中资源与颜色一致。
- 主机测试 **31/31 通过**：[host-tests.txt](../docs/performance/file-explorer/host-tests.txt)。包含已有恢复测试，及直接执行真实焦点/缩略图状态机、两个页面真实 loader 方法的受控测试，覆盖失败清理、同步异常、旧成功/失败、离屏再入和并发四个上限。主机测试不等同设备测试。
- 正式入口已恢复，deveco-cli build 退出码 0 且 `BUILD SUCCESSFUL`，记录见 [build.txt](../docs/performance/file-explorer/build.txt)。临时测试页、测量钩子、额外页面注册及 EntryAbility 改动不会进入正式提交。

## 复跑

先确认目标为本任务可占用的 TV 模拟器，所有命令在当前 worktree 执行：

```bash
node --test scripts/tests/file-explorer-lifecycle.test.mjs scripts/tests/file-explorer-recovery.test.mjs
python3 scripts/tests/file-explorer-probe.py install
devecocli run --device 127.0.0.1:5555
python3 scripts/tests/file-explorer-simulator.py --device 127.0.0.1:5555 --output /tmp/explorer-new-run --phase all
python3 scripts/tests/file-explorer-probe.py restore
devecocli build
```

即使测试中断也应执行 restore；备份不会覆盖已有备份。模拟器脚本对挂树数量、同 key 排序恢复、删除/刷新、末尾、目录往返、实际临时文件归零做断言。F1/F2/F3/F4/F5/F6 是仅测试页提供的排序、过滤、删除当前项、跳尾、返回、刷新入口，用于在保持实际行焦点时模拟数据更新；目录进入、上下导航和确认通过真实输入完成。

## 验收边界

- 未使用物理电视；启动的是原先已停止的 Huawei_TV_6_1_1。没有清用户数据或中断其他任务。
- API 19 TV 运行、物理设备帧率/内存、真实 SMB/WebDAV 网络慢响应和解码器全部图片格式尚未做设备端穷举；现有网络适配器未修改。
- 选择状态及各 Builder/回调接口保留；两个当前页面均采用默认非选择模式，带 Checkbox 的自定义使用方式未作模拟器专项验收。
- CI 使用原有工作流，结果按最终提交的 GitHub Checks 报告；不更改或放宽测试门禁。PR 保持草稿，等待独立验收，不自动合并。
