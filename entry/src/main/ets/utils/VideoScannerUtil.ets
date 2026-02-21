import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType } from '../db/models/FileSourceEntity';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { WebDAVClient, WebDAVConfig, WebDAVResource } from '../lib/WebDAVClient';
import { VideoInfoUtil, TrackInfo } from './VideoInfoUtil';
import { ScrapeClient } from '../lib/ScrapeClient';
import { VideoEntity, ScrapeInfoEntity } from '../db/models/MediaEntity';

// ─────────────────────────────────────────────
// 数据结构
// ─────────────────────────────────────────────

/** 扫描到的单个视频文件信息 */
export interface VideoFileInfo {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoryPath: string;
  filePath: string;
  fileName: string;
  fileSize?: number;
  lastModified?: string;
  contentType?: string;
}

export interface SourceScanStat {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoriesScanned: number;
  videosFound: number;
}

export interface ScanResult {
  totalDirectories: number;
  totalVideos: number;
  perSourceStats: SourceScanStat[];
  elapsedMs: number;
  videos: VideoFileInfo[];
}

export interface ScanOptions {
  maxDepth: number;
}

const DEFAULT_SCAN_OPTIONS: ScanOptions = { maxDepth: 5 };

// ─────────────────────────────────────────────
// 视频扩展名白名单
// ─────────────────────────────────────────────

const VIDEO_EXTENSIONS: Set<string> = new Set([
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv',
  'ts', 'm2ts', 'mts', 'rmvb', 'rm', 'webm',
  'm4v', 'mpeg', 'mpg', '3gp', 'ogv', 'vob',
  'divx', 'xvid', 'hevc', 'h264', 'h265'
]);

function isVideoFile(fileName: string, contentType?: string): boolean {
  if (contentType && contentType.toLowerCase().startsWith('video/')) {
    return true;
  }
  const dotIndex = fileName.lastIndexOf('.');
  if (dotIndex !== -1) {
    const ext = fileName.substring(dotIndex + 1).toLowerCase();
    if (VIDEO_EXTENSIONS.has(ext)) {
      return true;
    }
  }
  return false;
}

// ─────────────────────────────────────────────
// 适配器接口
// ─────────────────────────────────────────────

export interface ISourceAdapter {
  scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]>;
}

// ─────────────────────────────────────────────
// WebDAV 适配器
// ─────────────────────────────────────────────

export class WebDAVAdapter implements ISourceAdapter {
  private client: WebDAVClient;
  private fileSource: FileSource;
  private basePath: string;
  private scrapeClient?: ScrapeClient;

  constructor(fileSource: FileSource, scrapeClient?: ScrapeClient) {
    this.fileSource = fileSource;
    this.scrapeClient = scrapeClient;

    const config = JSON.parse(fileSource.configJson) as Record<string, string>;
    const protocol = config['protocol'] ?? 'http';
    const host = config['url'] ?? '';
    const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
    const rootPath = config['rootPath'] ?? '';
    const normalizedRoot = rootPath && !rootPath.startsWith('/') ? '/' + rootPath : rootPath;
    this.basePath = normalizedRoot.replace(/\/$/, '');
    const baseUrl = `${protocol}://${host}:${port}${normalizedRoot}`;

    console.info(
      `[VideoScanner][WebDAV] 解析配置 — url="${host}" username="${config['username'] ?? ''}" rootPath="${normalizedRoot}"`
    );
    const webdavConfig: WebDAVConfig = {
      baseUrl: baseUrl,
      username: config['username'] ?? '',
      password: config['password'] ?? '',
      timeout: 30000
    };
    try {
      this.client = new WebDAVClient(webdavConfig);
      console.info(`[VideoScanner][WebDAV] WebDAVClient 构造成功`);
    } catch (err) {
      const msg = `WebDAVClient 构造失败: ${JSON.stringify(err)}`;
      console.error(`[VideoScanner][ERROR] ${msg}`);
      throw new Error(msg);
    }
  }

  async scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]> {
    console.info(`[VideoScanner][WebDAV] 开始扫描目录: ${directoryPath} 最大深度: ${options.maxDepth}`);
    const results: VideoFileInfo[] = [];
    await this.scanDir(directoryPath, directoryPath, 0, options.maxDepth, results);
    return results;
  }

  private async scanDir(
    rootPath: string,
    currentPath: string,
    depth: number,
    maxDepth: number,
    results: VideoFileInfo[]
  ): Promise<void> {
    console.info(`[VideoScanner][WebDAV] 进入目录: ${currentPath}（相对配置目录深度 ${depth}/${maxDepth}）`);

    let resources: WebDAVResource[] = [];
    try {
      resources = await this.client.listDirectory(currentPath);
    } catch (err) {
      console.error(`[VideoScanner][ERROR] 列举目录失败: ${currentPath}，原因: ${JSON.stringify(err)}`);
      return;
    }

    for (const resource of resources) {
      const decodedHref = this.decodePath(resource.href);
      const relativePath = this.toRelativePath(decodedHref);

      if (this.isSamePath(relativePath, currentPath)) {
        continue;
      }

      if (resource.isCollection) {
        if (depth >= maxDepth) {
          console.info(`[VideoScanner][MAX_DEPTH] 已达最大深度 ${maxDepth}，跳过子目录: ${relativePath}`);
          continue;
        }
        await this.scanDir(rootPath, relativePath, depth + 1, maxDepth, results);
      } else {
        const fileName = resource.displayName || this.extractFileName(decodedHref);
        if (isVideoFile(fileName, resource.contentType)) {
          const info: VideoFileInfo = {
            sourceId: this.fileSource.id ?? 0,
            sourceName: this.fileSource.name,
            sourceType: this.fileSource.type,
            directoryPath: rootPath,
            filePath: relativePath,
            fileName: fileName,
            fileSize: resource.size,
            lastModified: resource.lastModified,
            contentType: resource.contentType
          };

          console.info(
            `[VideoScanner][VIDEO] ` +
            `文件源=${this.fileSource.name} | 路径=${decodedHref} | 文件名=${fileName} | ` +
            `大小=${resource.size !== undefined ? resource.size + ' bytes' : '未知'} | ` +
            `修改时间=${resource.lastModified ?? '未知'} | 类型=${resource.contentType ?? '未知'}`
          );

          results.push(info);

          // ── 异步落库 + 刮削（不阻塞扫描主流程）────────────────
          const authHeader = this.client.getAuthHeaderPublic();
          const httpHeader: Record<string, string> = authHeader ? { 'Authorization': authHeader } : {};
          const fullUrl = this.client.getFullUrl(relativePath);
          const capturedInfo = info;
          const capturedScrapeClient = this.scrapeClient;

          VideoInfoUtil.fetch(fullUrl, httpHeader).then(async (videoInfo) => {
            if (videoInfo.success) {
              console.info(
                `[VideoScanner][MEDIA] ${fileName} | ` +
                `时长=${videoInfo.durationText} | ` +
                `分辨率=${videoInfo.width ?? '?'}x${videoInfo.height ?? '?'} | ` +
                `编码=${videoInfo.videoCodec ?? '?'} | ` +
                `帧率=${videoInfo.frameRate ?? '?'}fps | ` +
                `音轨=${videoInfo.audioTracks.length} 字幕轨=${videoInfo.subtitleTracks.length}`
              );
              videoInfo.audioTracks.forEach((t: TrackInfo, i: number) => {
                console.info(`[VideoScanner][MEDIA]   音轨[${i}] codec=${t.codec ?? '?'} ${t.sampleRate ?? '?'}Hz ${t.channelCount ?? '?'}ch 语言=${t.language ?? '?'}`);
              });
              videoInfo.subtitleTracks.forEach((t: TrackInfo, i: number) => {
                console.info(`[VideoScanner][MEDIA]   字幕轨[${i}] codec=${t.codec ?? '?'} 语言=${t.language ?? '?'}`);
              });
            } else {
              console.warn(`[VideoScanner][MEDIA] 媒体信息抓取失败: ${fileName} — ${videoInfo.errorMessage ?? ''}`);
            }

            // 落库
            const videoEntity: VideoEntity = {
              sourceId: capturedInfo.sourceId,
              directoryPath: capturedInfo.directoryPath,
              filePath: capturedInfo.filePath,
              fileName: capturedInfo.fileName,
              fileSize: capturedInfo.fileSize,
              lastModified: capturedInfo.lastModified,
              contentType: capturedInfo.contentType,
              durationMs: videoInfo.success ? videoInfo.durationMs : undefined,
              width: videoInfo.success ? videoInfo.width : undefined,
              height: videoInfo.success ? videoInfo.height : undefined,
              frameRate: videoInfo.success ? videoInfo.frameRate : undefined,
              videoCodec: videoInfo.success ? videoInfo.videoCodec : undefined,
              audioTracksJson: videoInfo.success ? JSON.stringify(videoInfo.audioTracks) : undefined,
              subtitleTracksJson: videoInfo.success ? JSON.stringify(videoInfo.subtitleTracks) : undefined,
              scannedAt: Date.now()
            };

            let videoId: number = -1;
            try {
              videoId = await FileSourceDatabase.getInstance().upsertVideo(videoEntity);
              console.info(`[VideoScanner][DB] 落库成功 videoId=${videoId} fileName=${fileName}`);
            } catch (dbErr) {
              console.warn(`[VideoScanner][DB] 落库失败 fileName=${fileName}: ${JSON.stringify(dbErr)}`);
              return;
            }

            // 刮削（已有记录跳过）
            if (!capturedScrapeClient) {
              return;
            }
            try {
              const existing = await FileSourceDatabase.getInstance().getScrapeInfoByVideoId(videoId);
              if (existing) {
                console.info(`[VideoScanner][SCRAPE] 已有刮削记录，跳过 fileName=${fileName} title="${existing.title}"`);
                return;
              }
            } catch {
              // 查询失败时继续尝试刮削
            }

            console.info(`[VideoScanner][SCRAPE] 开始刮削 fileName=${fileName}`);
            capturedScrapeClient.autoScrape(fileName).then(async (scrapeResult) => {
              if (!scrapeResult) {
                console.warn(`[VideoScanner][SCRAPE] 刮削无结果 fileName=${fileName}`);
                return;
              }
              console.info(
                `[VideoScanner][SCRAPE] 刮削成功 fileName=${fileName} | ` +
                `title="${scrapeResult.title}" | provider=${scrapeResult.provider} | ` +
                `type=${scrapeResult.mediaType} | rating=${scrapeResult.rating ?? '-'} | ` +
                `releaseDate=${scrapeResult.releaseDate ?? '-'} | posterUrl=${scrapeResult.posterUrl ?? '无'}`
              );
              const scrapeEntity: ScrapeInfoEntity = {
                videoId: videoId,
                provider: scrapeResult.provider,
                providerId: scrapeResult.providerId,
                mediaType: scrapeResult.mediaType,
                title: scrapeResult.title,
                originalTitle: scrapeResult.originalTitle,
                overview: scrapeResult.overview,
                releaseDate: scrapeResult.releaseDate,
                rating: scrapeResult.rating,
                genresJson: scrapeResult.genres ? JSON.stringify(scrapeResult.genres) : undefined,
                castJson: scrapeResult.cast ? JSON.stringify(scrapeResult.cast) : undefined,
                directorsJson: scrapeResult.directors ? JSON.stringify(scrapeResult.directors) : undefined,
                posterUrl: scrapeResult.posterUrl,
                backdropUrl: scrapeResult.backdropUrl,
                scrapedAt: Date.now()
              };
              try {
                await FileSourceDatabase.getInstance().upsertScrapeInfo(scrapeEntity);
                console.info(`[VideoScanner][SCRAPE] 入库成功 videoId=${videoId} title="${scrapeResult.title}"`);
              } catch (scrapeDbErr) {
                console.warn(`[VideoScanner][SCRAPE] 入库失败 fileName=${fileName}: ${JSON.stringify(scrapeDbErr)}`);
              }
            }).catch((scrapeErr: Error) => {
              console.warn(`[VideoScanner][SCRAPE] autoScrape 异常 fileName=${fileName}: ${scrapeErr.message}`);
            });
          });
        }
      }
    }
  }

  private decodePath(href: string): string {
    try {
      return decodeURIComponent(href);
    } catch {
      return href;
    }
  }

  private toRelativePath(fullPath: string): string {
    if (this.basePath && fullPath.startsWith(this.basePath)) {
      const rel = fullPath.substring(this.basePath.length);
      return rel.startsWith('/') ? rel : '/' + rel;
    }
    return fullPath;
  }

  private isSamePath(a: string, b: string): boolean {
    return a.replace(/\/$/, '') === b.replace(/\/$/, '');
  }

  private extractFileName(path: string): string {
    const parts = path.replace(/\/$/, '').split('/');
    return parts[parts.length - 1] ?? path;
  }
}

// ─────────────────────────────────────────────
// 不支持协议占位适配器
// ─────────────────────────────────────────────

export class UnsupportedAdapter implements ISourceAdapter {
  private sourceType: FileSourceType;
  private sourceName: string;

  constructor(sourceName: string, sourceType: FileSourceType) {
    this.sourceName = sourceName;
    this.sourceType = sourceType;
  }

  async scan(directoryPath: string, _options: ScanOptions): Promise<VideoFileInfo[]> {
    console.warn(
      `[VideoScanner][SKIP] 协议 "${this.sourceType}" 暂不支持，` +
      `文件源="${this.sourceName}"，目录="${directoryPath}"，跳过。`
    );
    return [];
  }
}

// ─────────────────────────────────────────────
// 适配器工厂
// ─────────────────────────────────────────────

function createAdapter(fileSource: FileSource, scrapeClient?: ScrapeClient): ISourceAdapter {
  switch (fileSource.type) {
    case FileSourceType.WEBDAV:
      return new WebDAVAdapter(fileSource, scrapeClient);
    default:
      return new UnsupportedAdapter(fileSource.name, fileSource.type);
  }
}

// ─────────────────────────────────────────────
// 核心扫描工具类
// ─────────────────────────────────────────────

export class VideoScannerUtil {
  /**
   * 扫描所有已配置文件源中的视频文件
   * @param context       鸿蒙 Context
   * @param scrapeClient  刮削客户端（可选，不传则跳过刮削）
   * @param options       扫描选项（可选，默认 maxDepth=5）
   */
  static async scan(context: Context, scrapeClient?: ScrapeClient, options?: Partial<ScanOptions>): Promise<ScanResult> {
    const scanOptions: ScanOptions = {
      maxDepth: (options?.maxDepth !== undefined) ? options.maxDepth : DEFAULT_SCAN_OPTIONS.maxDepth
    };

    const startTime = Date.now();
    console.info(`[VideoScanner] ======== 开始视频扫描 ========`);
    console.info(`[VideoScanner] 扫描参数: maxDepth=${scanOptions.maxDepth}, 刮削=${scrapeClient ? '开启' : '关闭'}`);

    const db = FileSourceDatabase.getInstance(context);
    await db.init();

    const fileSources = await db.getAllFileSources();
    console.info(`[VideoScanner] 共找到 ${fileSources.length} 个文件源`);

    const seenPaths = new Set<string>();
    const allVideos: VideoFileInfo[] = [];
    const perSourceStats: SourceScanStat[] = [];
    let totalDirectories = 0;

    for (const fileSource of fileSources) {
      if (!fileSource.id) {
        continue;
      }

      console.info(`[VideoScanner] ──── 文件源: "${fileSource.name}" (${fileSource.type}) ────`);

      let directories: FileSourceDirectory[] = [];
      try {
        directories = await db.getDirectoriesBySourceId(fileSource.id);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 读取文件源 "${fileSource.name}" 目录失败: ${JSON.stringify(err)}`);
        continue;
      }

      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 配置了 ${directories.length} 个目录`);

      let adapter: ISourceAdapter;
      try {
        console.info(`[VideoScanner] 正在创建适配器，协议=${fileSource.type}`);
        adapter = createAdapter(fileSource, scrapeClient);
        console.info(`[VideoScanner] 适配器创建成功`);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 创建适配器失败: ${JSON.stringify(err)}`);
        continue;
      }

      const stat: SourceScanStat = {
        sourceId: fileSource.id,
        sourceName: fileSource.name,
        sourceType: fileSource.type,
        directoriesScanned: 0,
        videosFound: 0
      };

      for (const dir of directories) {
        totalDirectories++;
        stat.directoriesScanned++;
        console.info(`[VideoScanner] 准备扫描目录(${stat.directoriesScanned}/${directories.length}): ${dir.directoryPath}`);

        let found: VideoFileInfo[] = [];
        try {
          found = await adapter.scan(dir.directoryPath, scanOptions);
          console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 扫描完毕，找到 ${found.length} 个视频`);
        } catch (err) {
          console.error(`[VideoScanner][ERROR] 扫描目录 "${dir.directoryPath}" 异常: ${JSON.stringify(err)}`);
          continue;
        }

        for (const video of found) {
          if (!seenPaths.has(video.filePath)) {
            seenPaths.add(video.filePath);
            allVideos.push(video);
            stat.videosFound++;
          } else {
            console.info(`[VideoScanner] 重复路径，已跳过: ${video.filePath}`);
          }
        }
      }

      perSourceStats.push(stat);
      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 完成，视频=${stat.videosFound} 目录=${stat.directoriesScanned}`);
    }

    const elapsedMs = Date.now() - startTime;
    console.info(`[VideoScanner] ======== 扫描完成 ========`);
    console.info(`[VideoScanner][STATS] 总耗时: ${elapsedMs} ms`);
    console.info(`[VideoScanner][STATS] 扫描目录总数: ${totalDirectories}`);
    console.info(`[VideoScanner][STATS] 发现视频总数（去重后）: ${allVideos.length}`);
    for (const stat of perSourceStats) {
      console.info(
        `[VideoScanner][STATS] 文件源="${stat.sourceName}" (${stat.sourceType}) | ` +
        `目录数=${stat.directoriesScanned} | 视频数=${stat.videosFound}`
      );
    }
    console.info(`[VideoScanner] ===========================`);

    return {
      totalDirectories,
      totalVideos: allVideos.length,
      perSourceStats,
      elapsedMs,
      videos: allVideos
    };
  }
}
