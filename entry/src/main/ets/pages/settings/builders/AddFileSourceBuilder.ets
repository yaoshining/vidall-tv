import { SettingContainer } from "../SettingContainer"
import { SettingListItem } from "../SettingListItem"
import { SettingListItemGroup } from "../SettingListItemGroup"

@Builder
export function AddFileSourceBuilder() {
  SettingContainer({
    title: "添加文件源"
  }) {
    SettingListItemGroup({
      title: "网络"
    }) {
      SettingListItem({
        title: "SMB"
      })

      SettingListItem({
        title: "WebDAV / Alist"
      })
    }

    SettingListItemGroup({
      title: "云盘"
    }) {
      SettingListItem({
        title: "阿里云盘"
      })
      SettingListItem({
        title: "139网盘"
      })
      SettingListItem({
        title: "百度网盘"
      })
      SettingListItem({
        title: "123网盘"
      })
      SettingListItem({
        title: "115网盘"
      })
    }
  }
}