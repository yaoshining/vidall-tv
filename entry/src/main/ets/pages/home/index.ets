import { IBestButton, IBestDivider, IBestIcon, IBestPopover, IBestToast } from "@ibestservices/ibest-ui"
import { LengthMetrics, router } from "@kit.ArkUI"
import { LucideCloudDownload } from 'lucide'
import { BasicClock } from "../../components/common/BasicClock"
import { SidebarStore } from "../../stores/sidebar/SidebarStore"
import { TabBarStore } from "../../stores/tabbar/TabBarStore"
import { common } from "@kit.AbilityKit"
import { picker } from "@kit.CoreFileKit"
import { PlayerPageParam } from "../player"

interface TabItem {
  id: number,
  name: string
}

@ComponentV2
@Preview({
  deviceType: 'tv',
  width: 2800, // 可选的TV典型宽度
  height: 1575,
})
export struct HomePage {
  tabBarModel = TabBarStore.getState()
  sidebarModel = SidebarStore.getState()
  @Local handlePopup: boolean = true;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  swiperController = new SwiperController()

  @Builder
  settingIBestIconBuilder(name: string) {
    IBestIcon({
      name,
      iconSize: 20
    }).margin({ end: LengthMetrics.vp(4) })
  }

  @Builder
  settingLucideIconBuilder(name: string) {
    if (name === 'cloud-download') {
      LucideCloudDownload({
        iconSize: 20,
        strokeColor: Color.White
      }).margin({ end: LengthMetrics.vp(4) })
    }
  }

  @Builder
  settingHuaweiIconBuilder(value: Resource) {
    SymbolGlyph(value)
      .fontSize(20)
      .fontColor([Color.White])
  }

  build() {
    Flex({
      direction: FlexDirection.Column
    }) {
      Column() {
        Flex({
          justifyContent: FlexAlign.SpaceBetween,
        }) {
          Flex({
            justifyContent: FlexAlign.Start,
            alignItems: ItemAlign.Center,
            space: {
              main: LengthMetrics.vp(10)
            }
          }) {
            IBestButton({
              text: "设置",
              buttonSize: "small",
              btnBorderColor: Color.Transparent,
              iconBuilder: (): void => this.settingIBestIconBuilder('setting-o'),
              onBtnClick: () => {
                this.sidebarModel.sidebarOpened = true
              }
            })
            IBestDivider({ vertical: true })
            IBestButton({
              text: "Home",
              buttonSize: "small",
              btnBorderColor: Color.Transparent,
              iconBuilder: (): void => this.settingIBestIconBuilder('sort')
            })

            IBestButton({
              buttonSize: "small",
              btnBorderColor: Color.Transparent,
              iconBuilder: (): void => this.settingIBestIconBuilder('search')
            }).bindTips('搜索')

            IBestButton({
              buttonSize: "small",
              btnBorderColor: Color.Transparent,
              iconBuilder: (): void => this.settingLucideIconBuilder('cloud-download')
            }).bindTips('获取云端数据')

            IBestButton({
              buttonSize: "small",
              btnBorderColor: Color.Transparent,
              iconBuilder: (): void => this.settingHuaweiIconBuilder($r('sys.symbol.folder_badge_plus'))
            }).bindTips('添加/修改文件源')
          }

          Flex({
            justifyContent: FlexAlign.End,
            alignItems: ItemAlign.Center,
          }) {
            BasicClock()
              .margin({ right: 12 })
            Image($r('app.media.logo'))
              .width(36)
            Text("idAll")
              .fontSize(26)
          }
        }
        .padding({ left: 20, right: 20, top: 20, bottom: 10 })

        Flex({
          space: {
            main: LengthMetrics.vp(10)
          }
        }) {
          ForEach(this.tabBarModel.tabs, (tab: TabItem, index) => {
            Button(tab.name, {
              controlSize: ControlSize.SMALL
            })
              .buttonStyle(
                this.tabBarModel.currentTabIndex === index ?
                  ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL
              )
              .type(ButtonType.Normal)
              .borderRadius(8)
              .onClick(() => {
                this.swiperController.changeIndex(index, true)
              })
          })
        }
        .id("tabButtons")
        .padding({ left: 20, right: 20, top: 10, bottom: 20 })
      }

      Swiper(this.swiperController) {
        ForEach(this.tabBarModel.tabs, (tab: TabItem) => {
          Column() {
            Row() {
              Button(`${JSON.stringify(this.tabBarModel.currentTab)}`, {
                controlSize: ControlSize.SMALL
              })
                .onClick(() => {
                  let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                  let documentPicker = new picker.DocumentViewPicker(context);
                  documentPicker.select({
                    selectMode: picker.DocumentSelectMode.FILE,
                    authMode: true
                  }).then(async res => {
                    if (res.length > 0) {
                      let url = res[0]
                      console.log(`Select URL: ${url}`)
                      let pageParam: PlayerPageParam = {
                        fileUrl: url
                      }
                      try {
                        this.pageStack.pushPath({
                          name: 'player',
                          param: JSON.stringify(pageParam)
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
                  this.pageStack.pushPath({
                    name: 'player',
                    param: JSON.stringify({
                      url: 'https://vjs.zencdn.net/v/oceans.mp4'
                    })
                  }, true)
                  // this.getUIContext().getRouter().pushUrl({
                  //   url: 'pages/Test'
                  // }, router.RouterMode.Single, (err) => {
                  //   if (err) {
                  //     console.error(`Invoke pushUrl failed, code is ${err.code}, message is ${err.message}`)
                  //     return
                  //   }
                  // })
                })
            }
            ForEach(Array.from(Array(50)), (_i: number, index: number) => {
              Row() {
                Text(tab.name + index)
              }
            })
          }
          .width("100%")
        })
      }
      .onChange((index) => {
        this.tabBarModel.currentTabIndex = index
      })
      .indicator(false)
      .flexGrow(1)
    }
  }
}
