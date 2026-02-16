import SettingType from "./SettingType";

@ObservedV2
export class SettingsController {
  @Trace title: string = "设置"
  @Trace type: SettingType = SettingType.HOME
}