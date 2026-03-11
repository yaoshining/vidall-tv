---
applyTo: ".github/agents/*.agent.md"
description: "Agent 文件组织与维护规则。用于自定义 Agent 的命名、描述、tools 配置、稳定性维护与低风险重构。关键词：agent、.agent.md、自定义Agent、frontmatter、description、tools、组织规则。"
---

# Agent 文件组织规则

## 目标

- 保持 `.github/agents/*.agent.md` 可用、稳定、易发现
- 允许持续沉淀经验，但避免因为“整理”而破坏已有调用方式
- 将高风险变更限制在必要场景，默认采用低风险维护策略

## 文件组织

- `.github/agents/` 仅放可直接被发现和调用的 `.agent.md` 文件
- 共享规则不要继续堆到单个 agent 文件中，优先沉淀到 `.github/instructions/*.instructions.md`
- agent 文件只保留该角色真正独有的定位、边界、输出格式和工作流
- 若某条规则被多个 agent 复用，应优先抽到 instructions，而不是在多个 agent 文件中复制

## 低风险维护原则

- 默认不要修改现有 agent 的 `name`，避免影响已有调用习惯
- 默认不要删除或大幅改写现有 `description` 中的关键词；需要增强时，以“追加关键词”为主
- 默认不要修改 `user-invocable`，除非明确要调整是否允许用户直接调用
- 默认不要改动 `tools`，除非已经确认当前工具集无效、过宽或缺失，并且变更后能验证不影响使用
- 默认不要重命名 `.agent.md` 文件；若必须重命名，应视为迁移而不是整理

## Frontmatter 规则

- `name`：保持稳定，优先与用户实际使用的称呼一致
- `description`：必须包含清晰的“适用于什么任务”和足够的触发关键词
- `tools`：仅在该 agent 明确受工具白名单约束时声明；若不确定，宁可不改
- YAML frontmatter 必须简洁、合法，不引入不必要字段

## Description 编写原则

- `description` 是 agent 被发现的主要入口，必须保留稳定关键词
- 描述优先覆盖：角色、适用任务、关键领域词
- 扩展描述时优先追加，不要把原有高频关键词删掉
- 不要为了“文案更好看”而改掉用户已经习惯的触发词

## 适合放进 agent 的内容

- 该角色独有的身份定位
- 该角色独有的工作流和输出格式
- 该角色独有的审查或交付标准

## 不适合放进 agent 的内容

- Git 提交、PR、shell 稳定性等通用工作流规则
- ArkTS 通用编译护栏
- 多个 agent 都需要共享的仓库级规范

## 整理顺序

- 先检查：是否真的需要改 agent 文件，而不是只补 instructions
- 再判断：本次改动是否会影响 `name`、`description`、`tools` 的稳定性
- 若只是新增经验，优先补 instructions；仅当角色职责确实变化时再改 agent
- 改完后至少确认：frontmatter 合法、文件仍可读取、名称与描述未破坏原有发现路径

## 当前仓库建议分工

- `SE: HarmonyOS TV 原生工程师`：默认的 ArkTS / HarmonyOS TV 工程实现入口，负责功能开发、问题修复、兼容性处理与 TV 交互落地
- `SE: HarmonyOS TV Code Reviewer`：用于代码审查，不负责主实现；重点找 ArkTS 违规、焦点流风险、API 兼容与性能问题
- `QA`：用于测试计划、缺陷复现、边界场景分析和验证结论，不替代 Code Reviewer 的代码审查职责
- `SE: Pencil UI 设计师`：只负责 `.pen` 设计文件的页面结构、视觉还原与设计验收，不承担 ArkTS 工程实现
- `SE: UX 设计师`：负责 JTBD、用户旅程和 UX 研究材料，不直接替代 Pencil 设计稿产出
- `SE: 产品经理`：负责需求澄清、Issue 设计、用户故事和成功指标，不负责具体代码实现
- `SE: 技术写作`：负责开发文档、教程、博客和说明文档，不承担功能开发
- `软件工程师`：作为通用型兜底 agent，仅在任务不明显属于 TV 原生、QA、UX、PM、Pencil 等专用角色时使用

## 选用优先级

- HarmonyOS TV / ArkTS 功能开发与修复：优先 `SE: HarmonyOS TV 原生工程师`
- 代码审查与回归风险评估：优先 `SE: HarmonyOS TV Code Reviewer`
- 测试设计、复现与验收：优先 `QA`
- `.pen` 页面设计与 Figma 还原：优先 `SE: Pencil UI 设计师`
- 需求分析、Issue 拆分、业务价值澄清：优先 `SE: 产品经理`
- 文档、教程与说明稿：优先 `SE: 技术写作`
- 用户研究与旅程设计：优先 `SE: UX 设计师`

## 低风险整理建议

- 若发现两个 agent 都能覆盖同类任务，优先在 instructions 里补“谁优先”而不是直接删改 agent
- 若发现 agent 边界模糊，优先补“职责边界”说明，不急于重写 description
- 若后续需要真正精简 agent 数量，应先做一次调用频次和实际使用场景回顾，再决定是否合并