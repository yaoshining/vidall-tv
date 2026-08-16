## Why

issue #258 引入的构建期注入插件 `hvigor/subhub-secret-plugin.ts` 目前只服务 `SUBHUB_API_KEY` 一个变量：键名（`subhub.api.key=` / 环境变量 `SUBHUB_API_KEY`）被硬编码在插件里，每新增一个要注入的配置或密钥都要改插件代码。本变更把该机制通用化，使**任意**已在 `build-profile.json5` 的 `buildOption.arkOptions.buildProfileFields` 声明的字段都能通过 `local.properties` / 环境变量注入，扩展新变量无需改插件。

## What Changes

- **插件改名并通用化**：`hvigor/subhub-secret-plugin.ts` → `hvigor/build-env-inject-plugin.ts`（`buildEnvInjectPlugin()`），不再硬编码单个字段，改为遍历 `buildProfileFields` 中**已声明**的字段逐个注入。
- **注入键约定**：`local.properties` 键统一为 `app.env.<FIELD>`（如 `app.env.SUBHUB_API_KEY=`）；环境变量名统一为 `APP_ENV_<FIELD>`（如 `APP_ENV_SUBHUB_API_KEY`）；优先级 `local.properties` → 环境变量 → 空默认值。
- **注入范围**：仅注入已在 `buildProfileFields` 声明的字段；未声明字段即使存在 `app.env.X` / `APP_ENV_X` 也一律不注入。
- **`hvigorfile.ts`**：插件注册名由 `subhubSecretPlugin` 改为 `buildEnvInjectPlugin`。
- **`build-profile.json5`**：保持不变（两个 product 均提交 `SUBHUB_API_KEY = ""` 空默认值，即「声明即 schema」）。
- **`local.properties` / `local.properties.example`**：键名 `subhub.api.key` → `app.env.SUBHUB_API_KEY`（`local.properties` 已被 `.gitignore` 忽略，真实值不提交）。
- **`.github/workflows/release-build.yml`**：环境变量名 `SUBHUB_API_KEY` → `APP_ENV_SUBHUB_API_KEY`（GitHub Secret `SUBHUB_API_KEY` 名称不变）。
- **`.github/instructions/multiEnvBuild.instructions.md`**：更新注入约定文档为通用机制。
- **`entry/src/main/ets/config/AppEnv.ets`**：无需改动（仍读 `BuildProfile.SUBHUB_API_KEY`）。

**扩展新变量步骤**：① `build-profile.json5` 加 `"FOO": ""`；② 提供 `app.env.FOO` / `APP_ENV_FOO`；③ 代码读 `BuildProfile.FOO`。

## Capabilities

### New Capabilities

- `build-env-injection`: 构建期环境变量注入机制的通用契约——「声明即 schema」、`local.properties` 键名 `app.env.<FIELD>`、环境变量名 `APP_ENV_<FIELD>`、优先级与「仅注入已声明字段」的边界。

### Modified Capabilities

（无。`subhub-subtitle-provider` 规格中「Caller Key 来自构建期注入的 `BuildProfile.SUBHUB_API_KEY`」的运行时行为不变，注入键名属于构建工具内部实现细节，不构成规格级行为变更。）

## Impact

- **新增/改名代码**：
  - `hvigor/subhub-secret-plugin.ts` → 重命名为 `hvigor/build-env-inject-plugin.ts`（通用化实现）。
- **修改代码**：
  - `hvigorfile.ts`：插件导入与注册名更新。
- **修改配置/文档**：
  - `local.properties`、`local.properties.example`：键名 `subhub.api.key` → `app.env.SUBHUB_API_KEY`。
  - `.github/workflows/release-build.yml`：env 名 `SUBHUB_API_KEY` → `APP_ENV_SUBHUB_API_KEY`。
  - `.github/instructions/multiEnvBuild.instructions.md`：注入约定文档通用化。
- **不变**：`build-profile.json5`（保持空默认声明）、`entry/src/main/ets/config/AppEnv.ets`、`entry/src/main/ets/lib/SubHubClient.ets`、`openspec/specs/subhub-subtitle-provider/spec.md`。
- **依赖**：无新增第三方依赖；不引入新的运行时行为。

## 延后（本次不做）

- 变更归档（`openspec archive` 并同步 main specs）留待本分支 PR 合并后的独立 chore 提交。
- 不新增「按 secret 来源分类 / 加密存储」等超出通用注入契约的能力；当前目标仅是把「单字段硬编码」改为「声明驱动」。
