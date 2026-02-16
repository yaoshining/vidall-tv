import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";

@Builder
export function FileSourceSettingBuilder() {
  SettingContainer({
    title: "文件源配置"
  }) {
    SettingListItemGroup() {
      SettingListItem() {
        Text("asdasd")
      }
    }
  }
}