import { describe, it } from '@ohos/hypium';
import { exitDuringRouting, releaseBeforeNewInit, lateAudioSwitch, reenterAfterRelease } from './PlayerLifecycleCases';
export default function playerLifecycleTest(): void {
  describe('PlayerLifecycle', () => {
    it('路由等待中退出', 0, exitDuringRouting);
    it('释放晚于新初始化', 0, releaseBeforeNewInit);
    it('旧音轨切换迟到', 0, lateAudioSwitch);
    it('退出后重新进入', 0, reenterAfterRelease);
  });
}
