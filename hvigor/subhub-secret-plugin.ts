/**
 * SubHub Caller Key 构建期注入插件。
 *
 * 目的：把 SubHub Caller Key 从源码/仓库中移除，改为构建时从
 * 1) gitignored 的 local.properties 的 `subhub.api.key=` 行
 * 2) 环境变量 `SUBHUB_API_KEY`
 * 读取，并写入 build-profile.json5 的 buildOption.arkOptions.buildProfileFields，
 * 供 ArkTS 侧通过 `BuildProfile.SUBHUB_API_KEY` 读取。
 *
 * 都未配置时保持 build-profile.json5 中的空默认值（构建仍成功，
 * SubHubClient 会在请求前明确拒绝，而不是静默省略 Authorization 头）。
 */

import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import { OhosPluginId } from '@ohos/hvigor-ohos-plugin';

// hvigor 编译 hvigorfile 时 tsconfig 的 types 为空，未包含 @types/node，
// 这里用本地声明引用 Node 内建能力，避免类型检查报错（运行期由 Node 提供）。
declare function require(id: string): any;
declare const process: { env: Record<string, string | undefined> };
const fs = require('fs');
const path = require('path');

const KEY_FIELD = 'SUBHUB_API_KEY';
const LOCAL_PROPS_KEY = 'subhub.api.key';

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

/** 从 local.properties 读取 `subhub.api.key=`（不存在/解析失败返回空字符串）。 */
function readLocalPropertiesKey(projectDir: string): string {
  const localPropsPath = path.resolve(projectDir, 'local.properties');
  if (!fs.existsSync(localPropsPath)) {
    return '';
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
      if (key === LOCAL_PROPS_KEY) {
        return trimmed.substring(eq + 1).trim();
      }
    }
  } catch {
    // 读取失败时按未配置处理
  }
  return '';
}

/** 按优先级解析 Caller Key：local.properties → 环境变量 → 空。 */
function resolveSubHubApiKey(projectDir: string): string {
  const fromLocal = readLocalPropertiesKey(projectDir);
  if (fromLocal.length > 0) {
    return fromLocal;
  }
  const fromEnv = process.env[KEY_FIELD];
  if (fromEnv !== undefined && fromEnv.length > 0) {
    return fromEnv;
  }
  return '';
}

export function subhubSecretPlugin(): HvigorPlugin {
  return {
    pluginId: 'subhub-secret-plugin',
    apply(node: HvigorNode) {
      const projectDir = node.getNodePath();
      const key = resolveSubHubApiKey(projectDir);
      if (key.length === 0) {
        console.info('[subhub-secret-plugin] SUBHUB_API_KEY 未注入，保持空默认值');
        return;
      }

      node.afterNodeEvaluate((root: HvigorNode) => {
        const appCtx = root.getContext(OhosPluginId.OHOS_APP_PLUGIN) as AppProjectContext;
        const profile = appCtx.getBuildProfileOpt();
        const products = profile.app?.products;
        if (!products) {
          return;
        }
        for (const product of products) {
          if (!product.buildOption) {
            product.buildOption = {};
          }
          if (!product.buildOption.arkOptions) {
            product.buildOption.arkOptions = {};
          }
          if (!product.buildOption.arkOptions.buildProfileFields) {
            product.buildOption.arkOptions.buildProfileFields = {};
          }
          product.buildOption.arkOptions.buildProfileFields[KEY_FIELD] = key;
        }
        appCtx.setBuildProfileOpt(profile);
        console.info('[subhub-secret-plugin] 已注入 SUBHUB_API_KEY（来自 local.properties / 环境变量）');
      });
    }
  };
}
