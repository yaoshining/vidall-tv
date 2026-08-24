import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { AppPreferences, PrefKey } from "../../../utils/AppPreferences";
import { UmamiAnalyticsService } from "../../../services/analytics/UmamiAnalyticsService";
import { UmamiEventData } from "../../../services/analytics/UmamiReporter";

@ComponentV2
struct ResourceLibrarySettingBuilderComponent {
  @Local tmdbApiKey: string = '';
  @Local confirmLocalScrapeCandidate: boolean = false;
  @Local isLoading: boolean = false;

  private showToastSafe(message: string, duration: number = 2000): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration })
    } catch (_e) {}
  }

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    try {
      this.tmdbApiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      this.confirmLocalScrapeCandidate =
        (await AppPreferences.getNumber(PrefKey.LOCAL_SCRAPE_CONFIRM_CANDIDATE, 0)) === 1;
    } catch (error) {
      console.error('[ResourceLibrarySettingBuilder] 加载设置失败:', JSON.stringify(error));
    }
  }

  private async saveConfirmLocalScrapeCandidate(enabled: boolean): Promise<void> {
    const previousValue = this.confirmLocalScrapeCandidate;
    this.confirmLocalScrapeCandidate = enabled;
    try {
      await AppPreferences.set(PrefKey.LOCAL_SCRAPE_CONFIRM_CANDIDATE, enabled ? 1 : 0);
      if (UmamiAnalyticsService.isInitialized()) {
        const evtData: UmamiEventData = {
          setting_key: 'LOCAL_SCRAPE_CONFIRM_CANDIDATE',
          new_value: enabled ? 'enabled' : 'disabled'
        };
        UmamiAnalyticsService.getInstance().trackEvent('settings', 'settings_changed', evtData);
      }
    } catch (error) {
      this.confirmLocalScrapeCandidate = previousValue;
      console.error('[ResourceLibrarySettingBuilder] 保存局部刮削确认设置失败:', JSON.stringify(error));
      this.showToastSafe('保存失败，请重试');
    }
  }

  private showClearApiKeyDialog(): void {
    this.getUIContext().showAlertDialog({
      title: '清除 API Key',
      message: '确定要清除已配置的 TMDB API Key 吗？',
      autoCancel: false,
      secondaryButton: {
        value: '取消',
        action: () => {}
      },
      primaryButton: {
        value: '清除',
        action: () => {
          this.saveApiKey('');
        }
      }
    });
  }

  private async saveApiKey(value: string): Promise<void> {
    this.isLoading = true;
    try {
      await AppPreferences.set(PrefKey.TMDB_API_KEY, value);
      this.tmdbApiKey = value;
      if (UmamiAnalyticsService.isInitialized()) {
        const evtData: UmamiEventData = { setting_key: 'TMDB_API_KEY', new_value: value ? 'set' : 'cleared' };
        UmamiAnalyticsService.getInstance().trackEvent('settings', 'settings_changed', evtData);
      }
      this.showToastSafe(value ? 'API Key 已保存' : 'API Key 已清除');
    } catch (error) {
      console.error('[ResourceLibrarySettingBuilder] 保存失败:', JSON.stringify(error));
      this.showToastSafe('保存失败，请检查存储权限后重试');
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    SettingContainer({
      title: "资源库"
    }) {
      SettingListItemGroup({
        title: "元数据设置"
      }) {
        // TMDB API Key 配置
        Column() {
          Row() {
            Text('TMDB API Key')
              .fontSize(16)
              .fontColor('#E0E0E0')
              .layoutWeight(1)
            Text(this.tmdbApiKey ? '已配置' : '未配置')
              .fontSize(14)
              .fontColor(this.tmdbApiKey ? '#4CAF50' : '#999999')
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })

          // 始终显示输入框，支持首次配置和更新
          TextInput({ text: this.tmdbApiKey, placeholder: "输入 TMDB API Key" })
            .type(InputType.Password)
            .height(40)
            .fontSize(14)
            .margin({ left: 16, right: 16, bottom: 8 })
            .enabled(!this.isLoading)
            .onChange((value: string) => {
              this.tmdbApiKey = value;
            })
            .onSubmit(() => {
              this.saveApiKey(this.tmdbApiKey);
            })

          // 保存按钮（始终显示）
          Button('保存')
            .width('90%')
            .height(36)
            .fontSize(14)
            .margin({ left: 16, right: 16, bottom: 8 })
            .enabled(!this.isLoading && this.tmdbApiKey.length > 0)
            .onClick(() => {
              this.saveApiKey(this.tmdbApiKey);
            })

          // 清除按钮（仅已配置时显示）
          if (this.tmdbApiKey) {
            Button('清除 API Key')
              .width('90%')
              .height(36)
              .fontSize(14)
              .fontColor('#FF5252')
              .margin({ left: 16, right: 16, bottom: 8 })
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.isLoading)
              .onClick(() => {
                this.showClearApiKeyDialog();
              })
          }
        }
        .backgroundColor('#1E1E1E')

        ListItem() {
          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Text('局部刮削时选择匹配结果')
                .fontSize(16)
                .fontColor('#F5F5F5')
              Text('开启后，电影、剧集、季、单集和文件夹刮削会先显示候选；全局刮削不受影响。')
                .fontSize(12)
                .fontColor('#A0A0A0')
                .maxLines(3)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.confirmLocalScrapeCandidate })
              .onChange((isOn: boolean) => {
                this.saveConfirmLocalScrapeCandidate(isOn);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .backgroundColor('#333333')
          .borderRadius(8)
        }

        SettingListItem({
          title: "刮削服务",
          value: "TMDB",
          isLink: false
        })
        SettingListItem({
          title: "语言",
          value: "简体中文",
          isLink: false
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
}

@Builder
export function ResourceLibrarySettingBuilder() {
  ResourceLibrarySettingBuilderComponent()
}

