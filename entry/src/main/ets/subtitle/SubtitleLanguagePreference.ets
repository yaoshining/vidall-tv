import { AppPreferences, PrefKey } from '../utils/AppPreferences'

export interface SubtitleLanguageOption {
  code: string
  label: string
  searchCodes: string[]
  resultAliases: string[]
}

export interface SubtitleLanguagePreference {
  languages: string[]
  hideOtherLanguages: boolean
}

export type SubtitleLanguageActionType = 'enable' | 'disable' | 'move-up' | 'move-down'

export interface SubtitleLanguageAction {
  type: SubtitleLanguageActionType
  label: string
  enabled: boolean
}

export interface SubtitleSearchResultLike {
  id: string
  language: string
}

export interface SubtitleLanguageSearchPreferenceSnapshot {
  languages: string[]
  languagesParam: string
  hideOtherLanguages: boolean
}

export interface SubtitleLanguagePreferenceLoadContext {
  loadVersion: number
  hasLocalChanges: boolean
}

export interface SubtitleTrackLanguageCandidate {
  displayName: string
  language?: string
}

interface RawSubtitleLanguagePreference {
  languages?: string[]
  hideOtherLanguages?: boolean
}

const MAX_SUBTITLE_LANGUAGE_COUNT: number = 3

export const SUBTITLE_LANGUAGE_OPTIONS: SubtitleLanguageOption[] = [
  {
    code: 'zh-CN',
    label: '简体中文',
    searchCodes: ['zh-CN'],
    resultAliases: ['zh-cn', 'zh', 'chi', 'zho', 'chs']
  },
  {
    code: 'zh-TW',
    label: '繁体中文',
    searchCodes: ['zh-TW'],
    resultAliases: ['zh-tw', 'zh-hk', 'cht']
  },
  {
    code: 'en',
    label: '英语',
    searchCodes: ['en'],
    resultAliases: ['en', 'eng']
  },
  {
    code: 'ja',
    label: '日语',
    searchCodes: ['ja'],
    resultAliases: ['ja', 'jpn']
  },
  {
    code: 'ko',
    label: '韩语',
    searchCodes: ['ko'],
    resultAliases: ['ko', 'kor']
  },
  {
    code: 'fr',
    label: '法语',
    searchCodes: ['fr'],
    resultAliases: ['fr', 'fra', 'fre']
  },
  {
    code: 'de',
    label: '德语',
    searchCodes: ['de'],
    resultAliases: ['de', 'deu', 'ger']
  },
  {
    code: 'es',
    label: '西班牙语',
    searchCodes: ['es'],
    resultAliases: ['es', 'spa']
  }
]

export const DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE: SubtitleLanguagePreference = {
  languages: ['zh-CN', 'zh-TW'],
  hideOtherLanguages: false
}

function findSubtitleLanguageOption(code: string): SubtitleLanguageOption | null {
  const normalizedInput = code.trim().toLowerCase()
  for (let index = 0; index < SUBTITLE_LANGUAGE_OPTIONS.length; index++) {
    const option = SUBTITLE_LANGUAGE_OPTIONS[index]
    if (option.code.toLowerCase() === normalizedInput) {
      return option
    }
  }
  return null
}

export function getSubtitleLanguageDisplayName(code: string): string {
  const option = findSubtitleLanguageOption(code)
  return option === null ? code : option.label
}

export function normalizeSubtitleLanguagePreference(preference: SubtitleLanguagePreference): SubtitleLanguagePreference {
  const normalizedLanguages: string[] = []
  for (let index = 0; index < preference.languages.length; index++) {
    const option = findSubtitleLanguageOption(preference.languages[index])
    if (option === null) {
      continue
    }
    if (!normalizedLanguages.includes(option.code)) {
      normalizedLanguages.push(option.code)
    }
    if (normalizedLanguages.length >= MAX_SUBTITLE_LANGUAGE_COUNT) {
      break
    }
  }

  const fallbackLanguages: string[] = normalizedLanguages.length > 0
    ? normalizedLanguages
    : [...DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.languages]
  const normalizedPreference: SubtitleLanguagePreference = {
    languages: fallbackLanguages,
    hideOtherLanguages: preference.hideOtherLanguages === true
  }
  return normalizedPreference
}

export function moveSubtitleLanguagePreference(
  preference: SubtitleLanguagePreference,
  languageCode: string,
  direction: 'up' | 'down'
): SubtitleLanguagePreference {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  const languages = [...normalizedPreference.languages]
  const index = languages.indexOf(languageCode)
  if (index < 0) {
    return normalizedPreference
  }

  const targetIndex = direction === 'up' ? index - 1 : index + 1
  if (targetIndex < 0 || targetIndex >= languages.length) {
    return normalizedPreference
  }

  const currentValue = languages[index]
  languages[index] = languages[targetIndex]
  languages[targetIndex] = currentValue
  const movedPreference: SubtitleLanguagePreference = {
    languages,
    hideOtherLanguages: normalizedPreference.hideOtherLanguages
  }
  return movedPreference
}

export function buildSubtitleLanguageActions(
  preference: SubtitleLanguagePreference,
  languageCode: string
): SubtitleLanguageAction[] {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  const index = normalizedPreference.languages.indexOf(languageCode)
  if (index < 0) {
    const enableAction: SubtitleLanguageAction = {
      type: 'enable',
      label: '启用',
      enabled: normalizedPreference.languages.length < MAX_SUBTITLE_LANGUAGE_COUNT
    }
    return [enableAction]
  }

  const actions: SubtitleLanguageAction[] = [
    {
      type: 'move-up',
      label: '上移',
      enabled: index > 0
    },
    {
      type: 'move-down',
      label: '下移',
      enabled: index < normalizedPreference.languages.length - 1
    },
    {
      type: 'disable',
      label: '取消启用',
      enabled: normalizedPreference.languages.length > 1
    }
  ]
  return actions
}

export function buildSubtitleSearchPreferenceSnapshot(
  preference: SubtitleLanguagePreference
): SubtitleLanguageSearchPreferenceSnapshot {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  const snapshot: SubtitleLanguageSearchPreferenceSnapshot = {
    languages: [...normalizedPreference.languages],
    languagesParam: normalizedPreference.languages.join(','),
    hideOtherLanguages: normalizedPreference.hideOtherLanguages
  }
  return snapshot
}

export function shouldApplySubtitleLanguagePreferenceLoad(
  loadVersion: number,
  currentLoadVersion: number,
  hasLocalChanges: boolean
): boolean {
  return loadVersion === currentLoadVersion && !hasLocalChanges
}

export function beginSubtitleLanguagePreferenceLoad(
  currentLoadVersion: number
): SubtitleLanguagePreferenceLoadContext {
  const nextLoadContext: SubtitleLanguagePreferenceLoadContext = {
    loadVersion: currentLoadVersion + 1,
    hasLocalChanges: false
  }
  return nextLoadContext
}

function getSubtitleLanguageRank(language: string, preference: SubtitleLanguagePreference): number {
  const normalizedLanguage = language.trim().toLowerCase()
  for (let index = 0; index < preference.languages.length; index++) {
    const option = findSubtitleLanguageOption(preference.languages[index])
    if (option === null) {
      continue
    }
    if (option.resultAliases.includes(normalizedLanguage) || option.code.toLowerCase() === normalizedLanguage) {
      return index
    }
  }
  return -1
}

function buildSubtitleDisplayMatchKeywords(languageCode: string): string[] {
  const option = findSubtitleLanguageOption(languageCode)
  if (option === null) {
    return []
  }

  const baseKeywords: string[] = [
    option.code,
    option.label
  ]
  for (let index = 0; index < option.searchCodes.length; index++) {
    baseKeywords.push(option.searchCodes[index])
  }
  for (let index = 0; index < option.resultAliases.length; index++) {
    baseKeywords.push(option.resultAliases[index])
  }

  if (option.code === 'zh-CN') {
    baseKeywords.push('简体', '简中', 'hans', 'simplified')
  } else if (option.code === 'zh-TW') {
    baseKeywords.push('繁体', '繁中', '香港', '臺灣', '台湾', 'hant', 'traditional')
  } else if (option.code === 'en') {
    baseKeywords.push('english')
  } else if (option.code === 'ja') {
    baseKeywords.push('japanese')
  } else if (option.code === 'ko') {
    baseKeywords.push('korean')
  } else if (option.code === 'fr') {
    baseKeywords.push('french')
  } else if (option.code === 'de') {
    baseKeywords.push('german')
  } else if (option.code === 'es') {
    baseKeywords.push('spanish')
  }

  const keywords: string[] = []
  for (let index = 0; index < baseKeywords.length; index++) {
    const keyword = baseKeywords[index].trim().toLowerCase()
    if (keyword.length === 0 || keywords.includes(keyword)) {
      continue
    }
    keywords.push(keyword)
  }
  return keywords
}

function getSubtitleTrackLanguageRank(
  track: SubtitleTrackLanguageCandidate,
  preference: SubtitleLanguagePreference
): number {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  const languageRank = track.language !== undefined
    ? getSubtitleLanguageRank(track.language, normalizedPreference)
    : -1
  if (languageRank >= 0) {
    return languageRank
  }

  const normalizedDisplayName = track.displayName.trim().toLowerCase()
  for (let index = 0; index < normalizedPreference.languages.length; index++) {
    const keywords = buildSubtitleDisplayMatchKeywords(normalizedPreference.languages[index])
    for (let keywordIndex = 0; keywordIndex < keywords.length; keywordIndex++) {
      if (normalizedDisplayName.includes(keywords[keywordIndex])) {
        return index
      }
    }
  }
  return -1
}

export function findPreferredSubtitleTrackIndex(
  tracks: SubtitleTrackLanguageCandidate[],
  preference: SubtitleLanguagePreference
): number {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  let matchedTrackIndex = -1
  let matchedTrackRank = normalizedPreference.languages.length

  for (let index = 0; index < tracks.length; index++) {
    const rank = getSubtitleTrackLanguageRank(tracks[index], normalizedPreference)
    if (rank < 0) {
      continue
    }
    if (rank < matchedTrackRank) {
      matchedTrackRank = rank
      matchedTrackIndex = index
    }
  }

  return matchedTrackIndex
}

export function applySubtitleLanguagePreferenceToSearchResults<T extends SubtitleSearchResultLike>(
  results: T[],
  preference: SubtitleLanguagePreference
): T[] {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  const preferredBuckets: Array<T[]> = []
  const fallbackResults: T[] = []
  const orderedResults: T[] = []

  for (let index = 0; index < normalizedPreference.languages.length; index++) {
    preferredBuckets.push([])
  }

  for (let index = 0; index < results.length; index++) {
    const result = results[index]
    const rank = getSubtitleLanguageRank(result.language, normalizedPreference)
    if (rank >= 0) {
      preferredBuckets[rank].push(result)
      continue
    }
    if (!normalizedPreference.hideOtherLanguages) {
      fallbackResults.push(result)
    }
  }

  for (let index = 0; index < preferredBuckets.length; index++) {
    const bucket = preferredBuckets[index]
    for (let bucketIndex = 0; bucketIndex < bucket.length; bucketIndex++) {
      orderedResults.push(bucket[bucketIndex])
    }
  }

  for (let index = 0; index < fallbackResults.length; index++) {
    orderedResults.push(fallbackResults[index])
  }
  return orderedResults
}

export function buildSubtitleLanguagePreferenceSummary(preference: SubtitleLanguagePreference): string {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  const labels: string[] = []
  for (let index = 0; index < normalizedPreference.languages.length; index++) {
    labels.push(getSubtitleLanguageDisplayName(normalizedPreference.languages[index]))
  }
  const summary = labels.join(' / ')
  return normalizedPreference.hideOtherLanguages ? `${summary} · 仅偏好` : summary
}

export function deserializeSubtitleLanguagePreference(serializedPreference: string): SubtitleLanguagePreference {
  if (serializedPreference.trim().length === 0) {
    return normalizeSubtitleLanguagePreference(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE)
  }
  try {
    const rawPreference = JSON.parse(serializedPreference) as RawSubtitleLanguagePreference
    const preference: SubtitleLanguagePreference = {
      languages: Array.isArray(rawPreference.languages) ? rawPreference.languages : [],
      hideOtherLanguages: rawPreference.hideOtherLanguages === true
    }
    return normalizeSubtitleLanguagePreference(preference)
  } catch {
    return normalizeSubtitleLanguagePreference(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE)
  }
}

export async function loadSubtitleLanguagePreference(): Promise<SubtitleLanguagePreference> {
  const serializedPreference = await AppPreferences.get(PrefKey.SUBTITLE_LANGUAGE_PREFERENCE, '')
  return deserializeSubtitleLanguagePreference(serializedPreference)
}

export async function saveSubtitleLanguagePreference(preference: SubtitleLanguagePreference): Promise<void> {
  const normalizedPreference = normalizeSubtitleLanguagePreference(preference)
  await AppPreferences.set(
    PrefKey.SUBTITLE_LANGUAGE_PREFERENCE,
    JSON.stringify(normalizedPreference)
  )
}

export async function loadSubtitleSearchPreferenceSnapshot(): Promise<SubtitleLanguageSearchPreferenceSnapshot> {
  const preference = await loadSubtitleLanguagePreference()
  return buildSubtitleSearchPreferenceSnapshot(preference)
}
