export type MediaTypeClassification = 'movie' | 'tv' | 'unknown';

export type MediaTypeClassificationSignalSource =
  'file-name' |
  'full-path' |
  'parent-directory' |
  'ancestor-directory' |
  'path-semantics';

export interface FileNameSemanticInfo {
  title: string;
  year?: number;
  mediaType?: 'movie' | 'tv';
  seasonNumber?: number;
  episodeNumber?: number;
  language: string;
}

export interface MediaTypeClassificationSignal {
  source: MediaTypeClassificationSignalSource;
  value: string;
  detail?: string;
  weight?: number;
}

export interface MediaTypeClassificationInput {
  fileName: string;
  filePath: string;
  parentDirectoryName?: string;
  ancestorDirectoryNames: string[];
  pathSegments: string[];
  fileNameInfo?: FileNameSemanticInfo;
  seasonSiblingDetected?: boolean;
}

export interface MediaTypeClassificationOptions {
  seasonSiblingDetected?: boolean;
}

export interface MediaTypeClassificationResult {
  mediaType: MediaTypeClassification;
  signals: MediaTypeClassificationSignal[];
  reason?: string;
}

interface PathSemanticKeywordRule {
  mediaType: 'movie' | 'tv';
  keywords: string[];
}

interface PathSemanticSignalMatch {
  mediaType: 'movie' | 'tv';
  signal: MediaTypeClassificationSignal;
}

const TV_PATH_SEMANTIC_RULE: PathSemanticKeywordRule = {
  mediaType: 'tv',
  keywords: [
    '电视剧',
    '剧集',
    '连续剧',
    '番剧',
    '动漫',
    '美剧',
    '日剧',
    '韩剧',
    '国产剧',
    'tv series',
    'season',
    'episode',
    'anime'
  ]
};

const MOVIE_PATH_SEMANTIC_RULE: PathSemanticKeywordRule = {
  mediaType: 'movie',
  keywords: [
    '电影',
    '影片',
    '院线',
    '蓝光原盘',
    '蓝光',
    '电影合集',
    'movie',
    'movies',
    'film',
    'films',
    'bluray',
    'blu ray',
    'remux'
  ]
};

const PATH_SEMANTIC_RULES: PathSemanticKeywordRule[] = [
  TV_PATH_SEMANTIC_RULE,
  MOVIE_PATH_SEMANTIC_RULE
];

const WEAK_FILENAME_TOKENS: string[] = [
  '4k',
  '2160p',
  '1080p',
  '720p',
  '480p',
  'uhd',
  'hdr',
  'bluray',
  'blu ray',
  'web dl',
  'webrip',
  'hdtv',
  'remux'
];

const SEASON_DIRECTORY_PATTERNS: RegExp[] = [
  /^season(\s*\d+)?$/i,
  /^s\d{1,2}$/i,
  /^第\s*\d+\s*季$/,
  /^season\s+\d+$/i
];

function normalizePathSegments(filePath: string): string[] {
  const normalizedPath = filePath.replace(/\\/g, '/');
  return normalizedPath.split('/').filter((segment: string) => segment.length > 0);
}

function normalizeSemanticToken(value: string): string {
  return value
    .toLowerCase()
    .replace(/[._-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function getPathSignalSource(distanceFromLeaf: number): MediaTypeClassificationSignalSource {
  return distanceFromLeaf === 0 ? 'parent-directory' : 'ancestor-directory';
}

function getPathSignalWeight(distanceFromLeaf: number): number {
  const rawWeight = 70 - distanceFromLeaf * 10;
  return rawWeight >= 40 ? rawWeight : 40;
}

function matchesKeyword(normalizedSegment: string, keyword: string): boolean {
  const normalizedKeyword = normalizeSemanticToken(keyword);
  return normalizedKeyword.length > 0 && normalizedSegment.includes(normalizedKeyword);
}

function collectPathSemanticMatches(pathSegments: string[]): PathSemanticSignalMatch[] {
  const matches: PathSemanticSignalMatch[] = [];
  const totalSegments = pathSegments.length;
  pathSegments.forEach((segment: string, index: number) => {
    const normalizedSegment = normalizeSemanticToken(segment);
    if (normalizedSegment.length === 0) {
      return;
    }

    const distanceFromLeaf = totalSegments - index - 1;
    const weight = getPathSignalWeight(distanceFromLeaf);
    const source = getPathSignalSource(distanceFromLeaf);

    PATH_SEMANTIC_RULES.forEach((rule: PathSemanticKeywordRule) => {
      const matchedKeyword = rule.keywords.find((keyword: string) => matchesKeyword(normalizedSegment, keyword));
      if (matchedKeyword === undefined) {
        return;
      }

      const signal: MediaTypeClassificationSignal = {
        source,
        value: segment,
        detail: `${rule.mediaType}:${matchedKeyword}`,
        weight
      };
      matches.push({
        mediaType: rule.mediaType,
        signal
      });
    });
  });
  return matches;
}

export function isWeakSemanticTitleText(title: string): boolean {
  const normalizedTitle = normalizeSemanticToken(title);
  if (normalizedTitle.length === 0) {
    return true;
  }

  const strippedDigits = normalizedTitle.replace(/\d+/g, '').trim();
  if (strippedDigits.length === 0) {
    return true;
  }

  const reducedTitle = WEAK_FILENAME_TOKENS.reduce((current: string, token: string) => {
    const normalizedToken = normalizeSemanticToken(token);
    if (normalizedToken.length === 0) {
      return current;
    }
    return current.replace(new RegExp(`\\b${normalizedToken}\\b`, 'g'), ' ').trim();
  }, normalizedTitle);

  const cleanedTitle = reducedTitle.replace(/\s+/g, ' ').trim();
  return cleanedTitle.length === 0 || cleanedTitle.length === 1;
}

function hasStrongTvSignal(fileNameInfo?: FileNameSemanticInfo): boolean {
  return fileNameInfo?.seasonNumber !== undefined && fileNameInfo?.episodeNumber !== undefined;
}

function hasStrongMovieSignal(fileNameInfo?: FileNameSemanticInfo): boolean {
  if (fileNameInfo === undefined) {
    return false;
  }
  if (isWeakSemanticTitleText(fileNameInfo.title)) {
    return false;
  }
  return fileNameInfo.year !== undefined || fileNameInfo.title.length >= 2;
}

export function isSeasonDirectorySegment(segment: string): boolean {
  const normalizedSegment = normalizeSemanticToken(segment);
  return SEASON_DIRECTORY_PATTERNS.some((pattern: RegExp) => pattern.test(normalizedSegment)) ||
    /^第\s*[\d一二三四五六七八九十百]+\s*季$/.test(segment);
}

function isGenericTvSemanticSegment(segment: string): boolean {
  const normalizedSegment = normalizeSemanticToken(segment);
  return TV_PATH_SEMANTIC_RULE.keywords.some((keyword: string) => normalizeSemanticToken(keyword) === normalizedSegment);
}

function appendSignal(
  signals: MediaTypeClassificationSignal[],
  source: MediaTypeClassificationSignalSource,
  value: string,
  detail?: string,
  weight?: number
): void {
  const signal: MediaTypeClassificationSignal = { source, value, detail, weight };
  signals.push(signal);
}

export function buildMediaTypeClassificationInput(
  fileName: string,
  filePath: string,
  fileNameInfo?: FileNameSemanticInfo,
  options?: MediaTypeClassificationOptions
): MediaTypeClassificationInput {
  const rawSegments: string[] = normalizePathSegments(filePath);
  const filePathEndsWithFileName = rawSegments.length > 0 && rawSegments[rawSegments.length - 1] === fileName;
  const pathSegments: string[] = filePathEndsWithFileName ? rawSegments.slice(0, rawSegments.length - 1) : rawSegments;
  const parentDirectoryName = pathSegments.length > 0 ? pathSegments[pathSegments.length - 1] : undefined;
  const ancestorDirectoryNames: string[] =
    pathSegments.length > 1 ? pathSegments.slice(0, pathSegments.length - 1) : [];

  return {
    fileName,
    filePath,
    parentDirectoryName,
    ancestorDirectoryNames,
    pathSegments,
    fileNameInfo,
    seasonSiblingDetected: options?.seasonSiblingDetected
  };
}

export function createFileNameSemanticInfo(
  title: string,
  language: string,
  mediaType?: 'movie' | 'tv',
  seasonNumber?: number,
  episodeNumber?: number,
  year?: number
): FileNameSemanticInfo {
  return {
    title,
    language,
    mediaType,
    seasonNumber,
    episodeNumber,
    year
  };
}

export function createMediaTypeClassificationResult(
  mediaType: MediaTypeClassification,
  signals: MediaTypeClassificationSignal[],
  reason?: string
): MediaTypeClassificationResult {
  return {
    mediaType,
    signals,
    reason
  };
}

export function extractSeriesHintFromFilePath(filePath: string): string | undefined {
  const segments = normalizePathSegments(filePath);
  const directorySegments = segments.length > 0 ? segments.slice(0, segments.length - 1) : [];
  for (let index = directorySegments.length - 1; index >= 0; index--) {
    const segment = directorySegments[index];
    if (segment.length === 0) {
      continue;
    }
    if (isSeasonDirectorySegment(segment)) {
      continue;
    }
    if (isGenericTvSemanticSegment(segment)) {
      continue;
    }
    return segment;
  }
  return directorySegments.length > 0 ? directorySegments[directorySegments.length - 1] : undefined;
}

export function formatMediaTypeClassificationSignals(classification: MediaTypeClassificationResult): string {
  if (classification.signals.length === 0) {
    return 'none';
  }
  return classification.signals
    .map((signal) => `${signal.source}:${signal.value}${signal.detail ? '[' + signal.detail + ']' : ''}`)
    .join(', ');
}

export function classifyMediaType(input: MediaTypeClassificationInput): MediaTypeClassificationResult {
  const signals: MediaTypeClassificationSignal[] = [];
  const fileNameInfo = input.fileNameInfo;
  const hasWeakSemanticTitle = isWeakSemanticTitleText(fileNameInfo?.title ?? '');

  if (hasStrongTvSignal(fileNameInfo)) {
    appendSignal(
      signals,
      'file-name',
      input.fileName,
      `season-episode:S${fileNameInfo?.seasonNumber ?? 0}E${fileNameInfo?.episodeNumber ?? 0}`,
      100
    );
    return createMediaTypeClassificationResult('tv', signals, 'season-episode-pattern');
  }

  let movieScore = 0;
  let tvScore = 0;

  if (fileNameInfo !== undefined) {
    if (hasWeakSemanticTitle) {
      appendSignal(signals, 'file-name', fileNameInfo.title.length > 0 ? fileNameInfo.title : input.fileName, 'weak-semantic-title', 0);
    } else if (hasStrongMovieSignal(fileNameInfo)) {
      const movieSignalWeight = fileNameInfo.year !== undefined ? 80 : 60;
      movieScore += movieSignalWeight;
      appendSignal(signals, 'file-name', fileNameInfo.title, fileNameInfo.year !== undefined ? 'title-with-year' : 'readable-title', movieSignalWeight);
    }
  }

  const pathMatches = collectPathSemanticMatches(input.pathSegments);
  pathMatches.forEach((match: PathSemanticSignalMatch) => {
    signals.push(match.signal);
    if (match.mediaType === 'tv') {
      tvScore += match.signal.weight ?? 0;
    } else {
      movieScore += match.signal.weight ?? 0;
    }
  });

  if (tvScore > 0 && movieScore > 0 && Math.abs(tvScore - movieScore) < 25) {
    return createMediaTypeClassificationResult('unknown', signals, 'conflicting-signals');
  }

  if (tvScore >= 60 && tvScore > movieScore) {
    return createMediaTypeClassificationResult('tv', signals, 'path-tv-semantics');
  }

  if (movieScore >= 70 && movieScore > tvScore && !hasWeakSemanticTitle) {
    return createMediaTypeClassificationResult('movie', signals, 'movie-title-or-path');
  }

  if (tvScore > 0 && movieScore === 0) {
    return createMediaTypeClassificationResult('tv', signals, 'path-tv-semantics');
  }

  if (movieScore > 0 && tvScore === 0 && !hasWeakSemanticTitle) {
    return createMediaTypeClassificationResult('movie', signals, 'movie-title-or-path');
  }

  if (input.seasonSiblingDetected === true && isWeakSemanticTitleText(fileNameInfo?.title ?? input.fileName)) {
    appendSignal(
      signals,
      'path-semantics',
      input.parentDirectoryName ?? input.filePath,
      'path:season-sibling-detected',
      60
    );
    return createMediaTypeClassificationResult('tv', signals, 'season-sibling-detected');
  }

  return createMediaTypeClassificationResult('unknown', signals, 'insufficient-evidence');
}
