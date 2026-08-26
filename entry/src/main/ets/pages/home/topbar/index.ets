import { IBestButton, IBestDivider, IBestIcon, IBestToast } from "@ibestservices/ibest-ui"
import { LengthMetrics } from "@kit.ArkUI"
import { LucideCloudDownload, LucideServer } from "lucide"
import { BasicClock } from "../../../components/common/BasicClock"
import { SettingsPage, SettingsPageParam } from "../../settings/Index"
import SettingType from "../../settings/SettingType"
import { SearchWorkspacePage } from "../../search"
import { SourceSwitchModel } from "../../../stores/media/SourceSwitchModel"
import { ScrapeTaskIndicator } from "../../../components/scrape/ScrapeTaskIndicator"

@ComponentV2
export struct HomeTopBar {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Event onHomeClick: () => void = () => {}
  sourceSwitchModel: SourceSwitchModel = SourceSwitchModel.getState()

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
    } else if (name === 'server') {
      LucideServer({
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
            // this.sidebarModel.sidebarOpened = true
            this.pageStack.pushPath({
              name: SettingsPage.PAGE_NAME
            })
          }
        })
        IBestDivider({ vertical: true })
        IBestButton({
          text: this.sourceSwitchModel.getDisplayName(),
          buttonSize: "small",
          btnBorderColor: Color.Transparent,
          iconBuilder: (): void => this.settingIBestIconBuilder('sort'),
          onBtnClick: () => {
            this.onHomeClick()
          }
        })

        IBestButton({
          buttonSize: "small",
          btnBorderColor: Color.Transparent,
          iconBuilder: (): void => this.settingIBestIconBuilder('search'),
          onBtnClick: () => {
            this.pageStack.pushPathByName(SearchWorkspacePage.PAGE_NAME, null)
          }
        }).bindTips('搜索')

        IBestButton({
          buttonSize: "small",
          btnBorderColor: Color.Transparent,
          iconBuilder: (): void => this.settingLucideIconBuilder('cloud-download')
        }).bindTips('获取云端数据')

        IBestButton({
          buttonSize: "small",
          btnBorderColor: Color.Transparent,
          onBtnClick: () => {
            this.pageStack.pushPath({
              name: SettingsPage.PAGE_NAME,
              param: {
                type: SettingType.FILE_SOURCE
              } as SettingsPageParam
            })
          },
          iconBuilder: (): void => this.settingHuaweiIconBuilder($r('sys.symbol.folder_badge_plus'))
        })
          .bindTips('添加/修改文件源')

        IBestButton({
          buttonSize: "small",
          btnBorderColor: Color.Transparent,
          onBtnClick: () => {
            this.pageStack.pushPath({
              name: SettingsPage.PAGE_NAME,
              param: {
                type: SettingType.ADD_VIDEO_SERVER
              } as SettingsPageParam
            })
          },
          iconBuilder: (): void => this.settingLucideIconBuilder('server')
        })
          .bindTips('添加影视服务器')
      }

      Flex({
        justifyContent: FlexAlign.End,
        alignItems: ItemAlign.Center,
      }) {
        ScrapeTaskIndicator()
          .margin({ right: 10 })
        BasicClock()
          .margin({ right: 12 })
        Image($r('app.media.logo'))
          .width(36)
        Text("idAll")
          .fontSize(26)
      }
    }
    .padding({ left: 20, right: 20, top: 20, bottom: 10 })
  }
}
