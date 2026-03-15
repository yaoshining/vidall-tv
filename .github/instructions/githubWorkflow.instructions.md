---
applyTo: "**"
description: "GitHub 工作流指令。用于 git add、git commit、git push、gh pr create、提交消息生成、PR 创建、命令行执行方式等场景。关键词：GitHub提交指令、提交消息、推送分支、创建PR、gh、git commit、git push。"
---

# GitHub 工作流指令

## 提交消息

- 所有 git 提交消息必须使用中文
- 提交首行格式固定为：`<类型>: <简要说明>`
- 类型仅限：`新增`、`修复`、`优化`、`重构`、`文档`、`测试`、`配置`、`样式`
- 在 IDE 中生成提交消息后，如果结果是英文，必须先改写成中文再提交

## 提交与 PR 操作

- 提交前先确认只包含当前任务相关文件，不要误带工作区中无关的未跟踪文件
- 每个阶段性任务必须在独立分支上开发，禁止多个阶段任务混用同一开发分支
- 阶段性任务开始时先创建并切换分支（建议命名：`feat/issue-<编号>-<阶段简述>`）
- 每次有阶段性进展（可验证的小里程碑）必须执行一次 `git commit` 并 `git push` 到对应远端分支
- 能分步执行时，不要把 `git add`、`git commit`、`git push`、`gh pr create` 拼成一条超长命令
- 创建 PR 时优先分 3 步执行：先 `git push`，再准备标题/正文，最后 `gh pr create`
- 若 PR 正文较长，优先使用 `gh pr create --body-file <file>`，不要内联超长正文

## 命令行稳定性

- 默认 shell 为 zsh 时，命令中的 `?`、`*`、`[`、`]` 等字符可能触发 glob 展开；包含这类字符的参数必须安全引用
- 不要在终端里直接拼接包含大量中文、Markdown、反引号、问号或特殊字符的超长 `gh pr create --body` 命令
- 避免使用 heredoc 直接向共享终端输入长篇中文正文；若 heredoc 未正常闭合，会导致后续所有命令卡在输入态
- 当终端疑似卡住时，优先判断是否进入 heredoc/交互态；必要时改用新的终端会话继续执行

## 推荐执行模式

- `git status --short`：先确认改动范围
- `git add <files>`：只暂存目标文件
- `git commit -m "修复: ..."`：单独提交
- `git push -u origin <branch>`：单独推送
- `gh pr create --title "..." --body-file <file>`：最后创建 PR