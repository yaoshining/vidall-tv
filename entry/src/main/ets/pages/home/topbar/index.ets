import { IBestButton, IBestDivider, IBestIcon } from "@ibestservices/ibest-ui"
import { LengthMetrics } from "@kit.ArkUI"
import { LucideCloudDownload } from "lucide"
import { BasicClock } from "../../../components/common/BasicClock"
import { SettingsPage } from "../../settings/Index"

@ComponentV2
export struct HomeTopBar {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

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
  }
}