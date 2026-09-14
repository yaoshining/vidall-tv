# 播放器异步生命周期竞态修复与验证

基于最新 main `3818ef2e9a4d0762c0f2e7a7c67ef804004776ce`（PR #339）。独立分支 `codex/player-session-races`，不自动合并，等待独立验收。

## 复现与修复范围

先在未修改的生产实现上用 deferred promise 复现了 8 类缺陷：媒体标识乱序、初始化中退出、后端探测中退出、release 与 init 重叠、音轨枚举迟到、音轨切换暂停迟到、字幕解析在 reset 后回写、退出后的旧回调。使用数据库、播放器或 IO 边界替身，未复制控制器逻辑。

仓库中的安全断言也能对 main 复现：`baseline-red.txt` 的 5 项测试均失败，分别断言最新媒体标识、退出后不创建实例、后端查询退出、音轨列表归属、旧回调失效。日志中的其他用例因 name pattern 未运行，不构成通过证据。`host-fixed.txt` 是本次修复后完整主机回归结果。

本轮没有拆分控制器大文件。资源摘取和清理逻辑保留在控制器内；改动的 service、bridge、dispatcher 和偏好写入边界均用于阻止 await 内部的迟到副作用。

## 会话与资源归属

- initPlayer、release、AVPlayer→MPV 回退均在首个 await 前递增会话编号。同步摘取旧 player，失效字幕 bridge/service，清理进度和字幕计时器。退出不再等待底层释放后才失效。
- 元信息和路由查询完成后先验证会话；媒体名称和 source 在异步查询前设置。旧媒体标识不提交，旧查询不创建实例。
- 每个退役 player 捕获其已经启动的初始化 Promise。清理队列等待该 Promise settle 后对原实例释放一次；新实例创建必须等待清理队列。旧 release 不会在 await 后修改共享 this.player。
- AVPlayer 初始化和 MPV surface 绑定都纳入该等待关系。bindMpvContext 在 surface.onLoad 返回后、adapter.init 前自行检查会话。相同 surface 的重叠绑定合并；旧失败不会触发新会话的错误处理。
- MPV→MPV 切集保持原 softRelease 语义，NativeWindow 交给新实例；若等待中退出，保留的 surface 由退出清理。SMB 代理及 VPE 记录创建代次，旧代次无权释放后来创建的资源。
- reload 请求编号与播放器会话编号分离：同源后端回退沿用请求，新源/退出才使请求过期，旧 catch 不拒绝新请求。
- 音轨枚举、默认选轨、pause→select→seek/play、ready 恢复、play/seek 及异常/finally 分支均验证原会话/实例。用户新选轨会使旧自动选轨建议失效。字幕切换持久化在开始时捕获稳定源 key。
- SubtitleSessionService 的 reset 和新操作使旧 operation 失效；Base/AV/MPV/SMB 字幕 bridge 在内部 await 后验证生命周期，阻止迟到轨道投影、自动选择和 SMB 提取 fallback。旧字幕异常安全结束。
- 音轨及字幕 dispatcher 的失效绑定清理、保存选择会把有效性检查传到偏好写入层；等待 store 初始化后再次检查。对已经开始、无法取消的 put，同 key 新写入排在其后，避免旧写入最终覆盖新选择。

## 验证

### 主机

安装或指定 TypeScript 5.6.3 后运行：

```sh
TYPESCRIPT_PATH=/path/to/typescript node --test entry/src/test/player_session_races_test.cjs
```

36/36 通过，执行真实控制器、会话服务、字幕 bridge、音轨路由、代理/VPE 所有权检查及偏好持久化实现。测试覆盖初始化成功/异常迟到、退出、连续切集、重复释放、音轨/字幕迟到及旧异常、MPV surface 重叠/失败、soft release、正常 ready/play/pause/seek/续播、重进和后端回退。断言最终字段、实例身份、调用目标和释放次数。

新增独立主机 CI workflow；原有单元测试、集成测试和严格证据门禁保持不变。4 个 ArkTS 用例注册到现有单元测试 List.test，等待真实平台 CI 执行。

复现 main 的安全断言失败（预期非零退出）：

```sh
mkdir -p /tmp/player-race-baseline
git archive 3818ef2e9a4d0762c0f2e7a7c67ef804004776ce entry/src/main/ets | tar -x -C /tmp/player-race-baseline
PLAYER_SOURCE_ROOT=/tmp/player-race-baseline/entry/src/main/ets \
TYPESCRIPT_PATH=/path/to/typescript \
node --test --test-name-pattern='媒体标识乱序|media 等待中退出|routing 等待中退出|旧音轨枚举|退出后旧回调' \
entry/src/test/player_session_races_test.cjs
```

### 构建与 TV 模拟器

使用 `devecocli build --modules entry` 构建生产 HAP，通过；`devecocli build --modules entry@ohosTest` 构建测试 feature，通过。存在原有依赖/装饰器警告，不等于无警告构建。

在 Huawei_TV_6_1_1 / HarmonyOS 6.1.1 API 24 模拟器，通过 `devecocli run --module entry@ohosTest --ability TestAbility --skip-build` 运行 4 个 ArkTS 用例：路由等待退出、旧 release 与新 init 重叠、旧音轨切换迟到、退出重进。逐项日志见 `platform-hilog.txt`。

测试使用临时专用 TestAbility 和页面，直接调用 `PlayerLifecycleCases.ets`；IPlayer 与路由是受控替身，生产 controller 不替换。普通 TestAbility 首次直接启动因没有 Hypium 参数在测试前报错，不能计为测试结果；改用专用入口后才取得 4/4 逐项证据。临时两个文件已恢复，不进入 PR。仅安装/移除 entry_test feature，移除时指定 `-k` 保留数据；检查生产 entry 仍存在。未卸载应用、未清空应用数据。

## 未验证边界与代价

- 模拟器证据仅代表 ArkTS 运行时的控制器冒烟，不代表真机、真实 AVPlayer/MPV 解码、SMB 网络播放、字幕提取或 VPE 效果验收。正常播放/暂停/续播/切集的自动回归使用受控 IPlayer。
- 已开始的底层 init/onLoad/release 没有被取消。如果它永久不返回，后续实例创建会等待，避免在清理未完成时复用 native 资源；本轮未引入虚假的取消或超时后强行复用。
- 已提交的 native 命令/偏好 put 不能撤销。旧实例的命令不得转向新实例；偏好写入按 key 排队保证顺序。
- 全量既有平台单测与集成测试以 PR CI 的实际结果为准；构建、主机测试和模拟器冒烟均不能替代其门禁。最终 SHA 以 PR HEAD 和交付消息为准。
