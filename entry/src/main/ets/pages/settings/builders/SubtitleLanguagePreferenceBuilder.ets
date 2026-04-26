import { SettingContainer } from "../SettingContainer"
import { SettingListItemGroup } from "../SettingListItemGroup"
import {
  buildSubtitleLanguageActions,
  buildSubtitleLanguagePreferenceSummary,
  DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE,
  getSubtitleLanguageDisplayName,
  loadSubtitleLanguagePreference,
  moveSubtitleLanguagePreference,
  saveSubtitleLanguagePreference,
  shouldApplySubtitleLanguagePreferenceLoad,
  SubtitleLanguageAction,
  SubtitleLanguageActionType,
  SubtitleLanguageOption,
  SubtitleLanguagePreference,
  SUBTITLE_LANGUAGE_OPTIONS
} from "../../../subtitle/SubtitleLanguagePreference"

@ComponentV2
struct SubtitleLanguagePreferenceBuilderComponent {
  @Local selectedLanguages: string[] = [...DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.languages]
  @Local hideOtherLanguages: boolean = DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.hideOtherLanguages
  @Local isPreferenceLoaded: boolean = false
  private preferenceLoadVersion: number = 0
  private hasLocalPreferenceChange: boolean = false

  aboutToAppear(): void {
    this.loadPreference()
  }

  private async loadPreference(): Promise<void> {
    this.isPreferenceLoaded = false
    this.preferenceLoadVersion += 1
    const currentLoadVersion = this.preferenceLoadVersion
    try {
      const preference = await loadSubtitleLanguagePreference()
      if (!shouldApplySubtitleLanguagePreferenceLoad(
        currentLoadVersion,
        this.preferenceLoadVersion,
        this.hasLocalPreferenceChange
      )) {
        return
      }
      this.selectedLanguages = [...preference.languages]
      this.hideOtherLanguages = preference.hideOtherLanguages
      this.isPreferenceLoaded = true
    } catch {
      if (!shouldApplySubtitleLanguagePreferenceLoad(
        currentLoadVersion,
        this.preferenceLoadVersion,
        this.hasLocalPreferenceChange
      )) {
        return
      }
      this.selectedLanguages = [...DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.languages]
      this.hideOtherLanguages = DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE.hideOtherLanguages
      this.isPreferenceLoaded = true
    }
  }

  private buildPreference(): SubtitleLanguagePreference {
    const preference: SubtitleLanguagePreference = {
      languages: [...this.selectedLanguages],
      hideOtherLanguages: this.hideOtherLanguages
    }
    return preference
  }

  private getLanguageRank(languageCode: string): number {
    return this.selectedLanguages.indexOf(languageCode)
  }

  private isLanguageSelected(languageCode: string): boolean {
    return this.getLanguageRank(languageCode) >= 0
  }

  private canMoveLanguageUp(languageCode: string): boolean {
    return this.getLanguageRank(languageCode) > 0
  }

  private canMoveLanguageDown(languageCode: string): boolean {
    const rank = this.getLanguageRank(languageCode)
    return rank >= 0 && rank < this.selectedLanguages.length - 1
  }

  private getDisplayOptions(): SubtitleLanguageOption[] {
    const selectedOptions: SubtitleLanguageOption[] = []
    const remainingOptions: SubtitleLanguageOption[] = []
    for (let index = 0; index < this.selectedLanguages.length; index++) {
      const languageCode = this.selectedLanguages[index]
      for (let optionIndex = 0; optionIndex < SUBTITLE_LANGUAGE_OPTIONS.length; optionIndex++) {
        const option = SUBTITLE_LANGUAGE_OPTIONS[optionIndex]
        if (option.code === languageCode) {
          selectedOptions.push(option)
          break
        }
      }
    }
    for (let optionIndex = 0; optionIndex < SUBTITLE_LANGUAGE_OPTIONS.length; optionIndex++) {
      const option = SUBTITLE_LANGUAGE_OPTIONS[optionIndex]
      if (!this.selectedLanguages.includes(option.code)) {
        remainingOptions.push(option)
      }
    }
    return [...selectedOptions, ...remainingOptions]
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message,
        duration: 1500
      })
    } catch {
      console.warn(`[SubtitleLanguagePreferenceBuilder] toast failed: ${message}`)
    }
  }

  private ensurePreferenceLoaded(): boolean {
    if (this.isPreferenceLoaded) {
      return true
    }
    this.showToast('正在读取已保存配置')
    return false
  }

  private async persistPreference(successMessage: string): Promise<void> {
    this.hasLocalPreferenceChange = true
    await saveSubtitleLanguagePreference(this.buildPreference())
    this.showToast(successMessage)
  }

  private async toggleLanguage(languageCode: string): Promise<void> {
    if (!this.ensurePreferenceLoaded()) {
      return
    }
    if (this.isLanguageSelected(languageCode)) {
      if (this.selectedLanguages.length === 1) {
        this.showToast('至少保留 1 种语言')
        return
      }
      this.selectedLanguages = this.selectedLanguages.filter((code: string) => code !== languageCode)
      await this.persistPreference('已更新字幕语言偏好')
      return
    }

    if (this.selectedLanguages.length >= 3) {
      this.showToast('最多选择 3 种语言')
      return
    }
    this.selectedLanguages = [...this.selectedLanguages, languageCode]
    await this.persistPreference('已添加字幕语言')
  }

  private async moveLanguage(languageCode: string, direction: 'up' | 'down'): Promise<void> {
    if (!this.ensurePreferenceLoaded()) {
      return
    }
    const nextPreference = moveSubtitleLanguagePreference(this.buildPreference(), languageCode, direction)
    const beforeSnapshot = this.selectedLanguages.join(',')
    const afterSnapshot = nextPreference.languages.join(',')
    if (beforeSnapshot === afterSnapshot) {
      return
    }
    this.selectedLanguages = [...nextPreference.languages]
    await this.persistPreference(direction === 'up' ? '已上移语言优先级' : '已下移语言优先级')
  }

  private async updateHideOtherLanguages(isEnabled: boolean): Promise<void> {
    if (!this.ensurePreferenceLoaded()) {
      return
    }
    this.hideOtherLanguages = isEnabled
    await this.persistPreference(isEnabled ? '已隐藏非偏好语言' : '已显示全部语言')
  }

  private getLanguageActions(languageCode: string): SubtitleLanguageAction[] {
    return buildSubtitleLanguageActions(this.buildPreference(), languageCode)
  }

  private async handleLanguageAction(languageCode: string, actionType: SubtitleLanguageActionType): Promise<void> {
    if (actionType === 'enable' || actionType === 'disable') {
      await this.toggleLanguage(languageCode)
      return
    }
    if (actionType === 'move-up') {
      await this.moveLanguage(languageCode, 'up')
      return
    }
    await this.moveLanguage(languageCode, 'down')
  }

  private getActionButtonFontColor(action: SubtitleLanguageAction): string {
    return action.enabled ? '#F5F5F5' : '#6F6F6F'
  }

  private getActionButtonBackgroundColor(action: SubtitleLanguageAction): string {
    return action.enabled ? '#3F3F3F' : '#2B2B2B'
  }

  build() {
    SettingContainer({
      title: "字幕语言偏好"
    }) {
      SettingListItemGroup({
        title: "当前配置"
      }) {
        ListItem() {
          Column({ space: 8 }) {
            Text(this.isPreferenceLoaded
              ? buildSubtitleLanguagePreferenceSummary(this.buildPreference())
              : '正在加载字幕语言偏好…')
              .fontSize(16)
              .fontColor('#F5F5F5')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('最多选择 3 种语言；方向键聚焦到已选择语言后，可直接用上下键调整优先级。')
              .fontSize(13)
              .fontColor('#A0A0A0')
              .maxLines(3)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .backgroundColor('#333333')
          .borderRadius(8)
        }
      }

      SettingListItemGroup({
        title: "语言优先级"
      }) {
        if (!this.isPreferenceLoaded) {
          ListItem() {
            Text('正在读取已保存配置，请稍候。')
              .fontSize(14)
              .fontColor('#A0A0A0')
              .padding({ left: 16, right: 16, top: 18, bottom: 18 })
          }
          .backgroundColor('#333333')
          .borderRadius(8)
        } else {
          ForEach(this.getDisplayOptions(), (option: SubtitleLanguageOption) => {
            ListItem() {
              Row({ space: 12 }) {
                Checkbox()
                  .select(this.isLanguageSelected(option.code))
                  .selectedColor('#4CAF50')
                  .hitTestBehavior(HitTestMode.Transparent)

                Column({ space: 6 }) {
                  Text(option.label)
                    .fontSize(16)
                    .fontColor('#F5F5F5')
                  Text(this.isLanguageSelected(option.code)
                    ? `优先级 #${this.getLanguageRank(option.code) + 1} · 搜索参数 ${option.code}`
                    : `未启用 · 搜索参数 ${option.code}`)
                    .fontSize(12)
                    .fontColor('#A0A0A0')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row({ space: 8 }) {
                  ForEach(this.getLanguageActions(option.code), (action: SubtitleLanguageAction) => {
                    Button(action.label)
                      .enabled(action.enabled)
                      .fontSize(12)
                      .fontColor(this.getActionButtonFontColor(action))
                      .backgroundColor(this.getActionButtonBackgroundColor(action))
                      .borderRadius(8)
                      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                      .onClick(() => {
                        this.handleLanguageAction(option.code, action.type)
                      })
                  }, (action: SubtitleLanguageAction): string => action.type)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .alignItems(VerticalAlign.Center)
              .backgroundColor('#333333')
              .borderRadius(8)
            }
          }, (option: SubtitleLanguageOption) => option.code)
        }
      }

      SettingListItemGroup({
        title: "结果过滤"
      }) {
        ListItem() {
          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Text('隐藏非偏好语言')
                .fontSize(16)
                .fontColor('#F5F5F5')
              Text('开启后，后续字幕搜索结果只保留偏好语言；关闭时保留全部结果但优先语言置顶。')
                .fontSize(12)
                .fontColor('#A0A0A0')
                .maxLines(3)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.hideOtherLanguages })
              .enabled(this.isPreferenceLoaded)
              .onChange((isOn: boolean) => {
                this.updateHideOtherLanguages(isOn)
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .backgroundColor('#333333')
          .borderRadius(8)
        }
      }
    }
  }
}

@Builder
export function SubtitleLanguagePreferenceBuilder() {
  SubtitleLanguagePreferenceBuilderComponent()
}
