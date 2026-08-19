import { describe, it, expect } from '@ohos/hypium';
import { VideoServerTypeLabels, VideoServerType } from '../main/ets/db/models/VideoServerEntity';
import { videoServerTypeLabel } from '../main/ets/stores/servers/VideoServerModel';

export default function videoServerLabelsTest() {
  describe('影视服务器类型标签', () => {
    it('Jellyfin 标签', 0, () => {
      expect(VideoServerTypeLabels.getLabel(VideoServerType.JELLYFIN)).assertEqual('Jellyfin');
      expect(videoServerTypeLabel(VideoServerType.JELLYFIN)).assertEqual('Jellyfin');
    });

    it('Emby 标签', 0, () => {
      expect(VideoServerTypeLabels.getLabel(VideoServerType.EMBY)).assertEqual('Emby');
      expect(videoServerTypeLabel(VideoServerType.EMBY)).assertEqual('Emby');
    });

    it('Plex 标签', 0, () => {
      expect(VideoServerTypeLabels.getLabel(VideoServerType.PLEX)).assertEqual('Plex');
      expect(videoServerTypeLabel(VideoServerType.PLEX)).assertEqual('Plex');
    });

    it('未知类型回退', 0, () => {
      expect(VideoServerTypeLabels.getLabel('unknown' as VideoServerType)).assertEqual('未知');
      expect(videoServerTypeLabel('unknown' as VideoServerType)).assertEqual('未知');
    });
  });
}
