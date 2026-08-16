// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleProviderResolver.ets
//
// 决定本次字幕获取使用哪些 provider：
//   - 未配置 OPENSUBTITLES_API_KEY → 仅 SubHub
//   - 已配置 OPENSUBTITLES_API_KEY → OpenSubtitles（直连）+ SubHub

import { AppPreferences, PrefKey } from '../../../utils/AppPreferences';
import { SubtitleProvider } from './SubtitleProvider';
import { OpenSubtitlesSubtitleProvider } from './OpenSubtitlesSubtitleProvider';
import { SubHubSubtitleProvider } from './SubHubSubtitleProvider';

export class SubtitleProviderResolver {
  /** 按是否有 OpenSubtitles API Key 返回 provider 列表（OS 在前、SubHub 在后）。 */
  async resolveProviders(): Promise<SubtitleProvider[]> {
    const osKey = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '');
    const providers: SubtitleProvider[] = [];
    if (osKey.length > 0) {
      providers.push(new OpenSubtitlesSubtitleProvider());
    }
    providers.push(new SubHubSubtitleProvider());
    return providers;
  }
}
