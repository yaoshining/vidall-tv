/**
 * Test suite for SubtitleDeduplicator + normalizeReleaseName
 * Spec: subtitle-acquisition-service (聚合去重)
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  SubtitleDeduplicator,
  normalizeReleaseName
} from '../../../../main/ets/services/subtitleAcquisition/providers/SubtitleDeduplicator';
import { SubtitleSearchResult } from '../../../../main/ets/services/subtitleAcquisition/SubtitleAcquisitionTypes';

function osResult(id: string, fileName: string, lang: string): SubtitleSearchResult {
  const r: SubtitleSearchResult = {
    subtitleId: id,
    source: 'opensubtitles',
    fileName: fileName,
    languageCode: lang,
    downloadCount: 100,
    fileId: 1
  };
  return r;
}

function shResult(id: string, fileName: string, lang: string): SubtitleSearchResult {
  const r: SubtitleSearchResult = {
    subtitleId: id,
    source: 'subhub',
    fileName: fileName,
    languageCode: lang,
    downloadCount: 0,
    subtitleRef: id
  };
  return r;
}

export default function subtitleDeduplicatorTest() {
  describe('SubtitleDeduplicator_normalizeReleaseName', () => {
    it('strips subtitle extension', 0, () => {
      expect(normalizeReleaseName('Inception.2010.BluRay.srt')).assertEqual('inception 2010 bluray');
    });

    it('lowercases and trims', 0, () => {
      expect(normalizeReleaseName('  The.Matrix.1999 ')).assertEqual('the matrix 1999');
    });

    it('strips release group markers', 0, () => {
      expect(normalizeReleaseName('The.Wandering.Earth.2019-[YTS.MX]')).assertEqual('the wandering earth 2019');
    });

    it('preserves Chinese title', 0, () => {
      expect(normalizeReleaseName('长安的荔枝.ass')).assertEqual('长安的荔枝');
    });

    it('preserves Korean title', 0, () => {
      expect(normalizeReleaseName('우씨왕후.E01.srt')).assertEqual('우씨왕후 e01');
    });
  });

  describe('SubtitleDeduplicator_dedupe', () => {
    it('keeps opensubtitles on fingerprint collision', 0, () => {
      const results = [
        osResult('os1', 'Inception.2010.BluRay.srt', 'zh-CN'),
        shResult('sh1', 'Inception.2010.BluRay', 'zh-CN')
      ];
      const deduped = SubtitleDeduplicator.dedupe(results);
      expect(deduped.length).assertEqual(1);
      expect(deduped[0].source).assertEqual('opensubtitles');
      expect(deduped[0].subtitleId).assertEqual('os1');
    });

    it('keeps both when fingerprints differ', 0, () => {
      const results = [
        osResult('os1', 'Inception.srt', 'zh-CN'),
        shResult('sh1', 'Inception', 'en')
      ];
      expect(SubtitleDeduplicator.dedupe(results).length).assertEqual(2);
    });

    it('preserves input order for distinct results', 0, () => {
      const results = [
        osResult('os1', 'MovieA.srt', 'zh-CN'),
        shResult('sh1', 'MovieB', 'zh-CN')
      ];
      const deduped = SubtitleDeduplicator.dedupe(results);
      expect(deduped[0].subtitleId).assertEqual('os1');
      expect(deduped[1].subtitleId).assertEqual('sh1');
    });
  });
}
