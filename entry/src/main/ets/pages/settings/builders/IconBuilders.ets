import { FileSourceType } from "../../../db/models/FileSourceEntity"

@Builder
export function SmbIcon() {
  Image($r('app.media.smb_folder'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function WebdavIcon() {
  Image($r('app.media.webdav_folder'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function AliyunIcon() {
  Image($r('app.media.aliyun_drive'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function Cloud139Icon() {
  Image($r('app.media.netdisk_139'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function BaiduIcon() {
  Image($r('app.media.baidu_netdisk'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function Cloud123Icon() {
  Image($r('app.media.drive_123'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function Cloud115Icon() {
  Image($r('app.media.netdisk_115'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function OtherIcon() {
  Image($r('app.media.empty_folder'))
    .width("100%")
    .height("100%")
    .objectFit(ImageFit.Contain)
}

@Builder
export function SourceTypeIcon(type: FileSourceType) {
  if (type === FileSourceType.WEBDAV) {
    WebdavIcon()
  } else if (type === FileSourceType.SMB) {
    SmbIcon()
  } else if (type === FileSourceType.ALIYUN) {
    AliyunIcon()
  } else if (type === FileSourceType.CLOUD_139) {
    Cloud139Icon()
  } else if (type === FileSourceType.BAIDU) {
    BaiduIcon()
  } else if (type === FileSourceType.CLOUD_123) {
    Cloud123Icon()
  } else if (type === FileSourceType.CLOUD_115) {
    Cloud115Icon()
  } else {
    OtherIcon()
  }
}

