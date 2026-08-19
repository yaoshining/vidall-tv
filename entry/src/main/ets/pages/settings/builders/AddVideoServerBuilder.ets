import { SettingContainer } from "../SettingContainer"
import { SettingListItem } from "../SettingListItem"
import { SettingListItemGroup } from "../SettingListItemGroup"
import { SettingsController } from "../SettingsController"
import SettingType from "../SettingType"
import { JellyfinIcon, EmbyIcon, PlexIcon } from "./IconBuilders"

@ComponentV2
struct AddVideoServerBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  private pushConfig(type: SettingType, serverType: string): void {
    const params: Record<string, Object> = {}
    params['serverType'] = serverType as Object
    this.controller.pushType(type, params)
  }

  build() {
    SettingContainer({
      title: "添加影视服务器"
    }) {
      SettingListItemGroup({
        title: "服务器类型"
      }) {
        SettingListItem({
          title: "Jellyfin",
          iconBuilder: JellyfinIcon,
          isLink: true,
          onItemClick: () => {
            this.pushConfig(SettingType.JELLYFIN_CONFIG, 'jellyfin')
          }
        })

        SettingListItem({
          title: "Emby",
          iconBuilder: EmbyIcon,
          isLink: true,
          onItemClick: () => {
            this.pushConfig(SettingType.EMBY_CONFIG, 'emby')
          }
        })

        SettingListItem({
          title: "Plex",
          iconBuilder: PlexIcon,
          isLink: true,
          onItemClick: () => {
            this.pushConfig(SettingType.PLEX_CONFIG, 'plex')
          }
        })
      }
    }
  }
}

@Builder
export function AddVideoServerBuilder() {
  AddVideoServerBuilderComponent()
}
