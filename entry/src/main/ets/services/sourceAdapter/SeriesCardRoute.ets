// filepath: entry/src/main/ets/services/sourceAdapter/SeriesCardRoute.ets
//
// SeriesCardRoute - 媒体库「系列卡片」点击行为契约（纯函数）。
//
// 目标：把 `MediaLibraryTab` 中 `SeriesCard` 的点击分流抽成可单测的纯函数，
// 避免行为契约散落在 UI build() 里。
//
// 约束：
// - 仅包含无副作用纯函数，不依赖 UI / 网络 / 具体详情页。
// - 行为与 `MediaLibraryTab` 中 `SeriesCard` wiring 保持一致（wiring 通过本模块解析）。

import type { SeriesGroup } from "../../db/models/MediaEntity";

/** 系列卡片可跳转的目标详情页；null 表示不跳转。 */
export type SeriesCardDestination = 'seriesDetail' | 'seasonDetail' | null;

/**
 * 解析系列卡片点击应跳转的详情页：
 * - showSeasonPoster=true（最近添加/混合列表，显示季海报+季号）：
 *   有季号 → 季详情页（展示该季）；
 *   无季号 → 剧集详情页（展示整部剧，修复「点击后无法打开」的问题）。
 * - showSeasonPoster=false（电视剧栏）：→ 剧集详情页。
 * - tvSeriesId 缺失时返回 null（不跳转，防止误进详情页）。
 */
export function resolveSeriesCardDestination(showSeasonPoster: boolean, group: SeriesGroup): SeriesCardDestination {
  if (group.tvSeriesId === undefined) {
    return null;
  }
  if (showSeasonPoster) {
    return group.seasonNumber !== undefined ? 'seasonDetail' : 'seriesDetail';
  }
  return 'seriesDetail';
}
