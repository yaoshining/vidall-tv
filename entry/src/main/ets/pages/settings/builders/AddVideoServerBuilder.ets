import { SettingContainer } from "../SettingContainer"
import { SettingListItem } from "../SettingListItem"
import { SettingListItemGroup } from "../SettingListItemGroup"
import { SettingsController } from "../SettingsController"
import SettingType from "../SettingType"
import { JellyfinIcon, EmbyIcon, PlexIcon } from "./IconBuilders"

@ComponentV2
struct AddVideoServerBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

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
            const params: Record<string, Object> = {}
            params['serverType'] = 'jellyfin' as Object
            this.controller.pushType(SettingType.JELLYFIN_CONFIG, params)
          }
        })

        SettingListItem({
          title: "Emby",
          iconBuilder: EmbyIcon,
          isLink: true,
          onItemClick: () => {
            const params: Record<string, Object> = {}
            params['serverType'] = 'emby' as Object
            this.controller.pushType(SettingType.EMBY_CONFIG, params)
          }
        })

        SettingListItem({
          title: "Plex",
          iconBuilder: PlexIcon,
          isLink: true,
          onItemClick: () => {
            const params: Record<string, Object> = {}
            params['serverType'] = 'plex' as Object
            this.controller.pushType(SettingType.PLEX_CONFIG, params)
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
