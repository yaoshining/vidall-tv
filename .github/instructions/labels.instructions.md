# 标签使用规范

> 本文件为 Agent 共享知识，所有 Agent 在执行任务时应遵循本规范。
> 标签定义请参考 `docs/labels.md`（人类可读文档）。

---

## 一、标签组合标准

每个 Issue 应包含以下维度的标签：

| 维度 | 必须包含的标签 | 说明 |
|------|----------------|------|
| **组件** | `area:*` 之一 | 问题涉及的功能模块 |
| **规模** | `size:*` 之一 | 预计工作量 |
| **类型** | `bug` / `enhancement` / `feature` 等 | Issue 类型 |
| **阶段** | `phase: *` / `ready-to-*` / `moonshot` | 所处产品阶段 |
| **优先级** | `priority:*` 之一 | 业务优先级 |
| **Bug 特有** | `repro:*`（若为 bug） | 可复现性评估 |

### 示例组合

```
# 高优先级播放器 Bug（应立即处理）
bug + priority: high + area: player + repro:high

# 中等规模媒体库改进（按计划处理）
enhancement + priority: medium + size: medium + area: media-library + phase: 2-enhanced

# 长期想法（暂不规划）
enhancement + moonshot + size: medium
```

---

## 二、标签使用决策规则

### 2.1 Bug 优先级判断

当评估一个 Bug 的处理优先级时，需同时考虑 `priority:*` 和 `repro:*`：

```
高优先级 + 高可复现性 (repro:high)  → 立即处理
高优先级 + 低可复现性 (repro:low)   → 优先澄清复现条件
低优先级 + 高可复现性              → 按计划处理
低优先级 + 低可复现性              → 考虑关闭或推迟
```

### 2.2 阶段标签选择

| 状态 | 应使用标签 | 说明 |
|------|------------|------|
| 需求已澄清，等待设计 | `ready-to-spec` | 等待 PM/UX 出设计稿 |
| 设计已确认，等待开发 | `ready-to-implement` | 等待工程师认领 |
| 有价值但暂不投入 | `moonshot` | 散落在 Backlog 的长期想法 |
| 正常迭代开发 | `phase: 1-mvp` 或 `phase: 2-enhanced` | 按产品里程碑归属 |

### 2.3 阻塞状态标识

当 Issue 存在外部依赖时：
- 添加 `blocked` 标签
- 在 Issue 评论中说明阻塞原因和 `blocked by #xxx`
- 同步更新 Project 状态为 `BLOCKED`

---

## 三、标签维护规则

1. **新建 Issue 时**：必须同时选择合适的标签组合
2. **状态流转时**：根据当前状态更新标签（如开发完成 → 添加 `ready-to-implement`）
3. **PM 专属**：新增/修改/删除标签需经过 `SE: 产品经理` 确认
4. **文档同步**：标签变更后更新 `docs/labels.md` 和本文本

---

## 四、常见错误

| 错误 | 正确做法 |
|------|----------|
| 只加 `bug` 标签，没有组件/优先级 | 必须同时添加 `area:*` + `priority:*` + `repro:*`（如适用） |
| 用 `phase: *` 表示 Issue 就绪状态 | 应用 `ready-to-spec` / `ready-to-implement` |
| 把长期想法放进里程碑 | 使用 `moonshot` 标签 |
| 重复添加多个同类标签 | 每类标签只选一个 |