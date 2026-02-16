import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { SettingsController } from "../SettingsController";
import SettingType from "../SettingType";

@ComponentV2
struct HomeSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  @Builder
  userIcon() {
    Text("👤")
      .fontSize(20)
  }

  @Builder
  exitIcon() {
    Text("🚪")
      .fontSize(20)
  }

  @Builder
  folderIcon() {
    Text("📁")
      .fontSize(20)
  }

  @Builder
  serverIcon() {
    Text("🖥️")
      .fontSize(20)
  }

  @Builder
  libraryIcon() {
    Text("📚")
      .fontSize(20)
  }

  build() {
    SettingContainer({
      title: "配置"
    }) {
      SettingListItemGroup({
        title: "账号"
      }) {
        SettingListItem({
          title: "VidAll",
          value: "全平台可用",
          iconBuilder: this.userIcon
        })
        SettingListItem({
          title: "退出登录",
          isLink: true,
          iconBuilder: this.exitIcon
        })
      }

      SettingListItemGroup({
        title: "网络"
      }) {
        SettingListItem({
          title: "文件源",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.FILE_SOURCE)
          },
          iconBuilder: this.folderIcon
        })
        SettingListItem({
          title: "影视服务器",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.VIDEO_SERVER)
          },
          iconBuilder: this.serverIcon
        })
        SettingListItem({
          title: "资源库",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.RESOURCE_LIBRARY)
          },
          iconBuilder: this.libraryIcon
        })
      }

      SettingListItemGroup({
        title: "通用"
      }) {
        SettingListItem({
          title: "Trakt",
          value: "连接到Trakt",
          isLink: true
        })
        SettingListItem({
          title: "隐藏剧透",
          value: "关闭"
        })
        SettingListItem({
          title: "显示媒体库顶部分类栏",
          value: "开启"
        })
        SettingListItem({
          title: "媒体排序方式",
          value: "↓添加日期",
          isLink: true
        })
      }
    }
  }
}

@Builder
export function HomeSettingBuilder() {
  HomeSettingBuilderComponent()
}
