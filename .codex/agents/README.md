# 项目 Codex agents

复制自 `.github/agents/*.agent.md` 的 10 个项目级自定义 agents，原始 Copilot 文件未修改。

使用 [Codex 官方自定义 agent 格式](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents)：每个 TOML 包含 name、description 和 developer_instructions。

## 使用

在本项目中开启新的 Codex 会话，明确指定角色，例如：

> 请使用“SE: HarmonyOS TV Code Reviewer”子 agent 审查当前改动。

客户端需支持并允许加载项目级自定义 agents。现有会话的即时重载取决于客户端。本次校验了 TOML 格式和正文完整性，未启动角色执行实际任务。

## 迁移说明

- 原名称、描述及完整正文保留，正文前增加 Codex 运行适配说明。
- Copilot 的 tools、user-invocable 不直接写入 Codex 配置；原工具列表可查源文件，实际工具取决于当前会话。
- 模型与推理强度继承 Codex 配置，未沿用源文件的 GPT-5.4 / Auto 偏好。
- Copilot 后台分发与自动 PR 行为按适配说明处理。
- 这是独立副本，源文件修改不会自动同步。

| 角色 | Copilot 源文件 | Codex 配置 |
| --- | --- | --- |
| SE: 产品经理 | `PM.agent.md` | `PM.toml` |
| SE: HarmonyOS TV Code Reviewer | `harmonyos-tv-code-reviewer.agent.md` | `harmonyos-tv-code-reviewer.toml` |
| SE: HarmonyOS TV 原生工程师 | `harmonyos-tv-native-engineer.agent.md` | `harmonyos-tv-native-engineer.toml` |
| 元 Agent 项目脚手架 | `meta-agentic-project-scaffold.agent.md` | `meta-agentic-project-scaffold.toml` |
| SE: Pencil UI 设计师 | `pencil-ui-designer.agent.md` | `pencil-ui-designer.toml` |
| SE: 项目经理 | `project-manager.agent.md` | `project-manager.toml` |
| QA | `qa-subagent.agent.md` | `qa-subagent.toml` |
| SE: 技术写作 | `se-technical-writer.agent.md` | `se-technical-writer.toml` |
| SE: UX 设计师 | `se-ux-ui-designer.agent.md` | `se-ux-ui-designer.toml` |
| 软件工程师 | `software-engineer-agent-v1.agent.md` | `software-engineer-agent-v1.toml` |
