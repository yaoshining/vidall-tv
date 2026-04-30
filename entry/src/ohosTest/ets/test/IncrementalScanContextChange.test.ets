import { describe, it, expect } from '@ohos/hypium';
import {
  classifyVideoScrapeTarget,
  hasSeasonSiblingDirectory,
  createVideoScrapeContext,
  VideoScrapeContext
} from '../../main/ets/utils/VideoScannerUtil';
import {
  MediaTypeClassification,
  isWeakSemanticTitleText
} from '../../main/ets/lib/MediaTypeClassifier';

/**
 * 测试场景：增量扫描时扫描上下文变化的处理
 * 复现 #191 真机验收失败：用户先扫描了弱语义文件（纯数字），
 * 后添加季目录兄弟后重新扫描，文件应被重新分类为 TV
 */
export default function incrementalScanContextChangeTest() {
  describe('IncrementalScanContextChange', () => {
    it('纯数字文件名为弱语义', () => {
      expect(isWeakSemanticTitleText('19')).assertTrue();
      expect(isWeakSemanticTitleText('20')).assertTrue();
      expect(isWeakSemanticTitleText('22')).assertTrue();
    });

    it('检测到季目录兄弟时应返回true', () => {
      const childDirs1 = ['第一季', '其他目录'];
      expect(hasSeasonSiblingDirectory(childDirs1)).assertTrue();

      const childDirs2 = ['Season 1', 'extras'];
      expect(hasSeasonSiblingDirectory(childDirs2)).assertTrue();

      const childDirs3 = ['S01', 'S02'];
      expect(hasSeasonSiblingDirectory(childDirs3)).assertTrue();
    });

    it('无季目录兄弟时应返回false', () => {
      const childDirs = ['其他目录', '特典'];
      expect(hasSeasonSiblingDirectory(childDirs)).assertFalse();
    });

    it('无季目录兄弟时纯数字文件应分类为unknown', () => {
      const context: VideoScrapeContext = {
        seasonSiblingDetected: false
      };
      const result = classifyVideoScrapeTarget(
        '19.mp4',
        '/蜜语纪/19.mp4',
        context
      );
      expect(result.mediaType).assertEqual('unknown');
      expect(result.reason).assertEqual('insufficient-evidence');
    });

    it('有季目录兄弟时纯数字文件应分类为tv', () => {
      const context: VideoScrapeContext = {
        seasonSiblingDetected: true
      };
      const result = classifyVideoScrapeTarget(
        '19.mp4',
        '/蜜语纪/19.mp4',
        context
      );
      expect(result.mediaType).assertEqual('tv');
      expect(result.reason).assertEqual('season-sibling-detected');
    });

    it('扫描上下文应正确传递seasonSiblingDetected', () => {
      const rootPath = '/storage/蜜语纪';
      const depth = 0;

      // 场景1：无季目录兄弟
      const contextWithout = createVideoScrapeContext(rootPath, depth, false);
      expect(contextWithout.seasonSiblingDetected).assertFalse();
      expect(contextWithout.seriesHint).assertEqual('蜜语纪');

      // 场景2：有季目录兄弟
      const contextWith = createVideoScrapeContext(rootPath, depth, true);
      expect(contextWith.seasonSiblingDetected).assertTrue();
      expect(contextWith.seriesHint).assertEqual('蜜语纪');
    });

    it('深度>0时不应设置seriesHint', () => {
      const rootPath = '/storage/蜜语纪';
      const depth = 1;

      const context = createVideoScrapeContext(rootPath, depth, true);
      expect(context.seasonSiblingDetected).assertTrue();
      expect(context.seriesHint).assertUndefined();
    });

    it('真实场景模拟：扫描上下文变化前后的分类结果应不同', () => {
      // 模拟首次扫描：蜜语纪/ 只有 19.mp4-22.mp4（无季目录）
      const contextBefore: VideoScrapeContext = {
        seasonSiblingDetected: false
      };
      const resultBefore = classifyVideoScrapeTarget(
        '19.mp4',
        '/蜜语纪/19.mp4',
        contextBefore
      );
      expect(resultBefore.mediaType).assertEqual('unknown');

      // 模拟二次扫描：蜜语纪/ 现在有 第一季/ 子目录
      const contextAfter: VideoScrapeContext = {
        seasonSiblingDetected: true
      };
      const resultAfter = classifyVideoScrapeTarget(
        '19.mp4',
        '/蜜语纪/19.mp4',
        contextAfter
      );
      expect(resultAfter.mediaType).assertEqual('tv');

      // 关键断言：即使文件本身未变化，分类结果应该不同
      expect(resultBefore.mediaType).assertNotEqual(resultAfter.mediaType);
    });
  });
}
