/**
 * 媒体格式化工具函数（详情页 / 播放上下文共享）。
 *
 * 从 MovieDetailPage / SeasonDetailPage / SeriesDetailPage / PlaybackContext
 * 抽取的纯函数，用于消除重复实现。均为纯函数，无状态、无副作用。
 */

/**
 * 按指定宽度档位构造 TMDB 图片 URL。
 * width 取值：'w185' | 'w300' | 'w342' | 'w500' | 'w780' | 'w1280' | 'original'
 */
export function tmdbImageUrl(path: string | undefined, width: string): string {
  if (!path || path.length === 0) { return ''; }
  return `https://image.tmdb.org/t/p/${width}${path}`;
}

/** 取日期字符串的前 4 位作为年份；无效输入返回空串。 */
export function formatYear(date: string | undefined): string {
  if (!date || date.length < 4) { return ''; }
  return date.substring(0, 4);
}

/** 解析类型 JSON 数组；解析失败返回空数组。 */
export function parseGenresArr(json: string | undefined): string[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as string[]; } catch (e) { return []; }
}

/** 将 TMDB crew job 翻译为中文职位；未匹配时原样返回。 */
export function translateJob(job: string): string {
  if (job === 'Director') { return '导演'; }
  if (job === 'Writer' || job === 'Screenplay' || job === 'Story') { return '编剧'; }
  if (job === 'Editor') { return '剪辑师'; }
  if (job === 'Director of Photography') { return '摄影指导'; }
  if (job === 'Producer') { return '制片人'; }
  if (job === 'Executive Producer') { return '执行制片人'; }
  if (job === 'Composer' || job === 'Original Music Composer') { return '作曲'; }
  if (job === 'Art Direction' || job === 'Production Design') { return '艺术指导'; }
  if (job === 'Costume Design') { return '服装设计'; }
  if (job === 'Casting') { return '选角导演'; }
  if (job === 'Visual Effects Supervisor') { return '视效总监'; }
  return job;
}

/** 季号转中文季名：0 或负数 → 特别篇，1~20 → 第X季，更大 → 第N季。 */
export function toChineseSeasonLabel(n: number): string {
  if (n <= 0) { return '特别篇'; }
  const chineseNums = ['零','一','二','三','四','五','六','七','八','九','十',
    '十一','十二','十三','十四','十五','十六','十七','十八','十九','二十'];
  if (n < chineseNums.length) {
    return `第${chineseNums[n]}季`;
  }
  return `第${n}季`;
}

/** 构造集代码（S季:E集），负数归一为 0。 */
export function buildEpisodeCode(seasonNumber: number, episodeNumber: number): string {
  const sn = seasonNumber > 0 ? seasonNumber : 0;
  const en = episodeNumber > 0 ? episodeNumber : 0;
  return `S${sn}:E${en}`;
}

/** 判断季名是否为通用季名（如 "season 1" / "第1季" / "第一季"）。 */
export function isGenericSeasonTitle(title: string, n: number): boolean {
  const t = title.trim().toLowerCase();
  if (/^season\s*\d+$/.test(t)) { return true; }
  if (/^第\s*\d+\s*季$/.test(t)) { return true; }
  const chineseNums = ['零','一','二','三','四','五','六','七','八','九','十',
    '十一','十二','十三','十四','十五','十六','十七','十八','十九','二十'];
  if (n >= 0 && n < chineseNums.length) {
    if (t === `第${chineseNums[n]}季`) { return true; }
  }
  return false;
}

/** 将 #RRGGBB 转为完全不透明的 #FFRRGGBB（ARGB 8 位）。 */
export function toOpaqueColor(hex: string): string {
  return '#FF' + hex.substring(1);
}
