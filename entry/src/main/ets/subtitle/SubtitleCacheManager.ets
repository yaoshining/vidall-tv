import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { BusinessError } from '@kit.BasicServicesKit';
import { sha256Hex, buildSubtitleDir, buildSubtitlePath } from './SubtitleDownloader';

// ─────────────────────────────────────────────
// 公共接口类型
// ─────────────────────────────────────────────

/** 单条字幕缓存条目（对应 metadata.json 中 subtitles 数组的每个元素） */
export interface CachedSubtitleEntry {
  fileName: string;
  language: string;
  downloadedAt: string;
  source: string;
  subDownloadCount: number;
  /** 最后访问时间（用于 LRU 淘汰）；旧版 metadata 无此字段时降级为 downloadedAt */
  lastAccessedAt?: string;
}

/** metadata.json 整体结构 */
export interface SubtitleMetadata {
  videoPath: string;
  sourceId: string;
  /** 上次使用的字幕文件名（非完整路径） */
  lastUsed: string;
  subtitles: CachedSubtitleEntry[];
}

// ─────────────────────────────────────────────
// 最大缓存数量
// ─────────────────────────────────────────────

const MAX_CACHED_SUBTITLES = 10;
const METADATA_FILE_NAME = 'metadata.json';

// ─────────────────────────────────────────────
// SubtitleCacheManager
// ─────────────────────────────────────────────

/**
 * 字幕本地缓存管理器。
 *
 * 无状态设计：每次操作均从磁盘读取 metadata.json，不在内存中缓存。
 * 路径规范复用 SubtitleDownloader 中已导出的工具函数。
 */
export class SubtitleCacheManager {

  // ──────────────────────────────────────────
  // 私有工具方法
  // ──────────────────────────────────────────

  /**
   * 递归创建多级目录（目录已存在时忽略 EEXIST）。
   * 与 SubtitleDownloader.writeSubtitleContentToCache 保持一致的设备端验证模式。
   */
  private mkdirp(dirPath: string): void {
    try {
      fs.mkdirSync(dirPath, true);
    } catch (e) {
      const be = e as BusinessError;
      if (be.code !== 13900015) {
        throw new Error(`mkdirSync(${dirPath}) failed: ${be.message} (code: ${be.code})`);
      }
    }
  }

  /**
   * 读取并解析指定目录下的 metadata.json。
   * 文件不存在或 JSON 损坏时返回 null。
   */
  async readMetadata(dir: string): Promise<SubtitleMetadata | null> {
    const metaPath = `${dir}/${METADATA_FILE_NAME}`;
    try {
      const stat = fs.statSync(metaPath);
      if (!stat.isFile()) {
        return null;
      }
      const file = fs.openSync(metaPath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const readLen = fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const decoder = new util.TextDecoder('utf-8', { fatal: false, ignoreBOM: true });
      const text = decoder.decodeToString(new Uint8Array(buf, 0, readLen));
      const parsed = JSON.parse(text) as Record<string, string | CachedSubtitleEntry[]>;
      if (!parsed['videoPath'] || !parsed['subtitles']) {
        return null;
      }
      const metadata: SubtitleMetadata = {
        videoPath: parsed['videoPath'] as string,
        sourceId: (parsed['sourceId'] as string) ?? '',
        lastUsed: (parsed['lastUsed'] as string) ?? '',
        subtitles: (parsed['subtitles'] as CachedSubtitleEntry[]) ?? []
      };
      return metadata;
    } catch {
      return null;
    }
  }

  /**
   * 序列化并写入 metadata.json（覆盖写）。
   */
  async writeMetadata(dir: string, metadata: SubtitleMetadata): Promise<void> {
    const metaPath = `${dir}/${METADATA_FILE_NAME}`;
    this.mkdirp(dir);
    const text = JSON.stringify(metadata, null, 2);
    const encoder = new util.TextEncoder();
    const uint8Array = encoder.encodeInto(text);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(metaPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, uint8Array.buffer);
    } catch (e) {
      const be = e as BusinessError;
      throw new Error(`[SubtitleCacheManager] writeMetadata 失败: ${be.message}`);
    } finally {
      if (file !== null) {
        try { fs.closeSync(file); } catch (_ignored) {}
      }
    }
  }

  private async buildDir(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string
  ): Promise<string> {
    const hash = await sha256Hex(videoPath);
    return buildSubtitleDir(filesDir, sourceType, sourceId, hash);
  }

  // ──────────────────────────────────────────
  // 公开 API
  // ──────────────────────────────────────────

  /**
   * 保存字幕缓存条目并更新 metadata.json。
   *
   * - 同名 fileName 时覆盖（更新 downloadedAt）
   * - 超过 MAX_CACHED_SUBTITLES 时删除 downloadedAt 最早的条目及其文件
   * - 自动将 lastUsed 设为本次保存的 fileName
   */
  async saveSubtitle(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string,
    entry: CachedSubtitleEntry
  ): Promise<void> {
    try {
      const dir = await this.buildDir(filesDir, sourceType, sourceId, videoPath);
      let metadata = await this.readMetadata(dir);
      if (metadata === null) {
        const fresh: SubtitleMetadata = {
          videoPath,
          sourceId,
          lastUsed: entry.fileName,
          subtitles: []
        };
        metadata = fresh;
      }

      // 追加或覆盖（同名文件替换）
      let replaced = false;
      const now = new Date().toISOString();
      const entryWithAccess: CachedSubtitleEntry = {
        fileName: entry.fileName,
        language: entry.language,
        downloadedAt: entry.downloadedAt,
        source: entry.source,
        subDownloadCount: entry.subDownloadCount,
        lastAccessedAt: now
      };
      const updatedSubtitles: CachedSubtitleEntry[] = [];
      for (let i = 0; i < metadata.subtitles.length; i++) {
        if (metadata.subtitles[i].fileName === entry.fileName) {
          updatedSubtitles.push(entryWithAccess);
          replaced = true;
        } else {
          updatedSubtitles.push(metadata.subtitles[i]);
        }
      }
      if (!replaced) {
        updatedSubtitles.push(entryWithAccess);
      }
      metadata.subtitles = updatedSubtitles;
      metadata.lastUsed = entry.fileName;

      // LRU 清理：超过上限时删除最近最少使用（lastAccessedAt，无则降级为 downloadedAt）的条目
      while (metadata.subtitles.length > MAX_CACHED_SUBTITLES) {
        let oldestIdx = 0;
        for (let i = 1; i < metadata.subtitles.length; i++) {
          const timeI = metadata.subtitles[i].lastAccessedAt ?? metadata.subtitles[i].downloadedAt;
          const timeOldest = metadata.subtitles[oldestIdx].lastAccessedAt ?? metadata.subtitles[oldestIdx].downloadedAt;
          if (timeI < timeOldest) {
            oldestIdx = i;
          }
        }
        const oldest = metadata.subtitles[oldestIdx];
        const hash = await sha256Hex(videoPath);
        const oldPath = buildSubtitlePath(filesDir, sourceType, sourceId, hash, oldest.fileName);
        try {
          fs.unlinkSync(oldPath);
        } catch {
          // 文件不存在时忽略
        }
        // 若 lastUsed 指向被删除的文件，清除
        if (metadata.lastUsed === oldest.fileName) {
          metadata.lastUsed = '';
        }
        const remaining: CachedSubtitleEntry[] = [];
        for (let i = 0; i < metadata.subtitles.length; i++) {
          if (i !== oldestIdx) {
            remaining.push(metadata.subtitles[i]);
          }
        }
        metadata.subtitles = remaining;
      }

      await this.writeMetadata(dir, metadata);
    } catch (e) {
      throw new Error(`[SubtitleCacheManager] saveSubtitle 失败: ${String(e)}`);
    }
  }

  /**
   * 查询某视频的所有已缓存字幕。
   * metadata.json 不存在或损坏时返回空数组。
   */
  async listCachedSubtitles(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string
  ): Promise<CachedSubtitleEntry[]> {
    try {
      const dir = await this.buildDir(filesDir, sourceType, sourceId, videoPath);
      const metadata = await this.readMetadata(dir);
      if (metadata === null) {
        return [];
      }
      return metadata.subtitles;
    } catch {
      return [];
    }
  }

  /**
   * 读取上次使用的字幕完整本地路径。
   *
   * - lastUsed 为空或文件不存在 → 返回 null（并清除 lastUsed 字段）
   * - 文件存在 → 返回完整绝对路径
   */
  async getLastUsedSubtitle(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string
  ): Promise<string | null> {
    try {
      const dir = await this.buildDir(filesDir, sourceType, sourceId, videoPath);
      const metadata = await this.readMetadata(dir);
      if (metadata === null || metadata.lastUsed.length === 0) {
        return null;
      }
      const hash = await sha256Hex(videoPath);
      const fullPath = buildSubtitlePath(filesDir, sourceType, sourceId, hash, metadata.lastUsed);
      // 检查文件是否存在
      try {
        fs.statSync(fullPath);
        return fullPath;
      } catch {
        // 文件已被 LRU 清理或手动删除，清除 lastUsed
        metadata.lastUsed = '';
        await this.writeMetadata(dir, metadata);
        return null;
      }
    } catch {
      return null;
    }
  }

  /**
   * 更新 metadata.json 中的 lastUsed 字段。
   */
  async setLastUsedSubtitle(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string,
    fileName: string
  ): Promise<void> {
    try {
      const dir = await this.buildDir(filesDir, sourceType, sourceId, videoPath);
      const metadata = await this.readMetadata(dir);
      if (metadata === null) {
        return;
      }
      metadata.lastUsed = fileName;
      // 同步更新对应条目的访问时间，确保 LRU 淘汰不会删掉刚使用的字幕
      const accessTime = new Date().toISOString();
      for (let i = 0; i < metadata.subtitles.length; i++) {
        if (metadata.subtitles[i].fileName === fileName) {
          metadata.subtitles[i].lastAccessedAt = accessTime;
          break;
        }
      }
      await this.writeMetadata(dir, metadata);
    } catch (e) {
      console.error(`[SubtitleCacheManager] setLastUsedSubtitle 失败: ${String(e)}`);
    }
  }

  /**
   * 清除 metadata.json 中的 lastUsed 字段，但保留 subtitles 数组中已下载的字幕文件。
   *
   * 保留为公开 API 以备未来 UI 扩展（例如"已下载字幕列表"菜单）时使用。
   * 当前 `VideoPlayerController.switchSubtitleTrack(-1)` 不再调用本方法——
   * "关闭字幕"通过 `SubtitleDispatcher.clearUserBinding` 写入 `disabled` 标记实现，
   * 让 `SubtitleDispatcher.resolveSubtitle` 步骤 1 返回
   * `{ type: 'user-specified', trackIndex: -1 }`（显式关闭字幕，避免 adapter 自动选轨
   * 继续显示字幕），短路步骤 4 的 lastUsed 自动恢复。
   * metadata.json.lastUsed 与已下载字幕文件保持原样。
   *
   * 行为：
   * - 已有 metadata.json：清空 `lastUsed`，写回磁盘。subtitles 数组保持原样（已下载文件不被删除）。
   * - 无 metadata.json：静默返回。
   *
   * 不抛异常，失败仅 hilog.warn，不影响调用方主流程。
   */
  async clearLastUsedSubtitle(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string
  ): Promise<void> {
    try {
      const dir = await this.buildDir(filesDir, sourceType, sourceId, videoPath);
      const metadata = await this.readMetadata(dir);
      if (metadata === null) {
        return;
      }
      if (metadata.lastUsed.length === 0) {
        return;
      }
      metadata.lastUsed = '';
      await this.writeMetadata(dir, metadata);
    } catch (e) {
      console.error(`[SubtitleCacheManager] clearLastUsedSubtitle 失败: ${String(e)}`);
    }
  }

  /**
   * 删除某视频目录下的所有字幕文件及 metadata.json。
   * 目录不存在时静默返回。
   */
  async clearSubtitleCache(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string
  ): Promise<void> {
    try {
      const dir = await this.buildDir(filesDir, sourceType, sourceId, videoPath);
      try {
        fs.statSync(dir);
      } catch {
        // 目录不存在，静默返回
        return;
      }
      // 先按已知路径删除 metadata.json（不依赖 listFileSync 行为）
      try {
        fs.unlinkSync(`${dir}/${METADATA_FILE_NAME}`);
      } catch {
        // 不存在时忽略
      }
      // 再用 listFileSync 删除目录内其余文件（字幕文件等）
      try {
        const entries = fs.listFileSync(dir);
        for (let i = 0; i < entries.length; i++) {
          try {
            fs.unlinkSync(`${dir}/${entries[i]}`);
          } catch {
            // 单个文件删除失败不中断
          }
        }
      } catch {
        // listFileSync 失败时忽略
      }
      // 删除目录本身
      try {
        fs.rmdirSync(dir);
      } catch {
        // 目录非空时忽略
      }
    } catch (e) {
      console.error(`[SubtitleCacheManager] clearSubtitleCache 失败: ${String(e)}`);
    }
  }

  /**
   * 计算字幕缓存占用的总磁盘空间（字节数）。
   *
   * 目录结构为三层：subtitles/{sourceType}_{sourceId}/{sha256Hash}/files
   * subtitles/ 不存在时返回 0。
   */
  async getTotalCacheSizeBytes(filesDir: string): Promise<number> {
    const subtitlesRoot = `${filesDir}/subtitles`;
    try {
      await fs.stat(subtitlesRoot);
    } catch {
      return 0;
    }
    let totalBytes = 0;
    let level1Names: string[] = [];
    try {
      level1Names = await fs.listFile(subtitlesRoot);
    } catch {
      return 0;
    }
    for (let i = 0; i < level1Names.length; i++) {
      const level1Dir = `${subtitlesRoot}/${level1Names[i]}`;
      let level2Names: string[] = [];
      try {
        level2Names = await fs.listFile(level1Dir);
      } catch {
        continue;
      }
      for (let j = 0; j < level2Names.length; j++) {
        const level2Dir = `${level1Dir}/${level2Names[j]}`;
        let fileNames: string[] = [];
        try {
          fileNames = await fs.listFile(level2Dir);
        } catch {
          // level2 entry 可能是文件，直接 stat
          try {
            const stat = await fs.stat(level2Dir);
            totalBytes += stat.size;
          } catch {
            // ignore
          }
          continue;
        }
        for (let k = 0; k < fileNames.length; k++) {
          try {
            const stat = await fs.stat(`${level2Dir}/${fileNames[k]}`);
            totalBytes += stat.size;
          } catch {
            // ignore
          }
        }
      }
    }
    return totalBytes;
  }

  /**
   * 清理所有字幕缓存（删除 {filesDir}/subtitles/ 下的全部内容）。
   *
   * - subtitles/ 根目录不存在时静默返回，不抛异常
   * - 单个文件失败时记录日志并继续，全部处理完后若有失败则抛出 Error
   */
  async clearAllSubtitleCaches(filesDir: string): Promise<void> {
    const subtitlesRoot = `${filesDir}/subtitles`;
    // 根目录不存在时静默返回
    try {
      await fs.stat(subtitlesRoot);
    } catch {
      return;
    }

    // 遍历一级子目录
    let subDirNames: string[] = [];
    try {
      subDirNames = await fs.listFile(subtitlesRoot);
    } catch (e) {
      throw new Error(`[SubtitleCacheManager] 无法列出缓存目录: ${String(e)}`);
    }

    let hasError = false;
    for (let i = 0; i < subDirNames.length; i++) {
      const subDir = `${subtitlesRoot}/${subDirNames[i]}`;
      try {
        let files: string[] = [];
        try {
          files = await fs.listFile(subDir);
        } catch {
          // listFile 失败时忽略（可能是文件而非目录）
        }
        for (let j = 0; j < files.length; j++) {
          try {
            await fs.unlink(`${subDir}/${files[j]}`);
          } catch {
            // 单文件删除失败时忽略，继续下一个
          }
        }
        await fs.rmdir(subDir);
      } catch (e) {
        hasError = true;
        console.error(`[SubtitleCacheManager] clearAllSubtitleCaches 处理子目录失败: ${subDir} ${String(e)}`);
      }
    }

    // 尝试删除根目录（非空时失败可忽略）
    try {
      await fs.rmdir(subtitlesRoot);
    } catch {
      // 根目录非空时忽略
    }

    if (hasError) {
      throw new Error('[SubtitleCacheManager] 部分字幕缓存清理失败，请重试');
    }
  }
}

/**
 * 将字节数格式化为人类可读的缓存大小字符串。
 */
export function formatCacheSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  } else if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  } else {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
}
