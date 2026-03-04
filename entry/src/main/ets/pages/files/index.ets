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
import { FfprobeUtil } from "../../utils/FfprobeUtil";
import { PresetAudioTrack } from "../../components/core/player/VideoData";

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
      }
      .width('100%')
      .height('100%')
    }
    .onReady((context) => {
      const param = context.pathInfo.param as WebDAVConfig
      this.client = new WebDAVClient(param)
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

  private async playVideo(path: string, displayName: string) {
    const url = this.client.getFullUrl(path);
    const authHeader = this.client.getAuthHeaderPublic();
    const httpHeader: Record<string, string> = { 'Authorization': authHeader };

    // 用 ffprobe 探测完整音轨/字幕轨信息（支持 EAC-3、DTS、TrueHD 等所有格式）
    let presetAudioTracks: PresetAudioTrack[] = [];
    try {
      const probeResult = await FfprobeUtil.probe(encodeURI(url), httpHeader, 15000);
      if (probeResult.success && probeResult.audioTracks.length > 0) {
        for (let i = 0; i < probeResult.audioTracks.length; i++) {
          const t = probeResult.audioTracks[i];
          const item: PresetAudioTrack = {
            trackIndex: t.index,
            displayName: FfprobeUtil.buildAudioTrackDisplayName(t, i),
            language: t.language,
            mimeType: t.codecName
          };
          presetAudioTracks.push(item);
        }
        console.info(`[playVideo] ffprobe 探测到 ${presetAudioTracks.length} 个音轨`);
      } else {
        console.info(`[playVideo] ffprobe 探测失败或无音轨: ${probeResult.errorMessage ?? ''}`);
      }
    } catch (e) {
      console.warn(`[playVideo] ffprobe 异常，忽略: ${JSON.stringify(e)}`);
    }

    const pageParam: PlayerPageParam = {
      url: encodeURI(url),
      httpHeader: httpHeader,
      title: displayName,
      presetAudioTracks: presetAudioTracks.length > 0 ? presetAudioTracks : undefined
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