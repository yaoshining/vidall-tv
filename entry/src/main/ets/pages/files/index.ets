import { IBestToast } from "@ibestservices/ibest-ui";
import { FileExplorer } from "../../components/core/file/FileExplorer";
import { FileExplorerController } from "../../components/core/file/FileExplorerController";
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../lib/WebDAVClient";
import { PlayerPage, PlayerPageParam } from "../player";
import { common } from "@kit.AbilityKit";
import { util } from "@kit.ArkTS";
import { filePreview } from "@kit.PreviewKit";
import { fileIo } from "@kit.CoreFileKit";
import { ImagePreviewDialog } from "../../components/core/file/ImagePreview";
import { FfprobeUtil, FfprobeTrack } from "../../utils/FfprobeUtil";
import { PresetAudioTrack, PresetSubtitleTrack } from "../../components/core/player/VideoData";
import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { DirStatus } from "../../db/models/FileSourceEntity";

/**
 * 文件浏览页路由参数
 * 兼容旧版仅传 WebDAVConfig 的调用方，新增 dir 元信息用于删除目录检测
 */
export interface FileExplorerPageParam {
  config: WebDAVConfig;
  /** file_source_directories 主键，清理时必填 */
  dirId?: number;
  /** 所属文件源 id，清理时必填 */
  sourceId?: number;
  /** 目录路径，用于 DB 清理 */
  directoryPath?: string;
  /** 目录可达性状态，'missing' 时触发清理 Dialog */
  dirStatus?: DirStatus;
}

const config: WebDAVConfig = {
  baseUrl: 'http://www.baidu.com',
  username: 'asdasd',
  password: 'qweqwe'
}

@ComponentV2
export struct FileExplorerPage {
  static PAGE_NAME = "fileExplorerPage"
  client: WebDAVClient = new WebDAVClient(config)
  @Local imagePath: string = ''
  @Local showMissingDirDialog: boolean = false
  @Local isCleaningUp: boolean = false
  private cachedDirId: number = 0
  private cachedSourceId: number = 0
  private cachedDirectoryPath: string = ''
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private fileExplorerController = new FileExplorerController({
    resources: [],
    currentPath: '/',
    onFolderChange: (path) => {
      this.changePath(path)
    },
    onBack: () => {
      this.pageStack.pop(true)
      return true
    }
  })

  build() {
    NavDestination() {
      Stack() {
        FileExplorer({
          controller: this.fileExplorerController,
          onFileClick: event => {
            const displayName = event.resource.displayName
            if (this.isVideoFile(displayName)) {
              this.playVideo(event.fullPath, event.resource.displayName)
            }
            if (this.isImageFile(displayName)) {
              this.previewImage(event.fullPath, displayName)
            }
          }
        })

        // ── 已删除目录提示 Dialog ──────────────────────────────
        if (this.showMissingDirDialog) {
          Column() {
            Column() {
              Text('目录不存在')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Text('此目录在服务器上已不存在，是否立即清理相关数据？')
                .fontSize(18)
                .fontColor('#CCCCCC')
                .margin({ top: 16 })
                .textAlign(TextAlign.Center)
              Row({ space: 24 }) {
                Button('取消')
                  .fontSize(18)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#555555')
                  .borderRadius(8)
                  .width(120)
                  .height(48)
                  .enabled(!this.isCleaningUp)
                  .onClick(() => {
                    this.showMissingDirDialog = false
                  })
                Button(this.isCleaningUp ? '清理中...' : '清理')
                  .fontSize(18)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#E53935')
                  .borderRadius(8)
                  .width(120)
                  .height(48)
                  .enabled(!this.isCleaningUp)
                  .onClick(() => {
                    this.confirmCleanup()
                  })
              }
              .margin({ top: 24 })
            }
            .padding(32)
            .borderRadius(12)
            .backgroundColor('#2C2C2C')
            .width(460)
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#80000000')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            // 拦截蒙层点击穿透
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .onReady((context) => {
      const param = context.pathInfo.param as FileExplorerPageParam
      this.client = new WebDAVClient(param.config)
      this.cachedDirId = param.dirId ?? 0
      this.cachedSourceId = param.sourceId ?? 0
      this.cachedDirectoryPath = param.directoryPath ?? ''
      if (param.dirStatus === 'missing') {
        this.showMissingDirDialog = true
        return
      }
      this.changePath(this.fileExplorerController.currentPath)
    })
    .onBackPressed(() => {
      // 如果正在预览图片，先关闭图片预览
      if (this.imagePath) {
        this.imagePath = ''
        return true
      }
      this.fileExplorerController.handleBack()
      return true
    })
    .mode(NavDestinationMode.DIALOG)
    .hideTitleBar(true)
  }

  /**
   * 确认清理已删除目录：调用 DB 清理方法后返回上一页
   */
  private confirmCleanup(): void {
    this.isCleaningUp = true
    const dirId = this.cachedDirId
    const sourceId = this.cachedSourceId
    const directoryPath = this.cachedDirectoryPath
    const db = FileSourceDatabase.getInstance()
    db.clearMediaAndDirectoryForDir(dirId, sourceId, directoryPath)
      .then((): void => {
        this.pageStack.pop(true)
      })
      .catch((): void => {
        console.error('[FileExplorerPage][confirmCleanup] 清理失败')
        IBestToast.show('清理失败，请重试')
        this.isCleaningUp = false
        this.showMissingDirDialog = false
      })
  }

  private previewImage(path: string, displayName: string) {
    const authHeader = this.client.getAuthHeaderPublic()
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const tempPath = context.tempDir + "/" + displayName

    this.client.downloadFileStream(path, tempPath, {
      onProgress: (downloaded, total) => {
        const percentage = (downloaded / total * 100).toFixed(2);
        console.info(`下载进度: ${percentage}%`);
      },
      onComplete: (filePath) => {
        console.info('下载完成:', filePath);
        // 更新图片路径以显示图片
        this.imagePath = 'file://' + filePath;

        const dialogController: CustomDialogController = new CustomDialogController({
          builder: ImagePreviewDialog({
            imageSrc: this.imagePath,
          }),
          width: '100%',
          height: '100%',
          maskColor: Color.Transparent,
          cornerRadius: 0,
          customStyle: true,
        })

        dialogController.open()
      },
      onError: (error) => {
        console.error('下载失败:', error);
        IBestToast.show('图片加载失败: ' + error);
      }
    })
  }

  /** 安全截断 JSON 字符串用于日志展示，空/null/undefined 时返回对应标记 */
  private jsonPreview(json: string | null | undefined, maxLen: number = 60): string {
    if (json === null) { return 'NULL'; }
    if (json === undefined) { return 'undefined'; }
    if (json.length === 0) { return '(空)'; }
    return json.length > maxLen ? `"${json.substring(0, maxLen)}..."` : `"${json}"`;
  }

  private async playVideo(path: string, displayName: string) {
    const url = this.client.getFullUrl(path);
    const authHeader = this.client.getAuthHeaderPublic();
    const httpHeader: Record<string, string> = { 'Authorization': authHeader };

    console.info(`[playVideo] 开始 — path="${path}" displayName="${displayName}" url="${url}"`);

    let presetAudioTracks: PresetAudioTrack[] = [];
    let presetSubtitleTracks: PresetSubtitleTrack[] = [];
    let durationHintMs: number = 0;
    // DB 是否有确定性数据（NULL 表示未扫描，'[]' 表示已扫描但无轨道）
    let dbHasAudioData = false;
    let dbHasSubtitleData = false;

    // ── 优先：从数据库读取已落库的音轨/字幕信息（扫描时已写入）──
    // path 是相对路径（如 /nas/电影/xxx.mkv），数据库里的 filePath 与其对应
    try {
      console.info(`[playVideo] 查询 DB getVideoByPath: path="${path}"`);
      const videoEntity = await FileSourceDatabase.getInstance().getVideoByPath(path);
      if (videoEntity) {
        const audioJsonPreview = this.jsonPreview(videoEntity.audioTracksJson);
        const subJsonPreview = this.jsonPreview(videoEntity.subtitleTracksJson);
        console.info(
          `[playVideo] DB 命中: videoId=${videoEntity.id ?? '?'}` +
          ` audioTracksJson=${audioJsonPreview}` +
          ` subtitleTracksJson=${subJsonPreview}`
        );
        if (videoEntity.durationMs !== undefined && videoEntity.durationMs !== null && videoEntity.durationMs > 0) {
          durationHintMs = videoEntity.durationMs;
        }
        // 音轨（audioTracksJson 不为 null 表示已经探测过，哪怕结果为空数组）
        if (videoEntity.audioTracksJson !== null && videoEntity.audioTracksJson !== undefined) {
          dbHasAudioData = true;
          if (videoEntity.audioTracksJson.length > 0) {
            const tracks = JSON.parse(videoEntity.audioTracksJson) as FfprobeTrack[];
            console.info(`[playVideo] DB 音轨 JSON 解析: 共 ${tracks.length} 条`);
            presetAudioTracks = FfprobeUtil.toPresetAudioTracks(tracks);
          } else {
            console.info(`[playVideo] DB 音轨 JSON 为空字符串，视为已扫描无音轨`);
          }
        } else {
          console.info(`[playVideo] DB 音轨字段为 NULL/undefined，需 ffprobe 探测`);
        }
        // 字幕轨（subtitleTracksJson 不为 null 表示已经探测过）
        if (videoEntity.subtitleTracksJson !== null && videoEntity.subtitleTracksJson !== undefined) {
          dbHasSubtitleData = true;
          if (videoEntity.subtitleTracksJson.length > 0) {
            const subTracks = JSON.parse(videoEntity.subtitleTracksJson) as FfprobeTrack[];
            console.info(`[playVideo] DB 字幕轨 JSON 解析: 共 ${subTracks.length} 条`);
            presetSubtitleTracks = FfprobeUtil.toPresetSubtitleTracks(subTracks);
          } else {
            console.info(`[playVideo] DB 字幕轨 JSON 为空字符串，视为已扫描无内嵌字幕`);
          }
        } else {
          console.info(`[playVideo] DB 字幕轨字段为 NULL/undefined，需 ffprobe 探测`);
        }
      } else {
        console.info(`[playVideo] DB 未命中（文件未扫描），path="${path}"`);
      }
    } catch (e) {
      console.warn(`[playVideo] 数据库读取轨道失败，将 fallback 到 ffprobe: ${JSON.stringify(e)}`);
    }

    console.info(
      `[playVideo] DB 阶段结束: dbHasAudioData=${dbHasAudioData} dbHasSubtitleData=${dbHasSubtitleData}` +
      ` presetAudioTracks=${presetAudioTracks.length} presetSubtitleTracks=${presetSubtitleTracks.length}`
    );

    // 文件浏览器直开策略：默认实时 ffprobe（DB 仅兜底）
    // 说明：文件浏览器路径可能是“未入库/旧入库”状态，优先以实时探测结果构建播放参数。
    const useRealtimeProbeByDefault = true;
    if (useRealtimeProbeByDefault || !dbHasAudioData || !dbHasSubtitleData || durationHintMs <= 0) {
      console.info(
        `[playVideo] 触发 ffprobe fallback:` +
        ` dbHasAudioData=${dbHasAudioData} dbHasSubtitleData=${dbHasSubtitleData}` +
        ` durationHintMs=${durationHintMs}` +
        ` url="${url.substring(0, 80)}"`
      );
      try {
        // getFullUrl() 已完成路径编码，这里禁止再次 encodeURI，避免 % -> %25 的二次编码。
        const probeResult = await FfprobeUtil.probe(url, httpHeader, 15000);
        if (probeResult.success) {
          console.info(
            `[playVideo] ffprobe 成功: 音轨=${probeResult.audioTracks.length}` +
            ` 字幕轨=${probeResult.subtitleTracks.length}` +
            ` 格式=${probeResult.formatName ?? '?'} 时长=${probeResult.durationText}`
          );
          const probeHasUsefulData =
            probeResult.durationMs > 0 ||
            probeResult.audioTracks.length > 0 ||
            probeResult.subtitleTracks.length > 0;
          if (probeHasUsefulData) {
            if (probeResult.durationMs > 0) {
              durationHintMs = probeResult.durationMs;
            }
            // 实时策略下，probe 成功后以 probe 结果覆盖轨道列表。
            presetAudioTracks = FfprobeUtil.toPresetAudioTracks(probeResult.audioTracks);
            presetSubtitleTracks = FfprobeUtil.toPresetSubtitleTracks(probeResult.subtitleTracks);
          } else {
            console.warn('[playVideo] ffprobe 成功但未返回有效轨道/时长，保留 DB 结果作为兜底');
          }
          console.info(
            `[playVideo] ffprobe 补全完毕: 音轨=${presetAudioTracks.length} 字幕轨=${presetSubtitleTracks.length}`
          );
        } else {
          console.warn(`[playVideo] ffprobe 探测失败: ${probeResult.errorMessage ?? '(无错误信息)'}`);
        }
      } catch (e) {
        console.warn(`[playVideo] ffprobe 异常，忽略: ${JSON.stringify(e)}`);
      }
    } else {
      console.info(`[playVideo] DB 数据完整（音轨+字幕轨均已记录），跳过 ffprobe 探测`);
    }

    console.info(
      `[playVideo] 最终轨道: 音轨=${presetAudioTracks.length} 字幕轨=${presetSubtitleTracks.length}` +
      ` → 推入播放页`
    );

    const pageParam: PlayerPageParam = {
      // getFullUrl() 已编码，禁止二次 encodeURI。
      url: url,
      httpHeader: httpHeader,
      title: displayName,
      durationHintMs: durationHintMs > 0 ? durationHintMs : undefined,
      presetAudioTracks: presetAudioTracks.length > 0 ? presetAudioTracks : undefined,
      presetSubtitleTracks: presetSubtitleTracks.length > 0 ? presetSubtitleTracks : undefined
    };

    this.pageStack.pushPath({
      name: PlayerPage.PAGE_NAME,
      param: pageParam
    });
  }

  /** 语言代码转显示名称 */
  private getLanguageName(lang: string): string {
    return FfprobeUtil.getLanguageDisplayName(lang);
  }

  private changePath(newPath: string = '/') {
    this.client.listDirectory(encodeURIComponent(newPath)).then(files => {
      files.shift()
      this.fileExplorerController.currentPath = newPath
      this.fileExplorerController.resources = files
    })
  }

  private isVideoFile(fileName: string): boolean {
    const videoExtensions = ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v'];
    const lowerFileName = fileName.toLowerCase();
    return videoExtensions.some(ext => lowerFileName.endsWith(ext));
  }

  private isImageFile(fileName: string): boolean {
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.tiff'];
    const lowerFileName = fileName.toLowerCase();
    return imageExtensions.some(ext => lowerFileName.endsWith(ext));
  }
}