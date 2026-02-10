import { describe, it, TestType } from '@ohos/hypium'
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sleep } from '@ibestservices/ibest-ui/src/main/ets/utils/utils';

export default function fileOperationsTest() {
  describe('localFileTest', () => {
    it('read test', TestType.FUNCTION, async () => {
      try {
        // let uri = 'file://media/Photo/16/VID_1770555247_008/SVID_20260208_205227_1.mp4'
        let url = 'https://vjs.zencdn.net/v/oceans.mp4'
        let avPlayer = await media.createAVPlayer();
        avPlayer.url = url
        await avPlayer.prepare()
        await avPlayer.play()
        await avPlayer.getPlaybackInfo()
        await sleep(5000)
      } catch (error) {
        hilog.error(1, "com.yao.vidall.test",
          `initPlayer initPlayer, code is ${error.code}, message is ${error.message}`);
      }
    })
  })
}