import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";

@Builder
export function FileSourceSettingBuilder() {
  SettingContainer({
    title: "文件源"
  }) {
    SettingListItemGroup({
      title: "已添加的文件源"
    }) {
      SettingListItem({
        title: "暂无文件源"
      })

      SettingListItem({
        title: "添加文件源",
        isLink: true
      })
    }
  }
}