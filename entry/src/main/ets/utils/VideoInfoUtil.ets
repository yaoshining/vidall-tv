/**
 * VideoInfoUtil.ets
 *
 * 统一的视频轨道信息获取工具。
 *
 * 路由逻辑：
 *   - smb:// URL → FfprobeUtil.probe()（AVPlayer 不支持 SMB 协议）
 *   - http/https URL → FfprobeUtil.probe()（与 VideoScannerUtil 行为一致）
 *
 * SMB 认证说明：
 *   libsmb2 / FFmpeg 通过 URL 内嵌凭据识别 SMB 鉴权：
 *     smb://username:password@host/share/path
 *   调用方（如 SMBAdapter）负责将用户名密码拼入 URL；
 *   本工具不额外处理 SMB 凭据，直接将 URL 透传给 FfprobeUtil。
 *
 * 返回类型：
 *   VideoInfo = FfprobeResult，包含 videoTracks / audioTracks / subtitleTracks 等字段，
 *   与 VideoScannerUtil（WebDAV 路径）保持完全一致。
 */

import { FfprobeUtil, FfprobeResult } from './FfprobeUtil';

/**
 * VideoInfo 是 FfprobeResult 的类型别名。
 * 两条路径（HTTP 与 SMB）均返回相同结构，调用方无需区分来源。
 */
export type VideoInfo = FfprobeResult;

// 重新导出 FfprobeTrack，方便调用方访问轨道类型
export { FfprobeTrack } from './FfprobeUtil';

export class VideoInfoUtil {
  /**
   * 获取视频轨道信息（分辨率、编码、音轨列表、字幕列表等）。
   *
   * @param url       视频 URL
   *   - HTTP/HTTPS：如 "http://192.168.1.1:5005/dav/movie.mkv"
   *   - SMB：如 "smb://user:pass@192.168.1.100/Movies/movie.mkv"
   *     （认证信息需由调用方嵌入 URL）
   * @param headers   HTTP 请求头，仅对 http/https 生效；SMB 路径忽略此参数
   * @param timeoutMs 探测超时时间（毫秒），默认 20000
   * @returns         VideoInfo（即 FfprobeResult），包含 success 标志与轨道列表
   */
  static async getVideoInfo(
    url: string,
    headers?: Record<string, string>,
    timeoutMs: number = 20000
  ): Promise<VideoInfo> {
    const isSmbUrl: boolean = url.toLowerCase().startsWith('smb://');

    if (isSmbUrl) {
      // SMB 路径：AVPlayer 不支持 smb:// 协议，直接走 FfprobeUtil
      // 认证凭据应已嵌入 URL（smb://user:pass@host/share/path），
      // HTTP headers 对 SMB 无效，不传入。
      console.info(`[VideoInfoUtil] SMB URL → FfprobeUtil: ${VideoInfoUtil.maskSmbCredentials(url)}`);
      return FfprobeUtil.probe(url, undefined, timeoutMs);
    }

    // HTTP/HTTPS 路径：透传 headers（Authorization 等），与 VideoScannerUtil 行为保持一致
    console.info(`[VideoInfoUtil] HTTP URL → FfprobeUtil: ${url}`);
    return FfprobeUtil.probe(url, headers, timeoutMs);
  }

  /**
   * 对日志输出中的 SMB URL 做凭据脱敏：
   *   smb://user:secret@host/share → smb://***@host/share
   */
  private static maskSmbCredentials(url: string): string {
    // 匹配 smb://user:pass@host 或 smb://user@host 格式
    const atIdx: number = url.indexOf('@');
    if (atIdx < 0) {
      return url;
    }
    const protoEnd: number = url.indexOf('://');
    if (protoEnd < 0 || atIdx < protoEnd) {
      return url;
    }
    const proto: string = url.substring(0, protoEnd + 3); // "smb://"
    const rest: string = url.substring(atIdx);             // "@host/share/..."
    return `${proto}***${rest}`;
  }
}
