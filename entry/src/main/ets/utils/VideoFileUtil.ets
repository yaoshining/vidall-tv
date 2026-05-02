/**
 * 视频文件扩展名集合与工具函数（共享）。
 * 供文件浏览器页、FileExplorerContext 等处统一复用，避免各处维护各自的扩展名列表。
 */
export const SUPPORTED_VIDEO_EXTENSIONS: string[] = [
  '.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts', '.m2ts', '.mts'
];

/**
 * 判断文件名是否属于受支持的视频格式（大小写不敏感）。
 */
export function isVideoFile(fileName: string): boolean {
  const lower = fileName.toLowerCase();
  for (let i = 0; i < SUPPORTED_VIDEO_EXTENSIONS.length; i++) {
    if (lower.endsWith(SUPPORTED_VIDEO_EXTENSIONS[i])) {
      return true;
    }
  }
  return false;
}
