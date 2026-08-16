import cryptoFramework from '@ohos.security.cryptoFramework';
import buffer from '@ohos.buffer';
import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import { emitter, BusinessError } from '@kit.BasicServicesKit';
import { OpenSubtitlesClient, SubtitleDownloadError } from '../lib/OpenSubtitlesClient';
import { SubtitleCacheManager, CachedSubtitleEntry } from './SubtitleCacheManager';

// ─────────────────────────────────────────────
// 事件 ID 常量
// ─────────────────────────────────────────────

/** 字幕下载完成事件 ID（通过 emitter 通知 UI 刷新） */
export const SUBTITLE_DOWNLOADED_EVENT_ID: number = 10031;

// ─────────────────────────────────────────────
// 公共接口类型
// ─────────────────────────────────────────────

export interface DownloadResult {
  /** 写入后的本地绝对路径 */
  localPath: string;
  fileName: string;
}

/**
 * 最小上下文接口，只需 filesDir 属性。
 * 实际使用时传入 UIAbilityContext；测试时可传入简单对象。
 */
export interface SubtitleStorageContext {
  readonly filesDir: string;
}

// ─────────────────────────────────────────────
// SHA-256 工具函数（可单独测试）
// ─────────────────────────────────────────────

/**
 * 计算字符串的 SHA-256 摘要，返回前 16 字节的十六进制字符串（32 个字符）。
 */
export async function sha256Hex(input: string): Promise<string> {
  try {
    const md = cryptoFramework.createMd('SHA256');
    const inputBuf = buffer.from(input, 'utf-8');
    const dataBlob: cryptoFramework.DataBlob = {
      data: new Uint8Array(inputBuf.buffer)
    };
    await md.update(dataBlob);
    const digest = await md.digest();
    // 取前 16 字节转 hex（= 32 个十六进制字符）
    const bytes = digest.data.slice(0, 16);
    let hex = '';
    for (let i = 0; i < bytes.length; i++) {
      hex += bytes[i].toString(16).padStart(2, '0');
    }
    // 若 cryptoFramework mock 返回空数据（测试环境），回退到 JS 实现
    if (hex.length === 32) {
      return hex;
    }
  } catch (e) {
    // cryptoFramework 在测试环境不可用，回退到纯 JS 实现
  }
  return jsFallbackHash(input);
}

/** 纯 JS FNV-1a 哈希回退（仅在 cryptoFramework 不可用时使用）。
 *  产生 32 个十六进制字符（4 × 32-bit 哈希拼接）。 */
function jsFallbackHash(input: string): string {
  const FNV_PRIME = 16777619;
  const seeds: number[] = [2166136261, 0x811c9dc5, 0xdeadbeef, 0x1234abcd];
  const parts: string[] = [];
  for (let s = 0; s < seeds.length; s++) {
    let h: number = seeds[s];
    for (let i = s; i < input.length + s; i++) {
      h = h ^ input.charCodeAt(i % input.length);
      h = Math.imul(h, FNV_PRIME) >>> 0;
    }
    parts.push((h >>> 0).toString(16).padStart(8, '0'));
  }
  return parts.join('');
}

// ─────────────────────────────────────────────
// 路径构造工具函数（可单独测试）
// ─────────────────────────────────────────────

/**
 * 构造字幕本地存储目录路径。
 * 规范：{filesDir}/subtitles/{sourceType}_{sourceId}/{filePathHash}
 */
export function buildSubtitleDir(
  filesDir: string,
  sourceType: string,
  sourceId: string,
  filePathHash: string
): string {
  return `${filesDir}/subtitles/${sourceType}_${sourceId}/${filePathHash}`;
}

/**
 * 构造字幕本地存储完整路径。
 * 规范：{filesDir}/subtitles/{sourceType}_{sourceId}/{filePathHash}/{fileName}
 */
export function buildSubtitlePath(
  filesDir: string,
  sourceType: string,
  sourceId: string,
  filePathHash: string,
  fileName: string
): string {
  return `${buildSubtitleDir(filesDir, sourceType, sourceId, filePathHash)}/${fileName}`;
}

/**
 * 将字幕二进制内容写入本地规范路径（OpenSubtitles 与 SubHub 下载共用）。
 * 规范：{filesDir}/subtitles/{sourceType}_{sourceId}/{filePathHash}/{fileName}
 * 返回写入后的本地绝对路径。
 */
export async function writeSubtitleContentToCache(
  filesDir: string,
  sourceType: string,
  sourceId: string,
  videoPath: string,
  fileName: string,
  content: ArrayBuffer
): Promise<string> {
  // 拒绝路径片段/目录穿越：fileName 只接受单个文件名
  if (fileName.length === 0 || fileName === '.' || fileName === '..'
    || fileName.includes('/') || fileName.includes('\\')) {
    throw new SubtitleDownloadError('字幕文件名非法');
  }
  const filePathHash = await sha256Hex(videoPath);
  const dirPath = buildSubtitleDir(filesDir, sourceType, sourceId, filePathHash);
  const localPath = buildSubtitlePath(filesDir, sourceType, sourceId, filePathHash, fileName);

  // 递归创建目录（目录已存在时忽略 EEXIST）
  try {
    fs.mkdirSync(dirPath, true);
  } catch (e) {
    const be = e as BusinessError;
    if (be.code !== 13900015) {
      console.warn(`[SubtitleDownloader] mkdirSync warning code=${be.code}: ${be.message}`);
    }
  }

  const fileHandle = fs.openSync(localPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(fileHandle.fd, content);
  } catch (e) {
    fs.closeSync(fileHandle);
    const be = e as BusinessError;
    throw new SubtitleDownloadError(`字幕文件写入失败: ${be.message ?? JSON.stringify(e)}`);
  }
  fs.closeSync(fileHandle);
  return localPath;
}

// ─────────────────────────────────────────────
// SubtitleDownloader
// ─────────────────────────────────────────────

export class SubtitleDownloader {
  private readonly context: SubtitleStorageContext;
  private readonly client: OpenSubtitlesClient;
  private readonly cacheManager: SubtitleCacheManager;

  constructor(
    context: SubtitleStorageContext,
    client?: OpenSubtitlesClient,
    cacheManager?: SubtitleCacheManager
  ) {
    this.context = context;
    if (client !== undefined) {
      this.client = client;
    } else {
      this.client = new OpenSubtitlesClient();
    }
    if (cacheManager !== undefined) {
      this.cacheManager = cacheManager;
    } else {
      this.cacheManager = new SubtitleCacheManager();
    }
  }

  /**
   * 下载字幕文件并持久化到本地。
   *
   * @param fileId            OpenSubtitles file_id
   * @param videoPath         视频完整路径（用于计算存储目录 hash）
   * @param sourceType        文件源类型字符串（如 "webdav"）
   * @param sourceId          文件源 ID 字符串
   * @param language          字幕语言（可选，用于 metadata 记录）
   * @param subDownloadCount  字幕下载量（可选，用于 metadata 记录）
   * @returns 写入完成后的本地路径与文件名
   * @throws SubtitleDownloadError 下载或写入失败时抛出
   */
  async download(
    fileId: number,
    videoPath: string,
    sourceType: string,
    sourceId: string,
    language?: string,
    subDownloadCount?: number
  ): Promise<DownloadResult> {
    // Task 4.2 - 获取下载链接
    const linkInfo = await this.client.getDownloadLink(fileId);
    const link = linkInfo.link;
    const fileName = linkInfo.fileName;

    // Task 4.3 - 下载文件内容（ArrayBuffer）
    let arrayBuffer: ArrayBuffer;
    const req = http.createHttp();
    try {
      const resp = await req.request(link, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000,
        readTimeout: 60000
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        throw new SubtitleDownloadError(`字幕文件下载失败: HTTP ${resp.responseCode}`);
      }
      arrayBuffer = resp.result as ArrayBuffer;
    } catch (e) {
      req.destroy();
      if (e instanceof SubtitleDownloadError) {
        throw e;
      }
      const be = e as BusinessError;
      throw new SubtitleDownloadError(`字幕文件下载异常: ${be.message ?? JSON.stringify(e)}`);
    }

    // Task 4.3 - 计算路径 hash 并写入文件
    const localPath = await writeSubtitleContentToCache(
      this.context.filesDir, sourceType, sourceId, videoPath, fileName, arrayBuffer
    );

    const result: DownloadResult = {
      localPath: localPath,
      fileName: fileName
    };

    // Task 4.4 - 发布下载完成事件
    emitter.emit({ eventId: SUBTITLE_DOWNLOADED_EVENT_ID }, {
      data: { localPath: result.localPath, fileName: result.fileName }
    });

    // 写入字幕缓存 metadata（fire-and-forget，失败不影响下载结果）
    const cacheEntry: CachedSubtitleEntry = {
      fileName: fileName,
      language: language ?? '',
      downloadedAt: new Date().toISOString(),
      source: 'opensubtitles',
      subDownloadCount: subDownloadCount ?? 0
    };
    this.cacheManager.saveSubtitle(
      this.context.filesDir, sourceType, sourceId, videoPath, cacheEntry
    ).catch(() => {
      console.warn('[SubtitleDownloader] saveSubtitle 失败（非致命）');
    });

    console.info(`[SubtitleDownloader] 字幕已写入: ${localPath}`);
    return result;
  }
}
