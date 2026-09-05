import { LengthMetrics } from "@kit.ArkUI"
import { BusinessError } from "@kit.BasicServicesKit"
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
import { ScrapeFailureLogStore } from "../../services/scrape/ScrapeFailureLogStore"
import { AutoScrapeTrigger } from "../../services/scrape/AutoScrapeTrigger"

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
      // 仅在服务器列表成功加载后再恢复数据源，避免临时数据库错误时用不完整列表误判服务器已删除
      await this.sourceSwitchModel.load(this.videoServerModel.videoServers)
    } catch (error) {
      console.warn('[HomePage] 加载数据源状态失败', (error as BusinessError).message ?? String(error))
    }
  }

  aboutToAppear(): void {
    this.loadSourceState()
    // 注入失败日志存储的 context，并清空上次运行的临时失败日志（关 app 可清理）
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext !== undefined && hostContext !== null) {
        ScrapeFailureLogStore.setContext(hostContext);
        ScrapeFailureLogStore.clearAll().catch((): void => {});
        // 注入自动刮削触发器的 context（定向扫描需要 UIAbilityContext），与日志存储同一注入时机
        AutoScrapeTrigger.getInstance().setContext(hostContext);
      }
    } catch (e) {
      // 忽略注入失败，store 内部有 /tmp 兜底目录
    }
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
