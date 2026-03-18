import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { AppPreferences, PrefKey } from "../../../utils/AppPreferences";
import { PlayerEvents } from "../../../components/core/player/Constants";
import { emitter } from "@kit.BasicServicesKit";
import promptAction from '@ohos.promptAction';

@ComponentV2
struct ResourceLibrarySettingBuilderComponent {
  @Local tmdbApiKey: string = '';
  @Local nativeAudioOffsetText: string = '';
  @Local isLoading: boolean = false;

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    try {
      this.tmdbApiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      const nativeOffsetMs = await AppPreferences.getNumber(PrefKey.PLAYER_NATIVE_AUDIO_HARDWARE_OFFSET_MS, 120);
      this.nativeAudioOffsetText = `${nativeOffsetMs}`;
    } catch (error) {
      console.error('[ResourceLibrarySettingBuilder] 加载设置失败:', JSON.stringify(error));
    }
  }

  private showClearApiKeyDialog(): void {
    AlertDialog.show({
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
      promptAction.showToast({
        message: value ? 'API Key 已保存' : 'API Key 已清除'
      });
    } catch (error) {
      console.error('[ResourceLibrarySettingBuilder] 保存失败:', JSON.stringify(error));
      promptAction.showToast({
        message: '保存失败'
      });
    } finally {
      this.isLoading = false;
    }
  }

  private async saveNativeAudioOffset(value: string): Promise<void> {
    this.isLoading = true;
    try {
      const parsed = Number.parseInt(value.trim(), 10);
      const normalized = Number.isFinite(parsed)
        ? Math.max(-1500, Math.min(parsed, 1500))
        : 120;
      await AppPreferences.set(PrefKey.PLAYER_NATIVE_AUDIO_HARDWARE_OFFSET_MS, normalized);
      this.nativeAudioOffsetText = `${normalized}`;
      emitter.emit(PlayerEvents.NATIVE_AUDIO_OFFSET_CHANGED);
      promptAction.showToast({
        message: `当前设备音频补偿已保存: ${normalized}ms`
      });
    } catch (error) {
      console.error('[ResourceLibrarySettingBuilder] 保存 native 音频补偿失败:', JSON.stringify(error));
      promptAction.showToast({
        message: '保存失败'
      });
    } finally {
      this.isLoading = false;
    }
  }

  private resetNativeAudioOffset(): void {
    this.saveNativeAudioOffset('120');
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

      SettingListItemGroup({
        title: "播放调校（当前设备）"
      }) {
        Column() {
          Row() {
            Text('Native 音频补偿')
              .fontSize(16)
              .fontColor('#E0E0E0')
              .layoutWeight(1)
            Text(`${this.nativeAudioOffsetText.length > 0 ? this.nativeAudioOffsetText : '120'} ms`)
              .fontSize(14)
              .fontColor('#FFD700')
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })

            TextInput({ text: this.nativeAudioOffsetText, placeholder: '输入补偿毫秒，支持负数，默认 120' })
              .type(InputType.Normal)
              .height(40)
              .fontSize(14)
              .margin({ left: 16, right: 16, bottom: 8 })
              .enabled(!this.isLoading)
              .onChange((value: string) => {
                this.nativeAudioOffsetText = value;
              })
              .onSubmit(() => {
                this.saveNativeAudioOffset(this.nativeAudioOffsetText);
              })

          Text('值越大，画面越会“等声音”；声音领先画面时，请把值调小，必要时可用负数。')
            .fontSize(12)
            .fontColor('#999999')
            .margin({ left: 16, right: 16, bottom: 8 })

          Button('保存当前设备补偿')
            .width('90%')
            .height(36)
            .fontSize(14)
            .margin({ left: 16, right: 16, bottom: 8 })
            .enabled(!this.isLoading && this.nativeAudioOffsetText.length > 0)
            .onClick(() => {
              this.saveNativeAudioOffset(this.nativeAudioOffsetText);
            })

          Button('恢复默认补偿 120ms')
            .width('90%')
            .height(36)
            .fontSize(14)
            .margin({ left: 16, right: 16, bottom: 8 })
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.isLoading)
            .onClick(() => {
              this.resetNativeAudioOffset();
            })
        }
        .backgroundColor('#1E1E1E')
      }
    }
  }
}

@Builder
export function ResourceLibrarySettingBuilder() {
  ResourceLibrarySettingBuilderComponent()
}
