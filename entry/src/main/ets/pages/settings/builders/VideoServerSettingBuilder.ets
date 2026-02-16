import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";

@Builder
export function VideoServerSettingBuilder() {
  SettingContainer({
    title: "影视服务器"
  }) {
    SettingListItemGroup({
      title: "服务器配置"
    }) {
      SettingListItem({
        title: "添加服务器",
        isLink: true
      })
    }

    SettingListItemGroup({
      title: "已添加的服务器"
    }) {
      SettingListItem({
        title: "暂无服务器"
      })
    }
  }
}

