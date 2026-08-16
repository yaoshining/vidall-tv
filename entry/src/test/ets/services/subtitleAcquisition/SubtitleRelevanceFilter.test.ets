/**
 * Test suite for SubtitleRelevanceFilter（片名相关性过滤）
 * Spec: subhub-subtitle-provider
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeForMatch,
  isTitleRelevant,
  filterByTitleRelevance
} from '../../../../main/ets/services/subtitleAcquisition/providers/SubtitleRelevanceFilter';
import { SubtitleSearchResult } from '../../../../main/ets/services/subtitleAcquisition/SubtitleAcquisitionTypes';

export default function subtitleRelevanceFilterTest() {
  describe('normalizeForMatch', () => {
    it('strips dots, case and punctuation', 0, () => {
      expect(normalizeForMatch('The.Lychee.Road.2025.1080p.WEB-DL.x264.AAC-CHS.ass'))
        .assertEqual('thelycheeroad20251080pwebdlx264aacchsass');
    });

    it('keeps CJK characters', 0, () => {
      expect(normalizeForMatch('长安的荔枝.ass')).assertEqual('长安的荔枝ass');
    });

    it('keeps Korean Hangul characters', 0, () => {
      expect(normalizeForMatch('우씨왕후.E01.srt')).assertEqual('우씨왕후e01srt');
    });
  });

  describe('isTitleRelevant', () => {
    it('matches English query against English release name', 0, () => {
      expect(isTitleRelevant('The.Lychee.Road.2025.1080p.WEB-DL.x264.AAC-CHS.ass', 'The Lychee Road', '长安的荔枝'))
        .assertTrue();
    });

    it('matches Chinese display title against xunlei Chinese release name', 0, () => {
      expect(isTitleRelevant('长安的荔枝.ass', 'The Lychee Road', '长安的荔枝')).assertTrue();
    });

    it('rejects unrelated fuzzy match (Hallow Road)', 0, () => {
      expect(isTitleRelevant('Hallow.Road.2025.1080p.WEB-DL.x264-CHS.srt', 'The Lychee Road', '长安的荔枝'))
        .assertFalse();
    });

    it('rejects unrelated fuzzy match (Ice Road Vengeance)', 0, () => {
      expect(isTitleRelevant('Ice.Road.Vengeance.2025.1080p.WEB.x264-CHS.srt', 'The Lychee Road', '长安的荔枝'))
        .assertFalse();
    });

    it('drops leading "The" so "The Matrix" matches "Matrix.1999"', 0, () => {
      expect(isTitleRelevant('Matrix.1999.1080p.BluRay.x264-CHS.srt', 'The Matrix', '黑客帝国')).assertTrue();
    });

    it('matches Chinese query via whole-string fallback', 0, () => {
      expect(isTitleRelevant('御赐小仵作_02_中文(简体).ass', '御赐小仵作', '御赐小仵作')).assertTrue();
    });

    it('matches Korean query via whole-string fallback', 0, () => {
      expect(isTitleRelevant('우씨왕후KR.E01.srt', '우씨왕후', '于氏王后')).assertTrue();
    });

    it('passes when no reference title is provided', 0, () => {
      expect(isTitleRelevant('Anything.2025.srt', '', undefined)).assertTrue();
    });
  });

  describe('filterByTitleRelevance', () => {
    const r = (fileName: string): SubtitleSearchResult => ({
      subtitleId: fileName,
      source: 'opensubtitles',
      fileName: fileName,
      languageCode: 'zh-CN',
      downloadCount: 0
    });

    it('keeps relevant and drops garbage', 0, () => {
      const results = [
        r('The.Lychee.Road.2025.1080p.WEB-DL.x264.AAC-CHS.ass'),
        r('长安的荔枝.ass'),
        r('Hallow.Road.2025.1080p.WEB-DL.x264-CHS.srt'),
        r('Ice.Road.Vengeance.2025.1080p.WEB.x264-CHS.srt')
      ];
      const filtered = filterByTitleRelevance(results, 'The Lychee Road', '长安的荔枝');
      expect(filtered.length).assertEqual(2);
      expect(filtered[0].fileName.includes('Lychee.Road')).assertTrue();
      expect(filtered[1].fileName.includes('长安的荔枝')).assertTrue();
    });

    it('returns empty when nothing matches (no garbage fallback)', 0, () => {
      const results = [r('Hallow.Road.2025.srt'), r('Ice.Road.Vengeance.2025.srt')];
      const filtered = filterByTitleRelevance(results, 'The Lychee Road', '长安的荔枝');
      expect(filtered.length).assertEqual(0);
    });
  });
}
