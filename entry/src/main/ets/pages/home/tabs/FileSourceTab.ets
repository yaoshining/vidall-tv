import { LengthMetrics } from "@kit.ArkUI"
import { FileExplorerPage } from "../../files"

@ComponentV2
export struct FileSourceTab {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  build() {
    GridRow({
      gutter: 10,
      columns: 2
    }) {
      ForEach(Array.from(Array(10)), () => {
        GridCol() {
          Flex({
            alignItems: ItemAlign.Center,
            justifyContent: FlexAlign.Start,
            space: {
              main: LengthMetrics.vp(20)
            }
          }) {
            Image($r('app.media.empty_folder'))
              .height("100%")
            Flex({
              direction: FlexDirection.Column,
              justifyContent: FlexAlign.SpaceAround,
            }) {
              Text("全部文件")
                .fontSize($r('app.float.font_subtitle_1'))
                .fontWeight(FontWeight.Bold)
              Text("我的WebDAV")
                .opacity(0.6)
            }
            .height("100%")
          }
        }
        .onClick(() => {
          this.pageStack.pushPath({
            name: FileExplorerPage.PAGE_NAME
          }, false)
        })
        .height(80)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .borderRadius(6)
        .backgroundColor("#373737")
        .hoverEffect(HoverEffect.Highlight)
      })
    }
  }
}