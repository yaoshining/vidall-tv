/**
 * Test suite for SubtitleLanguageFilter（SubHub 结果中文过滤）
 * Spec: subhub-subtitle-provider
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  isChineseLanguagePreference,
  isChineseSubtitle
} from '../../../../main/ets/services/subtitleAcquisition/providers/SubtitleLanguageFilter';

export default function subtitleLanguageFilterTest() {
  describe('isChineseLanguagePreference', () => {
    it('returns true for zh-CN,zh-TW', 0, () => {
      expect(isChineseLanguagePreference('zh-CN,zh-TW')).assertTrue();
    });

    it('returns true for chi', 0, () => {
      expect(isChineseLanguagePreference('chi')).assertTrue();
    });

    it('returns false for en', 0, () => {
      expect(isChineseLanguagePreference('en')).assertFalse();
    });
  });

  describe('isChineseSubtitle_releaseName', () => {
    it('detects Chinese episode title', 0, () => {
      expect(isChineseSubtitle('权力的游戏.第02季第01集.Game.of.Thrones.S02.E01.2012', '')).assertTrue();
    });

    it('detects _zh_ marker', 0, () => {
      expect(isChineseSubtitle('一枕山河踏月来_zh_3_1779353944.ass', '')).assertTrue();
    });

    it('detects 简体 marker', 0, () => {
      expect(isChineseSubtitle('御赐小仵作_02_中文(简体).ass', '')).assertTrue();
    });

    it('detects 中文 marker', 0, () => {
      expect(isChineseSubtitle('御赐小仵作_29_中文含硬字幕片尾.srt', '默认')).assertTrue();
    });

    it('detects bilingual CHSEN via CJK', 0, () => {
      expect(isChineseSubtitle('CHSEN_权游.srt', 'CHSEN_权游')).assertTrue();
    });

    it('rejects _en_ marker even with Chinese show name', 0, () => {
      expect(isChineseSubtitle('一枕山河踏月来_en_16_1779420352.ass', '')).assertFalse();
    });

    it('rejects English scene name', 0, () => {
      expect(isChineseSubtitle('game.of.th', '')).assertFalse();
    });
  });

  describe('isChineseSubtitle_languagePriority', () => {
    it('detects zh-CN language code', 0, () => {
      expect(isChineseSubtitle('Game.of.Thrones.S01E01.zh-CN.srt', 'zh-CN')).assertTrue();
    });

    it('rejects en language code', 0, () => {
      expect(isChineseSubtitle('Game.of.Thrones.S01E01.en.srt', 'en')).assertFalse();
    });

    it('language zh-CN wins over releaseName .en marker', 0, () => {
      expect(isChineseSubtitle('Game.of.Thrones.S01E01.en.srt', 'zh-CN')).assertTrue();
    });

    it('keeps bilingual zh-CN,en', 0, () => {
      expect(isChineseSubtitle('Game.of.Thrones.S01E01.zh-CN.en.srt', 'zh-CN,en')).assertTrue();
    });
  });
}
