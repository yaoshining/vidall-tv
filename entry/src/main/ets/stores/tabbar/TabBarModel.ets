export interface TabItem {
  id: number,
  name: string,
  code: string
}

export enum TabItemCode {
  MEDIA_LIBRARY = "media_library",
  FILE_SOURCE = "file_source",
  VIDEO_SERVER = "video_server"
}

@ObservedV2
export class TabBarModel {

  @Trace tabs: TabItem[] = [{
    id: 1,
    name: "媒体库",
    code: TabItemCode.MEDIA_LIBRARY
  }, {
    id: 2,
    name: "文件源",
    code: TabItemCode.FILE_SOURCE
  }, {
    id: 3,
    name: "影视服务器",
    code: TabItemCode.VIDEO_SERVER
  }]

  @Trace currentTabIndex: number = 1

  @Computed
  get currentTab() {
    return this.tabs[this.currentTabIndex]
  }
}