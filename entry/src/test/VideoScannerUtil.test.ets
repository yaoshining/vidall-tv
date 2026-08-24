import { describe, it, expect } from '@ohos/hypium';
import {
  classifyVideoScrapeTarget,
  createVideoScrapeContext,
  extractEpisodeNumberFromWeakSemanticFileName,
  hasSeasonSiblingDirectory
} from '../main/ets/utils/VideoScannerHelpers';
import { VideoScrapeContext } from '../main/ets/utils/VideoScannerTypes';

export default function videoScannerUtilTest() {
  describe('VideoScannerUtil mixed directory scan helpers', () => {
    it('should detect season sibling directories from current directory entries', 0, () => {
      expect(hasSeasonSiblingDirectory(['第一季', '幕后花絮'])).assertTrue();
      expect(hasSeasonSiblingDirectory(['Season 1', 'Extras'])).assertTrue();
      expect(hasSeasonSiblingDirectory(['电影合集', '花絮'])).assertFalse();
    });

    it('should pass season sibling context and root series hint to root weak semantic files', 0, () => {
      const context: VideoScrapeContext = createVideoScrapeContext('/蜜语纪', 0, true);
      const classification = classifyVideoScrapeTarget('19.mp4', '/蜜语纪/19.mp4', context);

      expect(context.seasonSiblingDetected).assertTrue();
      expect(context.seriesHint).assertEqual('蜜语纪');
      expect(classification.mediaType).assertEqual('tv');
      expect(classification.reason).assertEqual('season-sibling-detected');
    });

    it('should not apply root mixed directory context to deeper layers without local season siblings', 0, () => {
      const context: VideoScrapeContext = createVideoScrapeContext('/蜜语纪', 1, false);
      const classification = classifyVideoScrapeTarget('19.mp4', '/蜜语纪/特典/19.mp4', context);

      expect(context.seasonSiblingDetected).assertFalse();
      expect(context.seriesHint === undefined).assertTrue();
      expect(classification.mediaType).assertEqual('unknown');
    });

    it('should classify NAS separated episode markers as TV', 0, () => {
      const context: VideoScrapeContext = createVideoScrapeContext('/御赐小仵作', 1, false);
      const classification = classifyVideoScrapeTarget(
        'S01 4K EP 07.mkv',
        '/御赐小仵作/S01 4K EP 07.mkv',
        context
      );

      expect(classification.mediaType).assertEqual('tv');
    });

    it('should extract episode number from weak semantic filenames with various separators', 0, () => {
      expect(extractEpisodeNumberFromWeakSemanticFileName('01~4K.mp4')).assertEqual(1);
      expect(extractEpisodeNumberFromWeakSemanticFileName('01_4K.mp4')).assertEqual(1);
      expect(extractEpisodeNumberFromWeakSemanticFileName('01-4K.mp4')).assertEqual(1);
      expect(extractEpisodeNumberFromWeakSemanticFileName('19 4K.mp4')).assertEqual(19);
      expect(extractEpisodeNumberFromWeakSemanticFileName('19.mp4')).assertEqual(19);
    });

    it('should not treat a year-only weak semantic filename as an episode number', 0, () => {
      expect(extractEpisodeNumberFromWeakSemanticFileName('2024.mp4')).assertEqual(undefined);
    });

    it('should classify tilde-separated weak semantic file in TV Series path as tv', 0, () => {
      const context: VideoScrapeContext = createVideoScrapeContext('/Videos/TV Series/重器', 0, false);
      const classification = classifyVideoScrapeTarget(
        '01~4K.mp4',
        '/Videos/TV Series/重器/01~4K.mp4',
        context
      );

      expect(classification.mediaType).assertEqual('tv');
    });
  });
}
