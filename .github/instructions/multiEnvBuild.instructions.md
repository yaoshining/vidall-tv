---
applyTo: "build-profile.json5,entry/build-profile.json5,entry/src/main/ets/config/**,proxy/**"
description: "多环境构建指南。用于 HarmonyOS App 的 product 切换、AppEnv 配置、Cloudflare Worker dev/production 环境区分及 CI 编译命令。关键词：多环境、product、AppEnv、wrangler、production、开发包、发布包。"
---

# 多环境构建规范

## 一、HarmonyOS App 环境配置

### Product 定义

项目在根目录 `build-profile.json5` 中定义两个 product：

| Product | 用途 | 签名 | 代理 URL |
|---------|------|------|----------|
| `default` | 开发调试 | debug key | `http://localhost:8787/v1` |
| `production` | 正式发布 | release key（`certs/release/`） | `https://os-proxy.vidall.app/v1` |

### AppEnv 模块

环境判断逻辑集中在 `entry/src/main/ets/config/AppEnv.ets`。

```typescript
import { AppEnv } from '../config/AppEnv';

// 使用示例
const proxyUrl = AppEnv.OS_PROXY_BASE_URL;   // 自动按当前 product 选择
const isDev = !AppEnv.IS_PRODUCTION;
```

**规则**：
- 所有环境相关的 URL、开关、Feature Flag **必须**通过 `AppEnv` 统一管理，禁止在业务代码中直接硬编码环境 URL。
- `AppEnv` 读取 `BuildProfile.PRODUCT_NAME`（编译时注入），无运行时开销。

### 编译命令

```bash
# 开发包
hvigorw.js --mode module -p module=entry@default -p product=default assembleHap

# 发布包
hvigorw.js --mode module -p module=entry@default -p product=production assembleHap
```

## 二、Cloudflare Worker 环境配置

Worker 代码位于 `proxy/opensubtitles-worker/`。

### 环境对应关系

| wrangler 环境 | App Product | 命令 |
|--------------|-------------|------|
| 默认（本地 dev） | `default` | `npm run dev` |
| `production` | `production` | `npm run deploy:production` |

### 本地开发

```bash
cp .dev.vars.example .dev.vars
# 编辑 .dev.vars 填入 OPENSUBTITLES_API_KEY
npm run dev   # 监听 localhost:8787，KV 本地模拟
```

### 生产部署

```bash
npm run kv:create:production          # 创建 KV namespace，记录返回的 id
# 将 id 填入 wrangler.toml [env.production.kv_namespaces] id 字段
npm run secret:put:production         # 注入 API Key（不写入版本控制）
npm run deploy:production             # 部署
```

### Secret 管理规则

- **禁止**在 `wrangler.toml` 或任何提交文件中写入明文 API Key。
- 本地开发：使用 `.dev.vars`（已在 `.gitignore` 中）。
- 生产环境：使用 `wrangler secret put --env production`。
- `.dev.vars.example` 仅包含字段名，不含真实值，**可以**提交到版本控制。

## 三、SubHub Caller Key 的构建期注入

SubHub Caller Key（`BuildProfile.SUBHUB_API_KEY`）不在源码或仓库中保存明文，而是由 `hvigor/subhub-secret-plugin.ts` 在构建时注入：

| 来源 | 说明 |
|------|------|
| `local.properties` 的 `subhub.api.key=` | 本地开发首选（`local.properties` 已被 `.gitignore` 忽略） |
| 环境变量 `SUBHUB_API_KEY` | 为 CI / release 预留 |

读取优先级：`local.properties` → 环境变量 → 空默认值。都未配置时构建仍成功，但 SubHub 请求会被 `SubHubClient` 明确拒绝（归类为 `subhub_auth_invalid`，UI 提示「字幕服务配置异常」）。

```bash
# 本地验证注入
cp local.properties.example local.properties
# 编辑 local.properties 填入 subhub.api.key= 真实值（勿提交）
```

- `build-profile.json5` 的两个 product 都提交了 `buildOption.arkOptions.buildProfileFields.SUBHUB_API_KEY = ""` 空默认值。
- `local.properties.example` 仅含字段名，可提交；`local.properties` 含真实值，**禁止**提交。
- **CI 注入**：`.github/workflows/release-build.yml` 在自托管 macOS runner 上构建 production 签名包，通过 GitHub Secret `SUBHUB_API_KEY` 注入 Caller Key（hvigor 插件读取环境变量），并注入 release 签名证书（`RELEASE_CERT_BASE64` / `RELEASE_P12_BASE64` / `RELEASE_PROFILE_BASE64` / `RELEASE_MATERIAL_BASE64`）。公共 GitHub runner（`ci-compile-check.yml`）只能做 OpenHarmony 编译检查，无法构建/签名 HarmonyOS release 包。

## 四、新增环境相关配置时的约束

1. 新增 URL / 端点 → 先在 `AppEnv.ets` 中按 `IS_PRODUCTION` 分支添加，再在业务代码中引用。
2. 新增 Worker 路由 / binding → 同步在 `wrangler.toml` 的默认块和 `[env.production]` 块中配置。
3. 新增 product → 同步更新 `entry/build-profile.json5` 的 `targets` 数组。
4. CI 中需要在公共 runner 编译时，使用 `-p product=default`（不依赖 release 证书）。
