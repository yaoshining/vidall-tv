/**
 * 通用构建期环境变量注入插件。
 *
 * 目的：把客户端可见配置/受客户端约束的凭据从源码/仓库中移除，改为构建时从
 * 1) gitignored 的 local.properties 的 `app.env.<FIELD>=` 行
 * 2) 环境变量 `APP_ENV_<FIELD>`
 * 读取，并写入 build-profile.json5 的 buildOption.arkOptions.buildProfileFields，
 * 供 ArkTS 侧通过 `BuildProfile.<FIELD>` 读取。
 *
 * ⚠️ 边界：`BuildProfile.<FIELD>` 会被编译进客户端构建产物，本机制仅用于注入
 * 客户端可见配置或受客户端约束的凭据（如客户端直接使用的 Caller Key）。
 * 禁止注入服务端私有密钥（签名私钥、数据库密码、服务端 API Key 等），
 * 否则凭据会随安装包泄露。
 *
 * 注入字段清单 = buildProfileFields 中已声明的字段（「声明即 schema」），
 * 未声明的字段一律不注入。都未配置时保持 build-profile.json5 中的空默认值
 * （构建仍成功）。
 *
 * 扩展新变量步骤：
 * ① build-profile.json5 加 `"FOO": ""`；② 提供 `app.env.FOO` / `APP_ENV_FOO`；
 * ③ 代码读 `BuildProfile.FOO`。无需改本插件。
 */

import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import { OhosPluginId } from '@ohos/hvigor-ohos-plugin';

// hvigor 编译 hvigorfile 时 tsconfig 的 types 为空，未包含 @types/node，
// 这里用本地声明引用 Node 内建能力，避免类型检查报错（运行期由 Node 提供）。
declare function require(id: string): any;
declare const process: { env: Record<string, string | undefined> };
const fs = require('fs');
const path = require('path');

const LOCAL_PROPS_PREFIX = 'app.env.';
const ENV_PREFIX = 'APP_ENV_';

interface AppProductProfile {
  name?: string;
  buildOption?: {
    arkOptions?: {
      buildProfileFields?: Record<string, string>;
    };
  };
}

interface AppBuildProfile {
  app?: {
    products?: AppProductProfile[];
  };
}

interface AppProjectContext {
  getBuildProfileOpt: () => AppBuildProfile;
  setBuildProfileOpt: (profile: AppBuildProfile) => void;
}

/** 解析 local.properties 为 key→value map（不存在/解析失败返回空 map）。 */
function readLocalProperties(projectDir: string): Map<string, string> {
  const result = new Map<string, string>();
  const localPropsPath = path.resolve(projectDir, 'local.properties');
  if (!fs.existsSync(localPropsPath)) {
    return result;
  }
  try {
    const content: string = fs.readFileSync(localPropsPath, 'utf-8');
    const lines: string[] = content.split(/\r?\n/);
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      const eq = trimmed.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key = trimmed.substring(0, eq).trim();
      const value = trimmed.substring(eq + 1).trim();
      result.set(key, value);
    }
  } catch {
    // 读取失败时按未配置处理
  }
  return result;
}

/** 按优先级解析字段值：local.properties → 环境变量 → 空，并返回实际来源。 */
function resolveFieldValue(
  localProps: Map<string, string>,
  field: string
): { value: string; source?: string } {
  const fromLocal = localProps.get(LOCAL_PROPS_PREFIX + field);
  if (fromLocal !== undefined && fromLocal.length > 0) {
    return { value: fromLocal, source: 'local.properties' };
  }
  const fromEnv = process.env[ENV_PREFIX + field];
  if (fromEnv !== undefined && fromEnv.length > 0) {
    return { value: fromEnv, source: '环境变量' };
  }
  return { value: '' };
}

export function buildEnvInjectPlugin(): HvigorPlugin {
  return {
    pluginId: 'build-env-inject-plugin',
    apply(node: HvigorNode) {
      const projectDir = node.getNodePath();

      node.afterNodeEvaluate((root: HvigorNode) => {
        const appCtx = root.getContext(OhosPluginId.OHOS_APP_PLUGIN) as AppProjectContext;
        const profile = appCtx.getBuildProfileOpt();
        const products = profile.app?.products;
        if (!products) {
          return;
        }

        const localProps = readLocalProperties(projectDir);
        let injectedCount = 0;

        for (const product of products) {
          const fields = product.buildOption?.arkOptions?.buildProfileFields;
          if (!fields) {
            continue;
          }
          for (const field of Object.keys(fields)) {
            const { value, source } = resolveFieldValue(localProps, field);
            if (value.length > 0) {
              fields[field] = value;
              injectedCount += 1;
              console.info(`[build-env-inject-plugin] 已注入 ${field}（来自 ${source}）`);
            }
          }
        }

        appCtx.setBuildProfileOpt(profile);
        if (injectedCount === 0) {
          console.info('[build-env-inject-plugin] 无字段注入，保持空默认值');
        }
      });
    }
  };
}
