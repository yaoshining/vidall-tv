import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { AppPreferences, PrefKey } from "../../../utils/AppPreferences";
import promptAction from '@ohos.promptAction';

@ComponentV2
struct ResourceLibrarySettingBuilderComponent {
  @Local tmdbApiKey: string = '';
  @Local isLoading: boolean = false;

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    try {
      this.tmdbApiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
    } catch (error) {
      console.error('[ResourceLibrarySettingBuilder] 加载设置失败:', JSON.stringify(error));
    }
  }

  private showApiKeyDialog(): void {
    AlertDialog.show({
      title: 'TMDB API Key 配置',
      message: 'TMDB (The Movie Database) 是免费的电影数据库，需要注册获取 API Key。\n\n' +
        '获取步骤：\n' +
        '1. 访问 themoviedb.org 注册账号\n' +
        '2. 进入设置 → API 获取 API Key (v3 auth)\n' +
        '3. 将 API Key 填入下方输入框',
      autoCancel: false,
      buttons: [
        {
          text: '取消',
          action: () => {}
        },
        {
          text: '配置',
          action: () => {
            this.showApiKeyInputDialog();
          }
        }
      ]
    });
  }

  private showApiKeyInputDialog(): void {
    // 使用 TextInput 的 AlertDialog 变体
    const inputValue: string = this.tmdbApiKey;

    AlertDialog.show({
      title: '输入 TMDB API Key',
      message: '当前值：' + (this.tmdbApiKey ? '已配置' : '未配置'),
      autoCancel: false,
      buttons: [
        {
          text: '取消',
          action: () => {}
        },
        {
          text: '保存',
          action: () => {
            // 由于 AlertDialog 不支持 TextInput，我们使用 prompt 方式
            this.showPromptForApiKey();
          }
        },
        {
          text: '清除',
          action: () => {
            this.saveApiKey('');
          }
        }
      ]
    });
  }

  private showPromptForApiKey(): void {
    // HarmonyOS AlertDialog 不支持输入框，需要创建自定义对话框
    // 暂时使用简化方案：点击后显示当前值，引导用户手动输入
    promptAction.showDialog({
      title: '设置 API Key',
      message: '请使用设置页面输入框修改 API Key',
      buttons: [
        {
          text: '确定',
          color: '#007DFF'
        }
      ]
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
          .onClick(() => {
            this.showApiKeyDialog();
          })

          // API Key 输入框（简化方案）
          if (this.tmdbApiKey) {
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
    }
  }
}

@Builder
export function ResourceLibrarySettingBuilder() {
  ResourceLibrarySettingBuilderComponent()
}

