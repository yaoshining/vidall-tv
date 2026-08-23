import { SidebarStore } from '../stores/sidebar/SidebarStore';
import { SidebarModel } from '../stores/sidebar/SidebarModel';
import { SourceSwitchModel } from '../stores/media/SourceSwitchModel';
import { FileExplorerPage } from './files';
import { SmbFileExplorerPage } from './files/SmbFileExplorerPage';
import { HomePage } from './home';
import { PlayerPage } from './player/index';
import { SettingsPage } from './settings/Index';
import { SeriesDetailPage } from './detail/SeriesDetailPage';
import { SeasonDetailPage } from './detail/SeasonDetailPage';
import { MovieDetailPage } from './detail/MovieDetailPage';
import { CastDetailPage } from './detail/CastDetailPage';
import { ServerMediaDetailPage } from './detail/ServerMediaDetailPage';
import { ServerSeasonDetailPage } from './detail/ServerSeasonDetailPage';
import { ServerPersonDetailPage } from './detail/ServerPersonDetailPage';
import { ServerLibraryListPage } from './detail/ServerLibraryListPage';
import { PlayHistoryPage } from './history/PlayHistoryPage';
import { SearchWorkspacePage } from './search';
import { MediaResultPage } from './search';
import { LoginDialog } from '../components/account/LoginDialog';
import { LogoutConfirmDialog } from '../components/account/LogoutConfirmDialog';
import { AccountModel } from '../stores/account/AccountModel';
@Entry
@ComponentV2
struct Index {
  sidebarModel: SidebarModel = SidebarStore.getState()
  @Local accountModel: AccountModel = AccountModel.getInstance()
  @Provider('pageStack') pageStack: NavPathStack = new NavPathStack();

  onBackPress(): boolean {
    if (this.accountModel.logoutConfirmVisible) {
      this.accountModel.hideLogoutConfirm();
      return true;
    }
    if (this.accountModel.loginDialogVisible) {
      this.accountModel.hideLoginDialog();
      return true;
    }
    // 数据源切换弹窗打开时，返回键仅关闭弹窗，不退出 App
    const model = SourceSwitchModel.getState();
    if (model.sourceSwitchDialogVisible) {
      model.sourceSwitchDialogVisible = false;
      return true;
    }
    return false;
  }

  @Builder
  PageBuilder(name: string) {
    if (name === PlayerPage.PAGE_NAME) {
      PlayerPage();
    } else if (name === SettingsPage.PAGE_NAME) {
      SettingsPage();
    } else if (name === FileExplorerPage.PAGE_NAME) {
      FileExplorerPage();
    } else if (name === SmbFileExplorerPage.PAGE_NAME) {
      SmbFileExplorerPage();
    } else if (name === SeriesDetailPage.PAGE_NAME) {
      SeriesDetailPage();
    } else if (name === MovieDetailPage.PAGE_NAME) {
      MovieDetailPage();
    } else if (name === SeasonDetailPage.PAGE_NAME) {
      SeasonDetailPage();
    } else if (name === CastDetailPage.PAGE_NAME) {
      CastDetailPage();
    } else if (name === ServerMediaDetailPage.PAGE_NAME) {
      ServerMediaDetailPage();
    } else if (name === ServerSeasonDetailPage.PAGE_NAME) {
      ServerSeasonDetailPage();
    } else if (name === ServerPersonDetailPage.PAGE_NAME) {
      ServerPersonDetailPage();
    } else if (name === ServerLibraryListPage.PAGE_NAME) {
      ServerLibraryListPage();
    } else if (name === PlayHistoryPage.PAGE_NAME) {
      PlayHistoryPage();
    } else if (name === SearchWorkspacePage.PAGE_NAME) {
      SearchWorkspacePage();
    } else if (name === MediaResultPage.PAGE_NAME) {
      MediaResultPage();
    }
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

      if (this.accountModel.loginDialogVisible) {
        LoginDialog()
      }

      if (this.accountModel.logoutConfirmVisible) {
        LogoutConfirmDialog()
      }
    }
    .alignContent(Alignment.TopStart)
    .height('100%')
    .width('100%')
  }
}