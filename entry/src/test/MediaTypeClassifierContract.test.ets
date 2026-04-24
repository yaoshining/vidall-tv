import { describe, it, expect } from '@ohos/hypium';
import {
  FileNameSemanticInfo,
  MediaTypeClassification,
  MediaTypeClassificationSignal,
  buildMediaTypeClassificationInput,
  classifyMediaType,
  createFileNameSemanticInfo,
  createMediaTypeClassificationResult,
  extractSeriesHintFromFilePath
} from '../main/ets/lib/MediaTypeClassifier';
import { parseFileName } from '../main/ets/lib/ScrapeClient';

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
  });
}
