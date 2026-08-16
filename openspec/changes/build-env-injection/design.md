# Design: build-env-injection

## Context

当前 `hvigor/subhub-secret-plugin.ts` 硬编码单个字段 `SUBHUB_API_KEY`：`readLocalPropertiesKey` 只读 `subhub.api.key=`，`resolveSubHubApiKey` 只回退 `process.env.SUBHUB_API_KEY`，最终只写 `buildProfileFields.SUBHUB_API_KEY`。插件已在 `afterNodeEvaluate` 里通过 `root.getContext(OhosPluginId.OHOS_APP_PLUGIN)` 拿到并回写 build profile（`getBuildProfileOpt()` / `setBuildProfileOpt()`），这条读写链路是通用化的落点。动机见 proposal.md - Why，行为契约见 specs/build-env-injection。

## Goals / Non-Goals

**Goals:**
- 让注入字段清单完全由 `buildProfileFields` 声明驱动，插件不再硬编码任何字段名。
- 统一注入键名（`app.env.<FIELD>` / `APP_ENV_<FIELD>`）与优先级（local.properties → env → 空默认）。
- 保持现有运行时行为不变（`BuildProfile.SUBHUB_API_KEY` 仍被注入），`AppEnv.ets` / `SubHubClient.ets` 零改动。

**Non-Goals:**
- 不引入加密存储、secret 来源分类或字段级校验（保持「空默认值提交、真实值不提交」的既有安全边界）。
- 不重命名 GitHub Secret（`SUBHUB_API_KEY` 名称保留，仅 CI 侧环境变量名变化）。
- 不改动 `build-profile.json5` 的声明结构（仍为平铺的 `Record<string, string>`）。

## Decisions

### 1. 字段清单从 build profile 上下文读取，而非二次解析 build-profile.json5
在 `afterNodeEvaluate` 中遍历 `getBuildProfileOpt()` 返回的各 product 的 `buildOption.arkOptions.buildProfileFields` 键，作为可注入字段清单。
- **为什么**：`buildProfileFields` 里的空默认值就是「声明即 schema」的唯一事实来源；hvigor 已解析好该结构，复用它能避免手写 JSON5 解析（注释/尾逗号），且与现有 `setBuildProfileOpt` 回写路径一致。
- **备选**：直接 `fs.readFileSync` + 正则/JSON5 解析 `build-profile.json5` —— 重复解析、需处理 JSON5 语法，且与 hvigor 内部已加载的 profile 可能不一致，弃用。

### 2. 通用解析器：local.properties 解析一次，键名用前缀常量
`local.properties` 每个构建只解析一次，产出 key→value map；`resolveFieldValue(projectDir, field)` 按 `local.properties['app.env.' + field]` → `process.env['APP_ENV_' + field]` → `''` 顺序取首个非空值。
- **为什么**：字段数量少但语义上「逐字段重读文件」浪费且散；解析一次成 map 后每个字段 O(1) 查表。前缀常量 `LOCAL_PROPS_PREFIX = 'app.env.'`、`ENV_PREFIX = 'APP_ENV_'` 集中定义，避免魔法字符串散落。
- **备选**：每字段调用一次 `readLocalPropertiesKey(projectDir, key)` 现读现查 —— 简单，但同一文件被读 N 次；功能等价，仅实现取舍。

### 3. 注入语义：非空才写入，空值保持默认
遍历每个 product 的 `buildProfileFields`，对每个字段解析值，`非空` 才写回 `buildProfileFields[field] = value`；空值不动（默认值已在 build-profile.json5 提交）。未注入任何字段时保留现有「未注入，保持空默认值」的日志语义，成功注入时按字段记录来源。
- **为什么**：与现状一致——`SUBHUB_API_KEY` 未配置时构建仍成功、`SubHubClient` 在请求前拒绝；通用化后每个字段同享该「空默认可用」契约。
- **风险规避**：不把空字符串当「显式覆盖」，避免误清空一个本应保留默认值的字段。

### 4. product 缺 buildProfileFields 时跳过（声明即 schema 的自然结果）
某个 product 没有 `buildProfileFields`（即未声明任何可注入字段）时直接跳过该 product，不为其创建空结构。
- **为什么**：注入清单完全由 `buildProfileFields` 声明驱动——没有声明就没有可注入字段，创建空结构是多余的回写；也与 spec「未声明字段不注入」的边界一致。
- **备选**：沿用 #258 的「不存在则逐层创建」防御逻辑 —— 在通用化后已无必要（旧代码需要它是因为要无条件写入 `SUBHUB_API_KEY`），且会引入对未声明 product 的无谓变异，弃用。

### 5. 插件改名与注册
`subhubSecretPlugin()` → `buildEnvInjectPlugin()`，`pluginId` 改为 `build-env-inject-plugin`，文件重命名为 `hvigor/build-env-inject-plugin.ts`；`hvigorfile.ts` 同步更新 import 与 `plugins: [buildEnvInjectPlugin()]`。
- **为什么**：插件职责由「SubHub 专用」变为「通用注入」，命名应与职责一致，日志前缀同步更新便于排查。

## Risks / Trade-offs

- [字段名大小写敏感导致键名不匹配] → 明确「原样拼接、大小写敏感」入 spec，文档示例统一用大写字段名，避免 `APP_ENV_subhub_api_key` 之类误配。
- [local.properties 解析失败/文件缺失] → 按未配置处理，回退环境变量，最终空默认，构建不失败（沿用现状 try/catch）。
- [意外注入未声明字段] → 插件只遍历 `buildProfileFields` 的键，天然隔离；spec 用「未声明不注入」显式约束。
- [CI Secret 名与 env 名混淆] → GitHub Secret 名 `SUBHUB_API_KEY` 不变，仅 workflow 中 `env:` 键改为 `APP_ENV_SUBHUB_API_KEY`，注释同步说明二者映射。

## Migration Plan

- 无数据迁移：`local.properties` 键名 `subhub.api.key` → `app.env.SUBHUB_API_KEY`（本地一次改键即可）；CI 侧仅改 env 键名。
- 部署：正常 `assembleHap` 即可；运行时行为不变。
- 回滚：revert 本分支即恢复 `subhub-secret-plugin.ts` 旧行为；只需同时把本地 `local.properties` 键名改回。

## Open Questions

（无——注入键名、优先级、范围均已由 issue #261 的设计决策确定。）
