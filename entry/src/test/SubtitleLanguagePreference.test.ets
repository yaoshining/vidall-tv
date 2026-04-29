import { describe, it, expect } from '@ohos/hypium'
import {
  buildSubtitleLanguageActions,
  beginSubtitleLanguagePreferenceLoad,
  DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE,
  applySubtitleLanguagePreferenceToSearchResults,
  buildSubtitleSearchPreferenceSnapshot,
  findPreferredSubtitleTrackIndex,
  moveSubtitleLanguagePreference,
  normalizeSubtitleLanguagePreference,
  shouldApplySubtitleLanguagePreferenceLoad,
  SubtitleLanguagePreference,
  SubtitleSearchResultLike,
  SubtitleTrackLanguageCandidate
} from '../main/ets/subtitle/SubtitleLanguagePreference'

interface MockSubtitleSearchResult extends SubtitleSearchResultLike {
  releaseName: string
}

interface MockSubtitleTrackCandidate extends SubtitleTrackLanguageCandidate {
}

function createSearchResult(id: string, language: string, releaseName: string): MockSubtitleSearchResult {
  return {
    id,
    language,
    releaseName
  }
}

function createTrackCandidate(displayName: string, language?: string): MockSubtitleTrackCandidate {
  const candidate: MockSubtitleTrackCandidate = {
    displayName
  }
  if (language !== undefined) {
    candidate.language = language
  }
  return candidate
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

    it('should expose explicit actions for enabled and disabled subtitle languages', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['zh-CN', 'en', 'ja'],
        hideOtherLanguages: false
      }
      const availablePreference: SubtitleLanguagePreference = {
        languages: ['zh-CN', 'en'],
        hideOtherLanguages: false
      }

      const enabledActions = buildSubtitleLanguageActions(preference, 'en')
      const disabledActions = buildSubtitleLanguageActions(availablePreference, 'fr')

      expect(enabledActions.length).assertEqual(3)
      expect(enabledActions[0].type).assertEqual('move-up')
      expect(enabledActions[0].enabled).assertTrue()
      expect(enabledActions[1].type).assertEqual('move-down')
      expect(enabledActions[1].enabled).assertTrue()
      expect(enabledActions[2].type).assertEqual('disable')
      expect(enabledActions[2].enabled).assertTrue()

      expect(disabledActions.length).assertEqual(1)
      expect(disabledActions[0].type).assertEqual('enable')
      expect(disabledActions[0].enabled).assertTrue()
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

    it('should pick the highest priority subtitle track that matches preferred languages', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['ja', 'en', 'zh-CN'],
        hideOtherLanguages: false
      }
      const tracks: MockSubtitleTrackCandidate[] = [
        createTrackCandidate('简体中文 (ASS)'),
        createTrackCandidate('English (SRT)', 'eng'),
        createTrackCandidate('日语 (ASS)', 'jpn')
      ]

      const preferredIndex = findPreferredSubtitleTrackIndex(tracks, preference)

      expect(preferredIndex).assertEqual(2)
    })

    it('should match preferred subtitle language from display name when track language is missing', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['zh-TW', 'en'],
        hideOtherLanguages: false
      }
      const tracks: MockSubtitleTrackCandidate[] = [
        createTrackCandidate('繁体中文 [外部·ASS]'),
        createTrackCandidate('English [外部·SRT]')
      ]

      const preferredIndex = findPreferredSubtitleTrackIndex(tracks, preference)

      expect(preferredIndex).assertEqual(0)
    })

    it('should keep subtitle disabled when no track matches preferred languages', 0, () => {
      const preference: SubtitleLanguagePreference = {
        languages: ['zh-CN', 'zh-TW'],
        hideOtherLanguages: false
      }
      const tracks: MockSubtitleTrackCandidate[] = [
        createTrackCandidate('English (ASS)', 'eng'),
        createTrackCandidate('French (SRT)', 'fra')
      ]

      const preferredIndex = findPreferredSubtitleTrackIndex(tracks, preference)

      expect(preferredIndex).assertEqual(-1)
    })
  })

  describe('SubtitleLanguagePreference async load guard', () => {
    it('用户已修改字幕语言偏好后不再应用旧的异步加载结果', 0, () => {
      expect(shouldApplySubtitleLanguagePreferenceLoad(1, 1, true)).assertFalse()
    })

    it('字幕偏好页开始新一轮加载时会清除旧的本地修改标记', 0, () => {
      const nextLoad = beginSubtitleLanguagePreferenceLoad(3)

      expect(nextLoad.loadVersion).assertEqual(4)
      expect(nextLoad.hasLocalChanges).assertFalse()
    })

    it('字幕偏好页重新打开后只接受最新一次加载结果', 0, () => {
      expect(shouldApplySubtitleLanguagePreferenceLoad(1, 2, false)).assertFalse()
      expect(shouldApplySubtitleLanguagePreferenceLoad(2, 2, false)).assertTrue()
    })
  })
}
