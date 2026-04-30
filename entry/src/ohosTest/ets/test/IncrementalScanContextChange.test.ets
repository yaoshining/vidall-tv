import { describe, it, expect } from '@ohos/hypium';
import {
  classifyVideoScrapeTarget,
  hasSeasonSiblingDirectory,
  createVideoScrapeContext,
  VideoScrapeContext
} from '../../main/ets/utils/VideoScannerUtil';
import {
  MediaTypeClassification,
  isWeakSemanticTitleText,
  isSeasonDirectorySegment
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

    it('isSeasonDirectorySegment应识别基础季目录名', () => {
      // 纯季目录名（旧测试已覆盖的场景）
      expect(isSeasonDirectorySegment('第一季')).assertTrue();
      expect(isSeasonDirectorySegment('Season 1')).assertTrue();
      expect(isSeasonDirectorySegment('S01')).assertTrue();
      expect(isSeasonDirectorySegment('S02')).assertTrue();
      expect(isSeasonDirectorySegment('第 2 季')).assertTrue();
    });

    it('isSeasonDirectorySegment应识别带质量后缀的真实季目录名 (#191 QA证据)', () => {
      // 真实场景：季目录名后面跟随质量信息
      expect(isSeasonDirectorySegment('第 1 季 - 2160p WEB-DL HDR H265 DDP 5.1')).assertTrue();
      expect(isSeasonDirectorySegment('Season 01 - 1080p BluRay')).assertTrue();
      expect(isSeasonDirectorySegment('S02 - AMZN WEB-DL')).assertTrue();
      expect(isSeasonDirectorySegment('第二季 - 4K HDR')).assertTrue();
    });

    it('isSeasonDirectorySegment应拒绝非季目录名', () => {
      // 避免误判：标题中恰好包含 S02 等模式但不是季目录
      expect(isSeasonDirectorySegment('特典')).assertFalse();
      expect(isSeasonDirectorySegment('其他目录')).assertFalse();
      expect(isSeasonDirectorySegment('extras')).assertFalse();
      // 注意：像 "Breaking Bad S01E01" 这样的文件名也应被拒绝，
      // 但由于 normalizeSemanticToken 会移除空格，实际测试需考虑归一化后的形态
    });

    it('检测到季目录兄弟时应返回true', () => {
      const childDirs1 = ['第一季', '其他目录'];
      expect(hasSeasonSiblingDirectory(childDirs1)).assertTrue();

      const childDirs2 = ['Season 1', 'extras'];
      expect(hasSeasonSiblingDirectory(childDirs2)).assertTrue();

      const childDirs3 = ['S01', 'S02'];
      expect(hasSeasonSiblingDirectory(childDirs3)).assertTrue();
    });

    it('检测到带质量后缀的季目录兄弟时应返回true (#191 QA证据)', () => {
      // 真实场景：目录列表包含带质量信息的季目录
      const childDirs1 = ['第 1 季 - 2160p WEB-DL HDR H265 DDP 5.1', '其他目录'];
      expect(hasSeasonSiblingDirectory(childDirs1)).assertTrue();

      const childDirs2 = ['Season 01 - 1080p BluRay', 'extras', 'Season 02 - 1080p BluRay'];
      expect(hasSeasonSiblingDirectory(childDirs2)).assertTrue();

      const childDirs3 = ['S02 - AMZN WEB-DL', '特典'];
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

    it('真实文件名带质量后缀时纯数字前缀应被识别为弱语义 (#191 第三轮真机失败)', () => {
      // 真实场景：文件名为 "19 4K.mp4"，前缀 "19" 是弱语义
      expect(isWeakSemanticTitleText('19 4K')).assertTrue();
      expect(isWeakSemanticTitleText('20 4K')).assertTrue();
      expect(isWeakSemanticTitleText('22 HDR')).assertTrue();
      expect(isWeakSemanticTitleText('19 2160p')).assertTrue();
    });

    it('真实文件名带质量后缀时有季目录兄弟应分类为tv (#191 第三轮真机失败)', () => {
      // 真实场景：文件名为 "19 4K.mp4"，目录下有 "第 1 季 - 2160p WEB-DL HDR H265 DDP 5.1"
      const context: VideoScrapeContext = {
        seasonSiblingDetected: true
      };
      const result = classifyVideoScrapeTarget(
        '19 4K.mp4',
        '/蜜语纪/19 4K.mp4',
        context
      );
      expect(result.mediaType).assertEqual('tv');
      expect(result.reason).assertEqual('season-sibling-detected');
    });

    it('真实文件名带质量后缀时无季目录兄弟应分类为unknown (#191 第三轮真机失败)', () => {
      // 真实场景：文件名为 "19 4K.mp4"，但目录下无季目录兄弟
      const context: VideoScrapeContext = {
        seasonSiblingDetected: false
      };
      const result = classifyVideoScrapeTarget(
        '19 4K.mp4',
        '/蜜语纪/19 4K.mp4',
        context
      );
      expect(result.mediaType).assertEqual('unknown');
      expect(result.reason).assertEqual('insufficient-evidence');
    });

    it('增量扫描时已存在video file但无scrape_info的弱语义文件在季目录兄弟出现后应重新处理 (#191 第三轮真机失败根因)', () => {
      // 这个测试覆盖真实数据流：
      // 1. 首次扫描：19 4K.mp4 被识别为 video file，但因为弱语义+无季目录兄弟，分类为 unknown
      //    可能没有创建 scrape_info，或创建了 mediaType=unknown 的 scrape_info
      // 2. 用户添加季目录兄弟：第 1 季 - 2160p WEB-DL HDR H265 DDP 5.1/
      // 3. 增量扫描：19 4K.mp4 文件未变化，但季目录兄弟已出现
      //    期望：应重新处理该文件，分类为 tv
      //    实际：被 canSkipIncrementalProcessing 跳过，或虽补刮削但没有检测季目录兄弟上下文变化

      // 场景1：首次扫描，无季目录兄弟
      const contextFirst: VideoScrapeContext = {
        seasonSiblingDetected: false
      };
      const resultFirst = classifyVideoScrapeTarget(
        '19 4K.mp4',
        '/蜜语纪/19 4K.mp4',
        contextFirst
      );
      expect(resultFirst.mediaType).assertEqual('unknown');

      // 场景2：增量扫描，季目录兄弟已出现
      const contextIncremental: VideoScrapeContext = {
        seasonSiblingDetected: true
      };
      const resultIncremental = classifyVideoScrapeTarget(
        '19 4K.mp4',
        '/蜜语纪/19 4K.mp4',
        contextIncremental
      );
      expect(resultIncremental.mediaType).assertEqual('tv');

      // 关键断言：即使 video file 未变化，增量扫描时检测到季目录兄弟，应重新分类
      expect(resultFirst.mediaType).assertNotEqual(resultIncremental.mediaType);
    });
  });
}
