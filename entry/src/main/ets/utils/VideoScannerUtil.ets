import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType } from '../db/models/FileSourceEntity';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { WebDAVClient, WebDAVConfig, WebDAVResource } from '../lib/WebDAVClient';
import { VideoInfoUtil } from './VideoInfoUtil';

// ─────────────────────────────────────────────
// 数据结构
// ─────────────────────────────────────────────

/** 扫描到的单个视频文件信息 */
export interface VideoFileInfo {
  /** 所属文件源 ID */
  sourceId: number;
  /** 所属文件源名称 */
  sourceName: string;
  /** 文件源类型 */
  sourceType: FileSourceType;
  /** 扫描起始目录路径 */
  directoryPath: string;
  /** 文件完整路径（用于去重） */
  filePath: string;
  /** 文件名 */
  fileName: string;
  /** 文件大小（字节），可能为 undefined */
  fileSize?: number;
  /** 最后修改时间字符串 */
  lastModified?: string;
  /** MIME 类型 */
  contentType?: string;
}

/** 每个文件源的扫描统计 */
export interface SourceScanStat {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoriesScanned: number;
  videosFound: number;
}

/** 扫描汇总结果 */
export interface ScanResult {
  /** 实际扫描的目录总数 */
  totalDirectories: number;
  /** 去重后发现的视频总数 */
  totalVideos: number;
  /** 各文件源统计 */
  perSourceStats: SourceScanStat[];
  /** 总耗时（毫秒） */
  elapsedMs: number;
  /** 所有视频文件信息列表 */
  videos: VideoFileInfo[];
}

/** 扫描选项 */
export interface ScanOptions {
  /**
   * 最大递归深度，默认 5 层
   * 后续可在 UI 设置页或数据库目录表中按目录/文件源自定义
   */
  maxDepth: number;
}

/** 默认扫描选项 */
const DEFAULT_SCAN_OPTIONS: ScanOptions = {
  maxDepth: 5
};

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
  // 通过 contentType 判断
  if (contentType && contentType.toLowerCase().startsWith('video/')) {
    return true;
  }
  // 通过扩展名判断
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
// 适配器接口（统一扩展点）
// ─────────────────────────────────────────────

/**
 * 文件源适配器接口
 * 每种协议实现该接口，VideoScannerUtil 通过此接口统一调用
 */
export interface ISourceAdapter {
  /**
   * 扫描指定目录，返回该目录下（含子目录）所有视频文件信息
   * @param directoryPath 起始目录路径
   * @param options       扫描选项
   */
  scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]>;
}

// ─────────────────────────────────────────────
// WebDAV 适配器
// ─────────────────────────────────────────────

export class WebDAVAdapter implements ISourceAdapter {
  private client: WebDAVClient;
  private fileSource: FileSource;
  /** WebDAV 挂载根路径，如 /dav，用于剥离 href 中的前缀 */
  private basePath: string;

  constructor(fileSource: FileSource) {
    this.fileSource = fileSource;

    const config = JSON.parse(fileSource.configJson) as Record<string, string>;

    // baseUrl = protocol://host:port/rootPath
    // WebDAVClient.listDirectory(path) 内部会把 baseUrl 里的路径部分提取出来再拼 path
    // 所以 baseUrl 必须带 rootPath，传入 listDirectory 的 path 只传相对于 rootPath 的路径
    const protocol = config['protocol'] ?? 'http';
    const host = config['url'] ?? '';
    const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
    const rootPath = config['rootPath'] ?? '';
    const normalizedRoot = rootPath && !rootPath.startsWith('/') ? '/' + rootPath : rootPath;
    this.basePath = normalizedRoot.replace(/\/$/, ''); // 去掉末尾斜杠，便于后续 startsWith 匹配
    const baseUrl = `${protocol}://${host}:${port}${normalizedRoot}`;

    console.info(
      `[VideoScanner][WebDAV] 解析配置 — protocol="${protocol}" ` +
      `host="${host}" port="${port}" rootPath="${normalizedRoot}" ` +
      `baseUrl="${baseUrl}" username="${config['username'] ?? '(空)'}"`
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
    console.info(`[VideoScanner][WebDAV] 开始扫描目录: ${directoryPath}，文件源: ${this.fileSource.name}，最大深度: ${options.maxDepth}`);
    const results: VideoFileInfo[] = [];
    // depth=0 表示配置目录本身，进入子目录后变为 1、2...
    // maxDepth=5 表示从配置目录往下最多递归 5 层
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
      // href 是服务器返回的完整路径（含 basePath 前缀），需剥离后才能再次传给 listDirectory
      const decodedHref = this.decodePath(resource.href);
      // 用于传给 listDirectory 的相对路径
      const relativePath = this.toRelativePath(decodedHref);

      // 跳过当前目录自身
      if (this.isSamePath(relativePath, currentPath)) {
        continue;
      }

      if (resource.isCollection) {
        // 是子目录
        if (depth >= maxDepth) {
          console.info(`[VideoScanner][MAX_DEPTH] 已达最大深度 ${maxDepth}，跳过子目录: ${relativePath}`);
          continue;
        }
        await this.scanDir(rootPath, relativePath, depth + 1, maxDepth, results);
      } else {
        // 是文件，判断是否为视频
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
            `文件源=${this.fileSource.name} | ` +
            `路径=${decodedHref} | ` +
            `文件名=${fileName} | ` +
            `大小=${resource.size !== undefined ? resource.size + ' bytes' : '未知'} | ` +
            `修改时间=${resource.lastModified ?? '未知'} | ` +
            `类型=${resource.contentType ?? '未知'}`
          );

          results.push(info);

          // 异步抓取媒体详细信息（不阻塞扫描主流程，失败只打印警告）
          const authHeader = this.client.getAuthHeaderPublic();
          const httpHeader: Record<string, string> = authHeader ? { 'Authorization': authHeader } : {};
          const fullUrl = this.client.getFullUrl(relativePath);
          VideoInfoUtil.fetch(fullUrl, httpHeader).then((videoInfo) => {
            if (videoInfo.success) {
              console.info(
                `[VideoScanner][MEDIA] ${fileName} | ` +
                `时长=${videoInfo.durationText} | ` +
                `分辨率=${videoInfo.width ?? '?'}x${videoInfo.height ?? '?'} | ` +
                `编码=${videoInfo.videoCodec ?? '?'} | ` +
                `帧率=${videoInfo.frameRate ?? '?'}fps | ` +
                `码率=${videoInfo.bitrate !== undefined ? Math.round(videoInfo.bitrate / 1000) + 'kbps' : '?'} | ` +
                `音轨=${videoInfo.audioTracks.length} 字幕轨=${videoInfo.subtitleTracks.length}`
              );
              videoInfo.audioTracks.forEach((t, i) => {
                console.info(
                  `[VideoScanner][MEDIA]   音轨[${i}] codec=${t.codec ?? '?'} ` +
                  `${t.sampleRate ?? '?'}Hz ${t.channelCount ?? '?'}ch 语言=${t.language ?? '?'}`
                );
              });
              videoInfo.subtitleTracks.forEach((t, i) => {
                console.info(
                  `[VideoScanner][MEDIA]   字幕轨[${i}] codec=${t.codec ?? '?'} 语言=${t.language ?? '?'}`
                );
              });
            } else {
              console.warn(`[VideoScanner][MEDIA] 媒体信息抓取失败: ${fileName} — ${videoInfo.errorMessage ?? ''}`);
            }
          });
        }
      }
    }
  }

  /** 将 href 路径解码 */
  private decodePath(href: string): string {
    try {
      return decodeURIComponent(href);
    } catch {
      return href;
    }
  }

  /**
   * 把服务器返回的完整路径（含 basePath 前缀）剥离为相对路径
   * 例：basePath=/dav，href=/dav/nas/movie/ → /nas/movie/
   */
  private toRelativePath(fullPath: string): string {
    if (this.basePath && fullPath.startsWith(this.basePath)) {
      const rel = fullPath.substring(this.basePath.length);
      return rel.startsWith('/') ? rel : '/' + rel;
    }
    return fullPath;
  }

  /** 判断两个路径是否等价（忽略末尾斜杠） */
  private isSamePath(a: string, b: string): boolean {
    return a.replace(/\/$/, '') === b.replace(/\/$/, '');
  }

  /** 从路径中提取文件名 */
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

function createAdapter(fileSource: FileSource): ISourceAdapter {
  switch (fileSource.type) {
    case FileSourceType.WEBDAV:
      return new WebDAVAdapter(fileSource);
    // 预留：后续各协议在此添加对应 case
    // case FileSourceType.SMB:
    //   return new SMBAdapter(fileSource);
    // case FileSourceType.ALIYUN:
    //   return new AliyunAdapter(fileSource);
    // case FileSourceType.BAIDU:
    //   return new BaiduAdapter(fileSource);
    // case FileSourceType.CLOUD_123:
    //   return new Cloud123Adapter(fileSource);
    // case FileSourceType.CLOUD_139:
    //   return new Cloud139Adapter(fileSource);
    // case FileSourceType.CLOUD_115:
    //   return new Cloud115Adapter(fileSource);
    default:
      return new UnsupportedAdapter(fileSource.name, fileSource.type);
  }
}

// ─────────────────────────────────────────────
// 核心扫描工具类
// ─────────────────────────────────────────────

/**
 * 视频扫描工具
 *
 * 使用方式：
 * ```typescript
 * const result = await VideoScannerUtil.scan(context);
 * // 或自定义深度
 * const result = await VideoScannerUtil.scan(context, { maxDepth: 3 });
 * ```
 */
export class VideoScannerUtil {
  /**
   * 扫描所有已配置文件源中的视频文件
   * @param context   鸿蒙 Context，用于初始化数据库
   * @param options   扫描选项（可选，默认 maxDepth=5）
   * @returns         扫描汇总结果
   */
  static async scan(context: Context, options?: Partial<ScanOptions>): Promise<ScanResult> {
    const scanOptions: ScanOptions = {
      maxDepth: (options?.maxDepth !== undefined) ? options.maxDepth : DEFAULT_SCAN_OPTIONS.maxDepth
    };

    const startTime = Date.now();
    console.info(`[VideoScanner] ======== 开始视频扫描 ========`);
    console.info(`[VideoScanner] 扫描参数: maxDepth=${scanOptions.maxDepth}`);

    // ① 初始化数据库
    const db = FileSourceDatabase.getInstance(context);
    await db.init();

    // ② 读取所有文件源
    const fileSources = await db.getAllFileSources();
    console.info(`[VideoScanner] 共找到 ${fileSources.length} 个文件源`);

    // 用于去重的路径集合
    const seenPaths = new Set<string>();

    // 汇总数据
    const allVideos: VideoFileInfo[] = [];
    const perSourceStats: SourceScanStat[] = [];
    let totalDirectories = 0;

    // ③ 逐文件源扫描
    for (const fileSource of fileSources) {
      if (!fileSource.id) {
        continue;
      }

      console.info(`[VideoScanner] ──── 文件源: "${fileSource.name}" (${fileSource.type}) ────`);

      // 读取该文件源下所有目录配置
      let directories: FileSourceDirectory[] = [];
      try {
        directories = await db.getDirectoriesBySourceId(fileSource.id);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 读取文件源 "${fileSource.name}" 的目录列表失败: ${JSON.stringify(err)}`);
        continue;
      }

      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 配置了 ${directories.length} 个目录`);

      let adapter: ISourceAdapter;
      try {
        console.info(`[VideoScanner] 正在创建适配器，协议=${fileSource.type}`);
        adapter = createAdapter(fileSource);
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

      // ④ 逐目录扫描
      for (const dir of directories) {
        totalDirectories++;
        stat.directoriesScanned++;

        console.info(`[VideoScanner] 准备扫描目录(${stat.directoriesScanned}/${directories.length}): ${dir.directoryPath}`);

        let found: VideoFileInfo[] = [];
        try {
          found = await adapter.scan(dir.directoryPath, scanOptions);
          console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 扫描完毕，本次找到 ${found.length} 个视频`);
        } catch (err) {
          console.error(`[VideoScanner][ERROR] 扫描目录 "${dir.directoryPath}" 时发生异常: ${JSON.stringify(err)}`);
          continue;
        }

        // ⑤ 去重后加入结果
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
      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 扫描完成，发现 ${stat.videosFound} 个视频（扫描了 ${stat.directoriesScanned} 个目录）`);
    }

    const elapsedMs = Date.now() - startTime;

    // ⑥ 打印统计汇总
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



