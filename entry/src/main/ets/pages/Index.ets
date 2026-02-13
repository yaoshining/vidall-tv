import { SidebarStore } from '../stores/sidebar/SidebarStore';
import { FileExplorerPage } from './files';
import { HomePage } from './home';
import { PlayerPage } from './player/index';
import { SettingsPage } from './settings/Index';

@Entry
@ComponentV2
struct Index {
  sidebarModel = SidebarStore.getState()
  @Provider('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Builder
  PageBuilder(name: string) {
    if (name === PlayerPage.PAGE_NAME) {
      PlayerPage();
    } else if (name === SettingsPage.PAGE_NAME) {
      SettingsPage();
    } else if (name === FileExplorerPage.PAGE_NAME) {
      FileExplorerPage();
    }
  }

  aboutToAppear(): void {
    this.pageStack.pushPath({ name: FileExplorerPage.PAGE_NAME })
  }

  build() {
    Stack() {
      Navigation(this.pageStack) {
        Scroll() {
          HomePage()
        }
        .height("100%")
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width("100%")
      .height("100%")
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .navDestination(this.PageBuilder)

      if (this.sidebarModel.sidebarOpened) {
        Column()
          .id("sidebarMask")
          .backgroundColor(Color.Black)
          .opacity(0.3)
          .onClick(() => {
            this.sidebarModel.sidebarOpened = false
          })
          .width("100%")
          .height("100%")

        RelativeContainer() {
          Button(`${this.sidebarModel.sidebarOpened}`)
            .onClick(() => {
              this.sidebarModel.sidebarOpened = !this.sidebarModel.sidebarOpened
            })
        }
        .id("sidebarContainer")
        .backgroundColor("#282828")
        .width(this.sidebarModel.sidebarOpened ? "35%" : 0)
        .height("100%")
      }
    }
    .alignContent(Alignment.TopStart)
    .height('100%')
    .width('100%')
  }
}