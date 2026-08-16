import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { subhubSecretPlugin } from './hvigor/subhub-secret-plugin';

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [subhubSecretPlugin()]       /* 用于扩展 Hvigor 功能的自定义插件。 */
}