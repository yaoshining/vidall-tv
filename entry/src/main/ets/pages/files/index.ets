import { IBestToast } from "@ibestservices/ibest-ui";
import { FileExplorer } from "../../components/core/file/FileExplorer";
import { FileExplorerController } from "../../components/core/file/FileExplorerController";
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../lib/WebDAVClient";
import { PlayerPage, PlayerPageParam } from "../player";
import { common } from "@kit.AbilityKit";
import { util } from "@kit.ArkTS";
import { filePreview } from "@kit.PreviewKit";
import { fileIo } from "@kit.CoreFileKit";

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
      if (this.imagePath) {
        Image(this.imagePath)
          .width(200)
          .height(200)
          .alt($r('app.media.foreground'))
          .objectFit(ImageFit.Cover)
          .onError(error => {
            console.error(error.message)
          })
      }
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
    .onReady((context) => {
      const param = context.pathInfo.param as WebDAVConfig
      this.client = new WebDAVClient(param)
      this.changePath(this.fileExplorerController.currentPath)
    })
    .onBackPressed(() => {
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
      },
      onError: (error) => {
        console.error('下载失败:', error);
      }
    })
  }

  private playVideo(path: string, displayName: string) {
    const url = this.client.getFullUrl(path)
    const authHeader = this.client.getAuthHeaderPublic()

    const pageParam: PlayerPageParam = {
      url: encodeURI(url),
      httpHeader: {
        'Authorization': authHeader
      },
      title: displayName
    }

    this.pageStack.pushPath({
      name: PlayerPage.PAGE_NAME,
      param: pageParam
    })
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