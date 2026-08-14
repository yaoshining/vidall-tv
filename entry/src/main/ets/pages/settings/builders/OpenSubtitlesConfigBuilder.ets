import { AppPreferences, PrefKey } from '../../../utils/AppPreferences'
import { SettingListItemGroup } from '../SettingListItemGroup'

/**
 * OpenSubtitles 字幕服务配置组件
 *
 * 功能：
 *  - 读取并展示当前 API Key 状态（官方代理 · 推荐 / 自定义 Key · 直连）
 *  - 遥控器确认键展开/收起 API Key 输入面板
 *  - 输入框脱敏展示（****+后4位），Password 类型支持遥控器调起系统键盘
 *  - 保存写入 AppPreferences；清除置空并恢复代理模式
 *  - 展开面板底部提供获取 Key 的引导提示及配额占位文案
 */
@ComponentV2
struct OpenSubtitlesConfigBuilderComponent {
  /** 当前持久化的 API Key（空串 = 代理模式） */
  @Local apiKey: string = ''
  /** 是否已完成初始加载 */
  @Local isKeyLoaded: boolean = false
  /** 展开/收起状态 */
  @Local isExpanded: boolean = false
  /** 输入框当前编辑值（展开时与 apiKey 同步，用户可独立编辑） */
  @Local editingKey: string = ''

  aboutToAppear(): void {
    this.loadApiKey()
  }

  private async loadApiKey(): Promise<void> {
    try {
      const key = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '')
      this.apiKey = key
      this.editingKey = key
      this.isKeyLoaded = true
    } catch {
      this.apiKey = ''
      this.editingKey = ''
      this.isKeyLoaded = true
    }
  }

  /** 当前模式文案：加载中 / 官方代理 · 推荐 / 自定义 Key · 直连 */
  private getStatusText(): string {
    if (!this.isKeyLoaded) {
      return '正在加载…'
    }
    return this.apiKey.length > 0 ? '自定义 Key · 直连' : 'SubHub · 推荐'
  }

  /** 脱敏显示：****+后4位；Key 长度 ≤ 4 时全部遮掩 */
  private getMaskedKey(): string {
    if (this.apiKey.length === 0) {
      return ''
    }
    if (this.apiKey.length <= 4) {
      return '****'
    }
    return `****${this.apiKey.substring(this.apiKey.length - 4)}`
  }

  /** 状态文案颜色：直连模式用绿色高亮，代理/加载用灰色 */
  private getStatusColor(): string {
    return (this.isKeyLoaded && this.apiKey.length > 0) ? '#4CAF50' : '#A0A0A0'
  }

  /** 展开/收起切换；收起时回滚编辑值避免未保存数据残留 */
  private toggleExpand(): void {
    this.isExpanded = !this.isExpanded
    if (!this.isExpanded) {
      this.editingKey = this.apiKey
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 1500 })
    } catch {
      console.warn(`[OpenSubtitlesConfig] toast failed: ${message}`)
    }
  }

  /** 保存当前编辑值到持久化存储 */
  private async saveKey(): Promise<void> {
    try {
      await AppPreferences.set(PrefKey.OPENSUBTITLES_API_KEY, this.editingKey)
      this.apiKey = this.editingKey
      this.isExpanded = false
      this.showToast(
        this.editingKey.length > 0 ? 'API Key 已保存，已切换为直连模式' : 'API Key 已清除，已切换为 SubHub'
      )
    } catch {
      this.showToast('保存失败，请重试')
    }
  }

  /** 清除 API Key，恢复官方代理模式 */
  private async clearKey(): Promise<void> {
    this.editingKey = ''
    try {
      await AppPreferences.set(PrefKey.OPENSUBTITLES_API_KEY, '')
      this.apiKey = ''
      this.isExpanded = false
      this.showToast('API Key 已清除，已切换为 SubHub')
    } catch {
      this.showToast('清除失败，请重试')
    }
  }

  build() {
    SettingListItemGroup({
      title: 'OpenSubtitles 字幕服务'
    }) {
      // ── 主行：状态展示 + 展开/收起（整行可聚焦，确认键触发） ──
      ListItem() {
        Column({ space: 0 }) {
          // 状态头行
          Row() {
            Column({ space: 4 }) {
              Text('API Key 配置')
                .fontSize($r('app.float.font_subtitle_1'))
                .fontColor('#F5F5F5')
              Text(this.getStatusText())
                .fontSize(13)
                .fontColor(this.getStatusColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(this.isExpanded ? '收起' : '配置 ›')
              .fontSize(13)
              .fontColor('#A0A0A0')
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // ── 展开面板 ──
          if (this.isExpanded) {
            Column({ space: 12 }) {
              // Task 5.2：API Key 输入框（Password 类型脱敏；遥控器确认可调起系统键盘）
              TextInput({
                placeholder: this.getMaskedKey().length > 0 ? this.getMaskedKey() : '输入您的 API Key',
                text: this.editingKey
              })
                .type(InputType.Password)
                .fontSize(14)
                .fontColor('#F5F5F5')
                .placeholderColor('#6F6F6F')
                .backgroundColor('#2A2A2A')
                .borderRadius(6)
                .height(44)
                .width('100%')
                .focusable(true)
                .onChange((value: string) => {
                  this.editingKey = value
                })

              // 操作按钮行：保存（始终可用）+ 清除（仅有已存 Key 时显示）
              Row({ space: 12 }) {
                Button('保存')
                  .fontSize(14)
                  .fontColor('#F5F5F5')
                  .backgroundColor('#3D6B4F')
                  .borderRadius(8)
                  .height(36)
                  .layoutWeight(1)
                  .focusable(true)
                  .onClick(() => {
                    this.saveKey()
                  })

                if (this.apiKey.length > 0) {
                  Button('清除')
                    .fontSize(14)
                    .fontColor('#F5F5F5')
                    .backgroundColor('#6B3D3D')
                    .borderRadius(8)
                    .height(36)
                    .layoutWeight(1)
                    .focusable(true)
                    .onClick(() => {
                      this.clearKey()
                    })
                }
              }
              .width('100%')

              // Task 5.3：如何获取 API Key 提示
              Text('在 opensubtitles.com 注册账号后，前往 个人设置 → API 生成您的 API Key')
                .fontSize(12)
                .fontColor('#7A7A7A')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              // Task 5.4：代理模式配额占位（网络请求实现复杂，保留占位文案）
              Text('今日配额状态：不可用')
                .fontSize(12)
                .fontColor('#6F6F6F')
            }
            .width('100%')
            .padding({ top: 12 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(HorizontalAlign.Start)
        .backgroundColor('#333333')
        .borderRadius(8)
      }
      .focusable(true)
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.toggleExpand()
      })
    }
  }
}

@Builder
export function OpenSubtitlesConfigBuilder() {
  OpenSubtitlesConfigBuilderComponent()
}
