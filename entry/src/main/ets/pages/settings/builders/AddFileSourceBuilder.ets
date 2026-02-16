import { SettingContainer } from "../SettingContainer"
import { SettingListItem } from "../SettingListItem"
import { SettingListItemGroup } from "../SettingListItemGroup"

@Builder
function SmbIcon() {
  Image($r('app.media.windows'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function WebdavIcon() {
  Image($r('app.media.global_folder'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function AliyunIcon() {
  Image($r('app.media.aliyun_drive'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function Cloud139Icon() {
  Image($r('app.media.netdisk_139'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function BaiduIcon() {
  Image($r('app.media.baidu_netdisk'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function Cloud123Icon() {
  Image($r('app.media.drive_123'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function Cloud115Icon() {
  Image($r('app.media.netdisk_115'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
function OtherIcon() {
  Image($r('app.media.cloud_drive'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

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