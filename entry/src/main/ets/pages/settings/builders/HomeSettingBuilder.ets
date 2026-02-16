import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";

@Builder
export function HomeSettingBuilder() {
  SettingContainer({
    title: "配置"
  }) {
    SettingListItemGroup({
      title: "账号"
    }) {
      SettingListItem({
        title: "VidAll",
        value: "全平台可用"
      })
      SettingListItem({
        title: "退出登录",
        isLink: true
      })
    }

    SettingListItemGroup({
      title: "网络"
    }) {
      SettingListItem({
        title: "文件源",
        isLink: true
      })
      SettingListItem({
        title: "影视服务器",
        isLink: true
      })
      SettingListItem({
        title: "资源库",
        isLink: true
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