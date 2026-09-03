import { describe, it, expect } from '@ohos/hypium';
import {
  classifyVideoScrapeTarget,
  createVideoScrapeContext,
  extractEpisodeNumberFromWeakSemanticFileName,
  hasSeasonSiblingDirectory
} from '../main/ets/utils/VideoScannerHelpers';
import { VideoScrapeContext, ScanProgressCallback, ScanContextInfo, ScanOptions } from '../main/ets/utils/VideoScannerTypes';
import { truncateMiddlePath } from '../main/ets/utils/PathDisplayUtil';

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

    it('ScanProgressCallback 回调接收 completed 与 total 计数', 0, () => {
      const received: number[] = [];
      const callback: ScanProgressCallback = (completed: number, total: number): void => {
        received.push(completed);
        received.push(total);
      };
      callback(0, 5);
      callback(3, 5);
      callback(5, 5);
      expect(received.length).assertEqual(6);
      expect(received[0]).assertEqual(0);
      expect(received[1]).assertEqual(5);
      expect(received[2]).assertEqual(3);
      expect(received[3]).assertEqual(5);
      expect(received[4]).assertEqual(5);
      expect(received[5]).assertEqual(5);
    });

    it('ScanOptions 接受可选的 onScanProgress', 0, () => {
      const callback: ScanProgressCallback = (_completed: number, _total: number, _context?: ScanContextInfo): void => {};
      const options: ScanOptions = {
        maxDepth: 5,
        mode: 'incremental',
        onScanProgress: callback
      };
      expect(options.onScanProgress !== undefined).assertTrue();
      const plainOptions: ScanOptions = {
        maxDepth: 5,
        mode: 'incremental'
      };
      expect(plainOptions.onScanProgress === undefined).assertTrue();
    });

    it('truncateMiddlePath 对短路径原样返回', 0, () => {
      expect(truncateMiddlePath('/short/path', 50)).assertEqual('/short/path');
    });

    it('truncateMiddlePath 长路径保留头部两段与尾部', 0, () => {
      const longPath = '/根文件夹/爷文件夹/子目录A/子目录B/abc.mp4';
      const result = truncateMiddlePath(longPath, 25);
      expect(result.startsWith('/根文件夹/爷文件夹/…/')).assertTrue();
      expect(result.endsWith('abc.mp4')).assertTrue();
    });

    it('truncateMiddlePath 头部仍过长时缩减为一段', 0, () => {
      const longPath = '/很长的文件夹名称AAAA/中间目录/子目录B/abc.mp4';
      const result = truncateMiddlePath(longPath, 24);
      expect(result.startsWith('/很长的文件夹名称AAAA/…/')).assertTrue();
      expect(result.endsWith('abc.mp4')).assertTrue();
    });

    it('truncateMiddlePath 超长时截断尾部', 0, () => {
      const longPath = '/a/b/c/d/e/非常非常长的文件名称超过限制.mp4';
      const result = truncateMiddlePath(longPath, 15);
      expect(result.startsWith('…')).assertTrue();
    });

    it('truncateMiddlePath 空输入返回空串', 0, () => {
      expect(truncateMiddlePath('', 10)).assertEqual('');
    });
  });
}
