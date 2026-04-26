import { describe, it, expect } from '@ohos/hypium'
import {
  DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE,
  applySubtitleLanguagePreferenceToSearchResults,
  buildSubtitleSearchPreferenceSnapshot,
  moveSubtitleLanguagePreference,
  normalizeSubtitleLanguagePreference,
  SubtitleLanguagePreference,
  SubtitleSearchResultLike
} from '../main/ets/subtitle/SubtitleLanguagePreference'

interface MockSubtitleSearchResult extends SubtitleSearchResultLike {
  releaseName: string
}

function createSearchResult(id: string, language: string, releaseName: string): MockSubtitleSearchResult {
  return {
    id,
    language,
    releaseName
  }
}

export default function subtitleLanguagePreferenceTest() {
  describe('SubtitleLanguagePreference', () => {
    it('should expose confirmed default subtitle preference', 0, () => {
      expect(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.languages.length).assertEqual(2)
      expect(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.languages[0]).assertEqual('zh-CN')
      expect(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.languages[1]).assertEqual('zh-TW')
      expect(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.hideOtherLanguages).assertFalse()
    })

    it('should normalize duplicates unsupported codes and keep at most three languages', 0, () => {
      const rawPreference: SubtitleLanguagePreference = {
        languages: ['en', 'zh-CN', 'en', 'ja', 'xx', 'fr'],
        hideOtherLanguages: true
      }

      const normalized = normalizeSubtitleLanguagePreference(rawPreference)

      expect(normalized.languages.length).assertEqual(3)
      expect(normalized.languages[0]).assertEqual('en')
      expect(normalized.languages[1]).assertEqual('zh-CN')
      expect(normalized.languages[2]).assertEqual('ja')
      expect(normalized.hideOtherLanguages).assertTrue()
    })

    it('should move enabled subtitle languages by priority', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['zh-CN', 'en', 'ja'],
        hideOtherLanguages: false
      }

      const movedUp = moveSubtitleLanguagePreference(preference, 'en', 'up')
      const movedDown = moveSubtitleLanguagePreference(movedUp, 'zh-CN', 'down')

      expect(movedUp.languages[0]).assertEqual('en')
      expect(movedUp.languages[1]).assertEqual('zh-CN')
      expect(movedDown.languages[0]).assertEqual('en')
      expect(movedDown.languages[1]).assertEqual('ja')
      expect(movedDown.languages[2]).assertEqual('zh-CN')
    })

    it('should expose search snapshot and sort subtitle results by preferred language aliases', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['zh-CN', 'en'],
        hideOtherLanguages: false
      }
      const results: MockSubtitleSearchResult[] = [
        createSearchResult('3', 'fra', 'French release'),
        createSearchResult('2', 'eng', 'English release'),
        createSearchResult('1', 'chi', 'Chinese release')
      ]

      const snapshot = buildSubtitleSearchPreferenceSnapshot(preference)
      const ordered = applySubtitleLanguagePreferenceToSearchResults(results, preference)

      expect(snapshot.languagesParam).assertEqual('zh-CN,en')
      expect(snapshot.hideOtherLanguages).assertFalse()
      expect(ordered.length).assertEqual(3)
      expect(ordered[0].id).assertEqual('1')
      expect(ordered[1].id).assertEqual('2')
      expect(ordered[2].id).assertEqual('3')
    })

    it('should hide non preferred subtitles when hideOtherLanguages is enabled', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['zh-TW'],
        hideOtherLanguages: true
      }
      const results: MockSubtitleSearchResult[] = [
        createSearchResult('1', 'eng', 'English release'),
        createSearchResult('2', 'cht', 'Traditional Chinese release'),
        createSearchResult('3', 'chi', 'Simplified Chinese release')
      ]

      const filtered = applySubtitleLanguagePreferenceToSearchResults(results, preference)

      expect(filtered.length).assertEqual(1)
      expect(filtered[0].id).assertEqual('2')
    })
  })
}
