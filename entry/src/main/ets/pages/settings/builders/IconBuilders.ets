import { FileSourceType } from "../../../db/models/FileSourceEntity"
import { VideoServerType } from "../../../db/models/VideoServerEntity"

@Builder
export function SmbIcon() {
  Image($r('app.media.windows'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function WebdavIcon() {
  Image($r('app.media.global_folder'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function AliyunIcon() {
  Image($r('app.media.aliyun_drive'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function Cloud139Icon() {
  Image($r('app.media.netdisk_139'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function BaiduIcon() {
  Image($r('app.media.baidu_netdisk'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function Cloud123Icon() {
  Image($r('app.media.drive_123'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function Cloud115Icon() {
  Image($r('app.media.netdisk_115'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function OtherIcon() {
  Image($r('app.media.cloud_drive'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

function getSourceIconResource(type: FileSourceType): Resource {
  switch (type) {
    case FileSourceType.WEBDAV:    return $r('app.media.global_folder');
    case FileSourceType.SMB:       return $r('app.media.windows');
    case FileSourceType.ALIYUN:    return $r('app.media.aliyun_drive');
    case FileSourceType.CLOUD_139: return $r('app.media.netdisk_139');
    case FileSourceType.BAIDU:     return $r('app.media.baidu_netdisk');
    case FileSourceType.CLOUD_123: return $r('app.media.drive_123');
    case FileSourceType.CLOUD_115: return $r('app.media.netdisk_115');
    default:                       return $r('app.media.cloud_drive');
  }
}

@Builder
export function SourceTypeIcon(type: FileSourceType) {
  Image(getSourceIconResource(type))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

// ── 影视服务器图标 ───────────────────────────────────────────

function getVideoServerIconResource(type: VideoServerType): Resource {
  switch (type) {
    case VideoServerType.JELLYFIN: return $r('app.media.jellyfin');
    case VideoServerType.EMBY:     return $r('app.media.emby');
    case VideoServerType.PLEX:     return $r('app.media.plex');
    default:                       return $r('app.media.cloud_drive');
  }
}

@Builder
export function JellyfinIcon() {
  Image($r('app.media.jellyfin'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function EmbyIcon() {
  Image($r('app.media.emby'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function PlexIcon() {
  Image($r('app.media.plex'))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

@Builder
export function VideoServerTypeIcon(type: VideoServerType) {
  Image(getVideoServerIconResource(type))
    .width(30)
    .height(30)
    .objectFit(ImageFit.Contain)
}

