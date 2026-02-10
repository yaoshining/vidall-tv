interface TabItem {
  id: number,
  name: string
}

@ObservedV2
export class TabBarModel {

  @Trace tabs: TabItem[] = [{
    id: 1,
    name: "媒体库"
  }, {
    id: 2,
    name: "文件源"
  }, {
    id: 3,
    name: "影视服务器"
  }]

  @Trace currentTabIndex: number = 1

  @Computed
  get currentTab() {
    return this.tabs[this.currentTabIndex]
  }
}