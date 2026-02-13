import { IBestToast } from "@ibestservices/ibest-ui";
import { FileExplorer } from "../../components/core/file/FileExplorer";
import { FileExplorerController } from "../../components/core/file/FileExplorerController";
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../lib/WebDAVClient";
import { PlayerPage, PlayerPageParam } from "../player";

const config: WebDAVConfig = {
  baseUrl: 'http://www.baidu.com',
  username: 'asdasd',
  password: 'qweqwe'
}

@ComponentV2
export struct FileExplorerPage {
  static PAGE_NAME = "fileExplorerPage"
  client: WebDAVClient = new WebDAVClient(config)
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
      FileExplorer({
        controller: this.fileExplorerController,
        onFileClick: event => {
          if (this.isVideoFile(event.resource.displayName)) {
            this.playVideo(event.fullPath, event.resource.displayName)
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
}