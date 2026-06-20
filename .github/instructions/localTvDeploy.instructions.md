---
applyTo: "build-profile.json5,entry/build-profile.json5,entry/**,.github/agents/*.agent.md,.github/prompts/**"
description: "局域网电视部署与当前 worktree 构建规范。用于在本地 DevEco 环境中构建当前工作树版本、安装到局域网电视、启动应用并采集日志。关键词：worktree、hdc、电视安装、assembleHap、EntryAbility、局域网 TV。"
---

# 当前 Worktree 部署到局域网电视规范

## 目标

- 任何 Agent 在执行“构建 HAP、安装到电视、真机验证、查看电视效果”类任务时，默认操作对象都是**当前工作树**
- 禁止误用主工作区或其他 worktree 的旧产物
- 构建、安装、启动、日志查看使用统一命令

## 一、工作树识别规则

执行任何部署命令前，先确认当前 worktree 身份：

```bash
pwd
git rev-parse --show-toplevel
git branch --show-current
git worktree list
git status --short --branch
```

**规则**：

- 一律以 `git rev-parse --show-toplevel` 的输出作为当前工程根目录
- 一律以当前工程根目录下的 `entry/build/...` 产物作为安装源
- 不要默认使用 `/Users/yaoshining/DevEcoStudioProjects/VidAll_TV`
- 若存在多个 worktree，必须明确说明当前使用的是哪一个路径和分支
- 若当前 worktree 有未提交改动，默认按**当前本地状态**构建和安装，除非用户明确要求只装某个提交或远端版本

## 二、已验证本地环境基线

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
export HARMONY_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
export NODE_BIN=/Applications/DevEco-Studio.app/Contents/tools/node/bin/node
export HVIGOR_WRAPPER=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js
export HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
```

**执行 shell**：

- 优先使用 `zsh -f`
- 避免受用户 shell profile 中额外输出干扰

## 三、标准部署流程

### 1) 检查电视在线状态

```bash
$HDC list targets
```

**成功标志**：

- 输出中存在局域网设备，例如 `192.168.3.85:5555`

若未看到设备：

- 先不要构建和安装
- 先提示设备未连接，等待用户处理网络、配对或开发者模式

### 2) 在当前 worktree 构建开发包

先取当前工程根目录：

```bash
ROOT_DIR="$(git rev-parse --show-toplevel)"
```

标准构建命令：

```bash
zsh -f -c '
cd "'"$ROOT_DIR"'" && \
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && \
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
export HARMONY_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
--mode module -p module=entry@default -p product=default \
assembleHap --analyze=normal --parallel --incremental --daemon'
```

**规则**：

- 默认构建 `product=default`
- 真机看效果时，优先安装 `entry-default-signed.hap`
- 不要在未确认需求前切到 `production`

**成功产物**：

```bash
$ROOT_DIR/entry/build/default/outputs/default/entry-default-signed.hap
```

### 3) 安装当前 worktree 的 HAP 到电视

```bash
ROOT_DIR="$(git rev-parse --show-toplevel)"
HAP="$ROOT_DIR/entry/build/default/outputs/default/entry-default-signed.hap"

$HDC install -r "$HAP"
```

**成功标志**：

- 输出包含 `install bundle successfully`

**规则**：

- 安装时必须显式使用当前 worktree 路径下的 HAP
- 不要复用其他 worktree 或主工作区残留包
- 默认使用 `-r` 覆盖安装

### 4) 启动应用

```bash
$HDC shell aa start -b com.yao.vidalltv -a EntryAbility
```

**成功标志**：

- 输出 `start ability successfully`

### 5) 查看日志

```bash
$HDC shell hilog | grep -i "vidall\\|error\\|fail\\|exception"
```

只看错误：

```bash
$HDC shell hilog -b E
```

## 四、校验与回报要求

执行完部署后，Agent 至少应回报：

- 当前 worktree 路径
- 当前分支名
- 是否存在本地未提交改动
- 构建是否成功
- 安装是否成功
- 启动是否成功
- 安装包路径
- 目标设备地址

推荐格式：

```text
当前 worktree: <绝对路径>
当前分支: <branch>
本地改动: 有 / 无
目标设备: <ip:port>
构建: 成功 / 失败
安装: 成功 / 失败
启动: 成功 / 失败
HAP: <绝对路径>
```

## 五、常见误区

- 在主工作区构建，却把结果当成 feature worktree 版本安装
- 只说“已安装”，但没有说明安装的是哪个 worktree 和分支
- 使用历史 `build/` 产物而不是重新构建当前 worktree
- 设备不在线时仍继续执行安装命令
- 部署后不启动应用，也不确认电视上是否可见

## 六、与其他文档的分工

- `.github/copilot-instructions.md`：只放全局入口和总规则
- 本文件：放 worktree 到局域网电视的操作规范
- `.github/instructions/multiEnvBuild.instructions.md`：放 product / AppEnv / Worker 的多环境构建规则
- `.github/agents/qa-subagent.agent.md`：保留 QA 的测试策略；若涉及真机安装，引用本文件而不是重复维护整套部署命令
