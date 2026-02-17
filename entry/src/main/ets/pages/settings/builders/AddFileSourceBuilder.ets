import { SettingContainer } from "../SettingContainer"
import { SettingListItem } from "../SettingListItem"
import { SettingListItemGroup } from "../SettingListItemGroup"
import {
  SmbIcon,
  WebdavIcon,
  AliyunIcon,
  Cloud139Icon,
  BaiduIcon,
  Cloud123Icon,
  Cloud115Icon,
  OtherIcon
} from "./IconBuilders"

@Builder
export function AddFileSourceBuilder() {
  SettingContainer({
    title: "添加文件源"
  }) {
    SettingListItemGroup({
      title: "网络"
    }) {
      SettingListItem({
        title: "SMB",
        iconBuilder: SmbIcon
      })

      SettingListItem({
        title: "WebDAV / Alist",
        iconBuilder: WebdavIcon
      })
    }

    SettingListItemGroup({
      title: "云盘"
    }) {
      SettingListItem({
        title: "阿里云盘",
        iconBuilder: AliyunIcon
      })

      SettingListItem({
        title: "139网盘",
        iconBuilder: Cloud139Icon
      })

      SettingListItem({
        title: "百度网盘",
        iconBuilder: BaiduIcon
      })

      SettingListItem({
        title: "123网盘",
        iconBuilder: Cloud123Icon
      })

      SettingListItem({
        title: "115网盘",
        iconBuilder: Cloud115Icon
      })

      SettingListItem({
        title: "其他网盘服务",
        iconBuilder: OtherIcon
      })
    }
  }
}