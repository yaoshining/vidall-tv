import { TabBarModel, TabItem } from "../../../stores/tabbar/TabBarModel"
import { TabBarStore } from "../../../stores/tabbar/TabBarStore"
import { common } from "@kit.AbilityKit"
import { picker } from "@kit.CoreFileKit"
import { PlayerPage, PlayerPageParam } from "../../player"
import { VideoScannerUtil } from "../../../utils/VideoScannerUtil"

@ComponentV2
export struct MediaLibraryTab {
  tabBarModel: TabBarModel = TabBarStore.getState()
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Require @Param tab: TabItem

  build() {
    Column() {
      Row() {
        Button(`${JSON.stringify(this.tabBarModel.currentTab)}`, {
          controlSize: ControlSize.SMALL
        })
          .onClick(() => {
            if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
              console.error('this api is not supported on this device');
              return;
            }

            let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
            let documentPicker = new picker.DocumentViewPicker(context);
            documentPicker.select({
              selectMode: picker.DocumentSelectMode.FILE,
              authMode: false,
            }).then(async res => {
              if (res.length > 0) {
                let url = res[0]
                console.log(`Select URL: ${url}`)

                let pageParam: PlayerPageParam = {
                  fileUrl: url
                }
                try {
                  this.pageStack.pushPath({
                    name: PlayerPage.PAGE_NAME,
                    param: pageParam
                  }, true)
                } catch (error) {
                  console.error(`Player error: ${error}`)
                }
              }
            })
          })

        Button("播放视频", {
          controlSize: ControlSize.SMALL
        })
          .onClick(() => {
            // const fileUrl = 'file://media/Photo/14/VID_1769519059_006/SVID_20260127_210239_1.mp4'
            const url = 'https://vjs.zencdn.net/v/oceans.mp4'
            this.pageStack.pushPath({
              name: PlayerPage.PAGE_NAME,
              param: { url } as PlayerPageParam
            }, true)
          })
      }
      Column() {
        Button("扫描视频").onClick((event: ClickEvent) => {
          VideoScannerUtil.scan(this.getUIContext().getHostContext()!)
        })
      }
      ForEach(Array.from(Array(50)), (_i: number, index: number) => {
        Row() {
          Text(this.tab.name + index)
        }
      })
    }
  }
}