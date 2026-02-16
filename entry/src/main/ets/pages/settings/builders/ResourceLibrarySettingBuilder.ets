import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";

@Builder
export function ResourceLibrarySettingBuilder() {
  SettingContainer({
    title: "资源库"
  }) {
    SettingListItemGroup({
      title: "资源库设置"
    }) {
      SettingListItem({
        title: "刮削服务",
        value: "TMDB",
        isLink: true
      })
      SettingListItem({
        title: "语言",
        value: "简体中文",
        isLink: true
      })
      SettingListItem({
        title: "自动刮削",
        value: "开启"
      })
    }

    SettingListItemGroup({
      title: "缓存"
    }) {
      SettingListItem({
        title: "清除海报缓存",
        isLink: true
      })
      SettingListItem({
        title: "清除元数据缓存",
        isLink: true
      })
    }
  }
}

