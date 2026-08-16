import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { subhubSecretPlugin } from './hvigor/subhub-secret-plugin';

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [subhubSecretPlugin()]       /* Custom plugin to extend the functionality of Hvigor. */
}