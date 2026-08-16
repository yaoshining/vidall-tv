## 1. 插件通用化

- [x] 1.1 将 `hvigor/subhub-secret-plugin.ts` 重命名为 `hvigor/build-env-inject-plugin.ts`
- [x] 1.2 删除硬编码的 `KEY_FIELD` / `LOCAL_PROPS_KEY`，改为 `LOCAL_PROPS_PREFIX = 'app.env.'` 与 `ENV_PREFIX = 'APP_ENV_'`
- [x] 1.3 将 `readLocalPropertiesKey` 泛化为「解析一次 `local.properties` 产出 key→value map」
- [x] 1.4 新增 `resolveFieldValue(projectDir, field)`：local.properties → 环境变量 → 空字符串
- [x] 1.5 `subhubSecretPlugin()` 改为 `buildEnvInjectPlugin()`，`pluginId` 改为 `build-env-inject-plugin`，遍历各 product 的 `buildProfileFields` 键逐个注入（非空才写入，空值保持默认）

## 2. 注册与配置

- [x] 2.1 `hvigorfile.ts` 更新 import 与 `plugins: [buildEnvInjectPlugin()]`
- [x] 2.2 `local.properties` 键名 `subhub.api.key` → `app.env.SUBHUB_API_KEY`
- [x] 2.3 `local.properties.example` 键名同步改为 `app.env.SUBHUB_API_KEY=`，注释指向新插件与通用约定
- [x] 2.4 确认 `build-profile.json5` 两个 product 均保留 `SUBHUB_API_KEY: ""` 空默认声明（无需改动）

## 3. CI 与文档

- [x] 3.1 `.github/workflows/release-build.yml` 的 job `env` 键 `SUBHUB_API_KEY` → `APP_ENV_SUBHUB_API_KEY`（值仍为 `${{ secrets.SUBHUB_API_KEY }}`），更新注释
- [x] 3.2 `.github/instructions/multiEnvBuild.instructions.md` 第三节改写为通用注入约定（声明即 schema、`app.env.<FIELD>` / `APP_ENV_<FIELD>`、优先级、扩展新变量三步法）

## 4. 验证

- [x] 4.1 `openspec validate build-env-injection` 通过
- [x] 4.2 `openspec validate --strict build-env-injection` 通过
- [x] 4.3 本地构建 `./hvigorw --mode module -p module=entry@default -p product=default assembleHap` 通过
- [x] 4.4 临时声明 `"FOO": ""` 并配置 `app.env.FOO` 验证注入日志（`已注入 FOO`）后还原
- [x] 4.5 `git status` 确认 `openspec/changes/archive/` 未被跟踪，提交并推送分支
