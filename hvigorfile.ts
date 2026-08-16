import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { buildEnvInjectPlugin } from './hvigor/build-env-inject-plugin';

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [buildEnvInjectPlugin()]     /* 用于扩展 Hvigor 功能的自定义插件。 */
}