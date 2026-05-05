import { LengthMetrics } from "@kit.ArkUI"
import { SidebarStore } from "../../stores/sidebar/SidebarStore"
import { TabBarStore } from "../../stores/tabbar/TabBarStore"
import { HomeTopBar } from "./topbar"
import { TabContentBuilder } from "./tabs"
import { TabItem, TabItemCode } from "../../stores/tabbar/TabBarModel"
import { FileSourceStore } from "../../stores/files/FileSourceStore"
import { UmamiAnalyticsService } from "../../services/analytics/UmamiAnalyticsService"

@ComponentV2
@Preview({
  deviceType: 'tv',
  width: 2800,
  height: 1575,
})
export struct HomePage {
  tabBarModel = TabBarStore.getState()
  sidebarModel = SidebarStore.getState()
  fileSourceModel = FileSourceStore.getState()
  @Local handlePopup: boolean = true;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  swiperController = new SwiperController()

  private tabIndexToPath(index: number): string {
    const tab = this.tabBarModel.tabs[index];
    if (tab === undefined) {
      return '/home';
    }
    if (tab.code === TabItemCode.MEDIA_LIBRARY) {
      return '/media-library';
    }
    if (tab.code === TabItemCode.FILE_SOURCE) {
      return '/file-browser';
    }
    return '/home';
  }

  aboutToAppear(): void {
    if (UmamiAnalyticsService.isInitialized()) {
      // 按实际当前 tab 上报，而非固定 /home（Swiper.onChange 首次不触发）
      const path = this.tabIndexToPath(this.tabBarModel.currentTabIndex);
      UmamiAnalyticsService.getInstance().trackPageView(path);
    }
  }

  build() {
    Scroll() {
      Column() {
        HomeTopBar()

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
                if (this.tabBarModel.currentTabIndex === index) {
                  // 已激活状态再次点击 → 对应 store 的 refreshTick 自增
                  if (tab.code === TabItemCode.FILE_SOURCE) {
                    this.fileSourceModel.refreshTick++
                  }
                } else {
                  this.swiperController.changeIndex(index, true)
                }
              })
          })
        }
        .id("tabButtons")
        .padding({
          left: 20,
          right: 20,
          top: 10,
          bottom: 20
        })

        Swiper(this.swiperController) {
          ForEach(this.tabBarModel.tabs, (tab: TabItem) => {
            Column() {
              TabContentBuilder(tab)
            }
            .width("100%")
            .padding({ left: 20, right: 20 })
          })
        }
        .onChange((index) => {
          this.tabBarModel.currentTabIndex = index
          if (UmamiAnalyticsService.isInitialized()) {
            UmamiAnalyticsService.getInstance().trackPageView(this.tabIndexToPath(index));
          }
        })
        .index(this.tabBarModel.currentTabIndex)
        .indicator(false)
        .cachedCount(this.tabBarModel.tabs.length)
      }
      .constraintSize({ minHeight: '100%' })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}
