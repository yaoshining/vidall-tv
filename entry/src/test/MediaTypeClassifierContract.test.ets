import { describe, it, expect } from '@ohos/hypium';
import {
  FileNameSemanticInfo,
  MediaTypeClassification,
  MediaTypeClassificationSignal,
  buildMediaTypeClassificationInput,
  classifyMediaType,
  createFileNameSemanticInfo,
  createMediaTypeClassificationResult,
  extractSeriesHintFromFilePath,
  extractSeasonNumberFromDirectoryName,
  stripSeasonSuffixFromDirectoryName,
  isSeasonDirectorySegment
} from '../main/ets/lib/MediaTypeClassifier';
import { parseFileName, resolveMovieSearchTerms } from '../main/ets/lib/ScrapeClient';
import { classifyVideoScrapeTarget } from '../main/ets/utils/VideoScannerHelpers';

interface WeakSemanticRegressionSample {
  name: string;
  fileName: string;
  filePath: string;
  expectedMediaType: MediaTypeClassification;
  expectedReason?: string;
}

// 新增误判样本时，先补到这里，再调整分类规则。
const weakSemanticRegressionSamples: WeakSemanticRegressionSample[] = [
  {
    name: '弱语义剧集样本：数字文件名依赖电视剧目录语义',
    fileName: '19 4K.mp4',
    filePath: '/电视剧/狂飙/Season 1/19 4K.mp4',
    expectedMediaType: 'tv'
  },
  {
    name: '弱语义电影样本：电影目录词可提供 movie 证据',
    fileName: 'Dune.2021.2160p.mkv',
    filePath: '/电影/科幻/Dune.2021.2160p.mkv',
    expectedMediaType: 'movie'
  },
  {
    name: '弱语义电影样本：父目录片名可兜底为 movie',
    fileName: '4K.mp4',
    filePath: '/Videos/Movies/穿普拉达的女王2/4K.mp4',
    expectedMediaType: 'movie',
    expectedReason: 'weak-filename-parent-directory-fallback'
  },
  {
    name: '弱语义 unknown 样本：无足够路径线索时保持保守',
    fileName: '22 4K.mp4',
    filePath: '/下载/未整理/22 4K.mp4',
    expectedMediaType: 'unknown',
    expectedReason: 'insufficient-evidence'
  }
];

export default function mediaTypeClassifierContractTest() {
  describe('MediaTypeClassifier contract', () => {
    it('should capture filename and ancestor path context for classification input', 0, () => {
      const fileNameInfo: FileNameSemanticInfo = {
        title: '19',
        language: 'zh-CN'
      };

      const input = buildMediaTypeClassificationInput(
        '19 4K.mp4',
        '/电视剧/狂飙/Season 1/19 4K.mp4',
        fileNameInfo
      );

      expect(input.fileName).assertEqual('19 4K.mp4');
      expect(input.filePath).assertEqual('/电视剧/狂飙/Season 1/19 4K.mp4');
      expect(input.parentDirectoryName).assertEqual('Season 1');
      expect(input.ancestorDirectoryNames.length).assertEqual(2);
      expect(input.ancestorDirectoryNames[0]).assertEqual('电视剧');
      expect(input.ancestorDirectoryNames[1]).assertEqual('狂飙');
      expect(input.pathSegments.length).assertEqual(3);
      expect(input.pathSegments[0]).assertEqual('电视剧');
      expect(input.pathSegments[2]).assertEqual('Season 1');
      expect(input.fileNameInfo?.title).assertEqual('19');
      expect(input.fileNameInfo?.language).assertEqual('zh-CN');
    });

    it('should preserve unknown classification result reason and signals', 0, () => {
      const signal: MediaTypeClassificationSignal = {
        source: 'path-semantics',
        value: '电视剧',
        detail: 'ancestor-directory',
        weight: 80
      };

      const result = createMediaTypeClassificationResult(
        'unknown',
        [signal],
        'insufficient-evidence'
      );

      expect(result.mediaType).assertEqual('unknown');
      expect(result.reason).assertEqual('insufficient-evidence');
      expect(result.signals.length).assertEqual(1);
      expect(result.signals[0].source).assertEqual('path-semantics');
      expect(result.signals[0].value).assertEqual('电视剧');
      expect(result.signals[0].detail).assertEqual('ancestor-directory');
      expect(result.signals[0].weight).assertEqual(80);
    });

    it('should classify explicit season episode filenames as tv before path semantics', 0, () => {
      const parsed = parseFileName('Breaking.Bad.S02E03.Bit.by.a.Dead.Bee.mkv');
      const fileNameInfo = createFileNameSemanticInfo(
        parsed.title,
        parsed.language,
        parsed.mediaType,
        parsed.seasonNumber,
        parsed.episodeNumber,
        parsed.year
      );
      const classification = classifyMediaType(
        buildMediaTypeClassificationInput(
          'Breaking.Bad.S02E03.Bit.by.a.Dead.Bee.mkv',
          '/下载/未整理/Breaking.Bad.S02E03.Bit.by.a.Dead.Bee.mkv',
          fileNameInfo
        )
      );

      expect(classification.mediaType).assertEqual('tv');
      expect(classification.reason).assertEqual('season-episode-pattern');
      expect(classification.signals.length).assertEqual(1);
      expect(classification.signals[0].source).assertEqual('file-name');
    });

    it('should extract series hint from the nearest non-season directory', 0, () => {
      const seriesHint = extractSeriesHintFromFilePath('/电视剧/狂飙/Season 1/19 4K.mp4');
      expect(seriesHint).assertEqual('狂飙');
    });

    it('should classify weak semantic regression samples consistently', 0, () => {
      weakSemanticRegressionSamples.forEach((sample: WeakSemanticRegressionSample) => {
        const parsed = parseFileName(sample.fileName);
        const fileNameInfo = createFileNameSemanticInfo(
          parsed.title,
          parsed.language,
          parsed.mediaType,
          parsed.seasonNumber,
          parsed.episodeNumber,
          parsed.year
        );
        const classification = classifyMediaType(
          buildMediaTypeClassificationInput(
            sample.fileName,
            sample.filePath,
            fileNameInfo
          )
        );

        expect(classification.mediaType).assertEqual(sample.expectedMediaType);
        if (sample.expectedReason !== undefined) {
          expect(classification.reason).assertEqual(sample.expectedReason);
        }
      });
    });

    it('should classify root weak semantic episode as tv when season sibling is detected', 0, () => {
      const classification = classifyVideoScrapeTarget(
        '19.mp4',
        '/蜜语纪/19.mp4',
        { seasonSiblingDetected: true }
      );

      expect(classification.mediaType).assertEqual('tv');
      expect(classification.reason).assertEqual('season-sibling-detected');
      expect(classification.signals.length > 0).assertTrue();
      expect(classification.signals[classification.signals.length - 1].detail).assertEqual('path:season-sibling-detected');
    });

    it('should keep weak semantic episode unknown when no season sibling is detected', 0, () => {
      const explicitFalseClassification = classifyVideoScrapeTarget(
        '19.mp4',
        '/电影合集/19.mp4',
        { seasonSiblingDetected: false }
      );
      const omittedClassification = classifyVideoScrapeTarget('19.mp4', '/电影合集/19.mp4');

      expect(explicitFalseClassification.mediaType).assertEqual('unknown');
      expect(explicitFalseClassification.reason).assertEqual('insufficient-evidence');
      expect(omittedClassification.mediaType).assertEqual('unknown');
      expect(omittedClassification.reason).assertEqual('insufficient-evidence');
    });

    it('电影路径下弱语义文件名用父目录片名兜底为 movie', 0, () => {
      const classification = classifyVideoScrapeTarget(
        '4K.mp4',
        '/Videos/Movies/穿普拉达的女王2/4K.mp4'
      );

      expect(classification.mediaType).assertEqual('movie');
      expect(classification.reason).assertEqual('weak-filename-parent-directory-fallback');
      expect(classification.fallbackTitle).assertEqual('穿普拉达的女王2');
    });

    it('父目录为通用电影关键词段时弱语义文件名保持 unknown', 0, () => {
      const classification = classifyVideoScrapeTarget('4K.mp4', '/电影合集/4K.mp4');

      expect(classification.mediaType).assertEqual('unknown');
      expect(classification.reason).assertEqual('insufficient-evidence');
      expect(classification.fallbackTitle).assertUndefined();
    });

    it('父目录为季目录段时弱语义文件名不兜底为 movie', 0, () => {
      const classification = classifyVideoScrapeTarget(
        '4K.mp4',
        '/电影/长剧第二季/4K.mp4'
      );

      expect(classification.mediaType).assertEqual('unknown');
      expect(classification.reason).assertEqual('insufficient-evidence');
      expect(classification.fallbackTitle).assertUndefined();
    });

    it('兜底标题末尾形如 .2021 的年份不被当扩展名丢失', 0, () => {
      const parsed = parseFileName('4K.mp4');
      const terms = resolveMovieSearchTerms(parsed, 'Dune.2021');

      expect(terms.title).assertEqual('Dune');
      expect(terms.year).assertEqual(2021);
    });

    // ─── #254 中文季号后缀目录名 ───

    it('should recognize Chinese season suffix directory as season directory', 0, () => {
      expect(isSeasonDirectorySegment('御赐小仵作第二季')).assertTrue();
      expect(isSeasonDirectorySegment('庆余年第二部')).assertTrue();
      expect(isSeasonDirectorySegment('我的剧第3季')).assertTrue();
      expect(isSeasonDirectorySegment('御赐小仵作')).assertFalse();
    });

    it('should extract season number from Chinese season suffix directory names', 0, () => {
      expect(extractSeasonNumberFromDirectoryName('御赐小仵作第二季')).assertEqual(2);
      expect(extractSeasonNumberFromDirectoryName('庆余年第二部')).assertEqual(2);
      expect(extractSeasonNumberFromDirectoryName('我的剧第3季')).assertEqual(3);
      expect(extractSeasonNumberFromDirectoryName('我的剧第三季')).assertEqual(3);
      expect(extractSeasonNumberFromDirectoryName('第二季')).assertEqual(2);
      expect(extractSeasonNumberFromDirectoryName('Season 2')).assertEqual(2);
      expect(extractSeasonNumberFromDirectoryName('S02')).assertEqual(2);
      expect(extractSeasonNumberFromDirectoryName('御赐小仵作')).assertEqual(undefined);
    });

    it('should strip Chinese season suffix to extract series title from directory name', 0, () => {
      expect(stripSeasonSuffixFromDirectoryName('御赐小仵作第二季')).assertEqual('御赐小仵作');
      expect(stripSeasonSuffixFromDirectoryName('庆余年第二部')).assertEqual('庆余年');
      expect(stripSeasonSuffixFromDirectoryName('我的剧第3季')).assertEqual('我的剧');
      expect(stripSeasonSuffixFromDirectoryName('第二季')).assertEqual(undefined);
      expect(stripSeasonSuffixFromDirectoryName('御赐小仵作')).assertEqual(undefined);
    });

    it('should extract correct series hint from Chinese season suffix directory path', 0, () => {
      // #254: "御赐小仵作第二季" 应提取出 "御赐小仵作" 而非整个目录名
      const hint = extractSeriesHintFromFilePath('/Videos/TV Series/御赐小仵作第二季/01.mp4');
      expect(hint).assertEqual('御赐小仵作');
    });

    it('should still extract series hint correctly for standard Season N directories', 0, () => {
      const hint = extractSeriesHintFromFilePath('/电视剧/狂飙/Season 1/19 4K.mp4');
      expect(hint).assertEqual('狂飙');
    });

    // ─── 括号包裹中文季号后缀目录名（如"艾米丽在巴黎(第五季)"） ───

    it('should recognize bracketed Chinese season suffix directory as season directory', 0, () => {
      expect(isSeasonDirectorySegment('艾米丽在巴黎(第五季)')).assertTrue();
      expect(isSeasonDirectorySegment('艾米丽在巴黎（第5季）')).assertTrue();
      expect(isSeasonDirectorySegment('艾米丽在巴黎')).assertFalse();
    });

    it('should extract season number from bracketed Chinese season suffix directory names', 0, () => {
      expect(extractSeasonNumberFromDirectoryName('艾米丽在巴黎(第五季)')).assertEqual(5);
      expect(extractSeasonNumberFromDirectoryName('艾米丽在巴黎（第5季）')).assertEqual(5);
      expect(extractSeasonNumberFromDirectoryName('艾米丽在巴黎(第三季)')).assertEqual(3);
    });

    it('should strip bracketed Chinese season suffix to extract series title', 0, () => {
      expect(stripSeasonSuffixFromDirectoryName('艾米丽在巴黎(第五季)')).assertEqual('艾米丽在巴黎');
      expect(stripSeasonSuffixFromDirectoryName('艾米丽在巴黎（第5季）')).assertEqual('艾米丽在巴黎');
      expect(stripSeasonSuffixFromDirectoryName('艾米丽在巴黎')).assertEqual(undefined);
    });

    it('should extract series hint from bracketed Chinese season suffix directory path', 0, () => {
      const hint = extractSeriesHintFromFilePath('/Videos/TV Series/艾米丽在巴黎(第五季)/S05E01.mp4');
      expect(hint).assertEqual('艾米丽在巴黎');
    });

    // ─── #254 中文大季号回归（CodeRabbit 评审） ───

    it('should parse Chinese season numbers beyond 29', 0, () => {
      expect(extractSeasonNumberFromDirectoryName('长剧第三十季')).assertEqual(30);
      expect(extractSeasonNumberFromDirectoryName('长剧第三十一季')).assertEqual(31);
      expect(extractSeasonNumberFromDirectoryName('长剧第五十季')).assertEqual(50);
      expect(extractSeasonNumberFromDirectoryName('长剧第九十九季')).assertEqual(99);
    });

    it('should parse Chinese season numbers at hundred level', 0, () => {
      expect(extractSeasonNumberFromDirectoryName('超级剧第一百季')).assertEqual(100);
      expect(extractSeasonNumberFromDirectoryName('超级剧第一百零三季')).assertEqual(103);
      expect(extractSeasonNumberFromDirectoryName('超级剧第一百二十季')).assertEqual(120);
    });

    it('should strip season suffix for large Chinese season numbers', 0, () => {
      expect(stripSeasonSuffixFromDirectoryName('长剧第三十季')).assertEqual('长剧');
      expect(stripSeasonSuffixFromDirectoryName('超级剧第一百季')).assertEqual('超级剧');
    });
  });
}
