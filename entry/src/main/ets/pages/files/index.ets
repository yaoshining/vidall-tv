import { IBestToast } from "@ibestservices/ibest-ui";
import { FileExplorer } from "../../components/core/file/FileExplorer";
import { FileExplorerController } from "../../components/core/file/FileExplorerController";
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../lib/WebDAVClient";
import { PlayerPage, PlayerPageParam } from "../player";

const config: WebDAVConfig = {
  baseUrl: 'http://192.168.3.59:5445/dav',
  username: 'yao',
  password: 'ys198756'
}

// const config: WebDAVConfig = {
//   baseUrl: 'http://dav.mypikpak.com',
//   username: 'cdkd',
//   password: 'dartvjhx'
// }

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
          console.log('Select file is: ' + JSON.stringify(event))
          const url = this.client.getFullUrl(event.fullPath)
          const authHeader = this.client.getAuthHeaderPublic()
          console.log(`Auth Header: ${encodeURI(url)}`)
          console.log(`Auth Header: ${authHeader}`)

          const pageParam: PlayerPageParam = {
            url: encodeURI(url),
            httpHeader: {
              'Authorization': authHeader
            }
          }

          this.pageStack.pushPath({
            name: PlayerPage.PAGE_NAME,
            param: pageParam
          })
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

  private changePath(newPath: string = '/') {
    this.client.listDirectory(encodeURIComponent(newPath)).then(files => {
      files.shift()
      this.fileExplorerController.currentPath = newPath
      this.fileExplorerController.resources = files
    })
  }
}