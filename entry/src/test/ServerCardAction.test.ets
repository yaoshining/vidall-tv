import { describe, it, expect } from '@ohos/hypium';
import {
  resolveCardBehavior,
  isDirectPlayContextValid
} from '../main/ets/services/sourceAdapter/ServerCardAction';
import { VideoServer, VideoServerType } from '../main/ets/db/models/VideoServerEntity';

function makeServer(): VideoServer {
  const server: VideoServer = {
    id: 1,
    name: 'test-server',
    type: VideoServerType.JELLYFIN,
    configJson: '{}',
    createdAt: 0
  };
  return server;
}

export default function serverCardActionTest() {
  describe('resolveCardBehavior - 卡片互斥契约', () => {
    it('继续观看：无播放按钮，整卡直播放', 0, () => {
      const b = resolveCardBehavior('continue-watching');
      expect(b.showPlayButton).assertFalse();
      expect(b.itemClick).assertEqual('direct-play');
      expect(b.playClick).assertEqual('none');
    });

    it('接下来：主体进详情，播放按钮直播放（互斥）', 0, () => {
      const b = resolveCardBehavior('next-up');
      expect(b.showPlayButton).assertTrue();
      expect(b.itemClick).assertEqual('open-detail');
      expect(b.playClick).assertEqual('direct-play');
    });

    it('最近添加：主体进详情，播放按钮直播放（互斥）', 0, () => {
      const b = resolveCardBehavior('recently-added');
      expect(b.showPlayButton).assertTrue();
      expect(b.itemClick).assertEqual('open-detail');
      expect(b.playClick).assertEqual('direct-play');
    });

    it('媒体库：主体进媒体库，无播放按钮', 0, () => {
      const b = resolveCardBehavior('library');
      expect(b.showPlayButton).assertFalse();
      expect(b.itemClick).assertEqual('open-detail');
      expect(b.playClick).assertEqual('none');
    });
  });

  describe('isDirectPlayContextValid - 直播放降级校验', () => {
    it('服务器 ID 缺失时降级（不可直播放）', 0, () => {
      expect(isDirectPlayContextValid(undefined, makeServer())).assertFalse();
    });

    it('服务器实例不存在时降级', 0, () => {
      expect(isDirectPlayContextValid(1, null)).assertFalse();
    });

    it('服务器 ID 与实例均有效时可直播放', 0, () => {
      expect(isDirectPlayContextValid(1, makeServer())).assertTrue();
    });
  });
}
