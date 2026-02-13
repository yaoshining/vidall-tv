import { LengthMetrics } from "@kit.ArkUI"
import { WebDAVConfig } from "../../../lib/WebDAVClient"
import { FileExplorerPage } from "../../files"

const config1: WebDAVConfig = {
  baseUrl: 'http://192.168.3.59:5445/dav',
  username: 'yao',
  password: 'ys198756'
}

const config2: WebDAVConfig = {
  baseUrl: 'http://dav.mypikpak.com',
  username: 'cdkd',
  password: 'dartvjhx'
}

@ComponentV2
export struct FileSourceTab {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  build() {
    GridRow({
      gutter: 10,
      columns: 2
    }) {
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
            Text("我的OpenList")
              .opacity(0.6)
          }
          .height("100%")
        }
      }
      .onClick(() => {
        this.pageStack.pushPath({
          name: FileExplorerPage.PAGE_NAME,
          param: config1 as WebDAVConfig
        }, false)
      })
      .height(80)
      .padding({ left: 20, right: 20, top: 10, bottom: 10 })
      .borderRadius(6)
      .backgroundColor("#373737")
      .hoverEffect(HoverEffect.Highlight)

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
            Text("我的PickPack")
              .opacity(0.6)
          }
          .height("100%")
        }
      }
      .onClick(() => {
        this.pageStack.pushPath({
          name: FileExplorerPage.PAGE_NAME,
          param: config2 as WebDAVConfig
        }, false)
      })
      .height(80)
      .padding({ left: 20, right: 20, top: 10, bottom: 10 })
      .borderRadius(6)
      .backgroundColor("#373737")
      .hoverEffect(HoverEffect.Highlight)

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
        .height(80)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .borderRadius(6)
        .backgroundColor("#373737")
        .hoverEffect(HoverEffect.Highlight)
      })
    }
  }
}