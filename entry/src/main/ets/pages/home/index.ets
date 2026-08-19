import { LengthMetrics } from "@kit.ArkUI"
import { SidebarStore } from "../../stores/sidebar/SidebarStore"
import { TabBarStore } from "../../stores/tabbar/TabBarStore"
import { HomeTopBar } from "./topbar"
import { SourceSwitchDialog } from "./topbar/SourceSwitchDialog"
import { TabContentBuilder } from "./tabs"
import { TabItem, TabItemCode, TabBarModel } from "../../stores/tabbar/TabBarModel"
import { FileSourceStore } from "../../stores/files/FileSourceStore"
import { FileSourceModel } from "../../stores/files/FileSourceModel"
import { SidebarModel } from "../../stores/sidebar/SidebarModel"
import { VideoServerStore } from "../../stores/servers/VideoServerStore"
import { VideoServerModel } from "../../stores/servers/VideoServerModel"
import { SourceSwitchModel } from "../../stores/media/SourceSwitchModel"
import { UmamiAnalyticsService } from "../../services/analytics/UmamiAnalyticsService"

@ComponentV2
@Preview({
  deviceType: 'tv',
  width: 2800,
  height: 1575,
})
export struct HomePage {
  tabBarModel: TabBarModel = TabBarStore.getState()
  sidebarModel: SidebarModel = SidebarStore.getState()
  fileSourceModel: FileSourceModel = FileSourceStore.getState()
  videoServerModel: VideoServerModel = VideoServerStore.getState()
  @Local sourceSwitchModel: SourceSwitchModel = SourceSwitchModel.getState()
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

  private async loadSourceState(): Promise<void> {
    try {
      await this.videoServerModel.loadVideoServers(true)
    } catch (error) {
      console.warn('[HomePage] 加载影视服务器列表失败', (error as Error).message ?? String(error))
    }
    // 服务器列表加载失败时仍尝试恢复持久化的数据源状态，避免用户上次选择被静默丢弃。
    try {
      await this.sourceSwitchModel.load(this.videoServerModel.videoServers.map(s => s.id ?? -1))
    } catch (error) {
      console.warn('[HomePage] 恢复数据源状态失败', (error as Error).message ?? String(error))
    }
  }

  aboutToAppear(): void {
    this.loadSourceState()
    if (UmamiAnalyticsService.isInitialized()) {
      // 按实际当前 tab 上报，而非固定 /home（Swiper.onChange 首次不触发）
      const path = this.tabIndexToPath(this.tabBarModel.currentTabIndex);
      UmamiAnalyticsService.getInstance().trackPageView(path);
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          HomeTopBar({
            onHomeClick: () => {
              this.sourceSwitchModel.sourceSwitchDialogVisible = true
            }
          })

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
          .loop(false)
          .cachedCount(this.tabBarModel.tabs.length)
        }
        .constraintSize({ minHeight: '100%' })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)

      if (this.sourceSwitchModel.sourceSwitchDialogVisible) {
        SourceSwitchDialog({
          onClose: () => {
            this.sourceSwitchModel.sourceSwitchDialogVisible = false
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
