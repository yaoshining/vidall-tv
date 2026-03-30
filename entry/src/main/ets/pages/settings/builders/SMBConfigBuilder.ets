import { SettingContainer } from "../SettingContainer"
import { SettingsController } from "../SettingsController"
import { IBestButton } from "@ibestservices/ibest-ui"
import { FileSourceStore } from "../../../stores/files/FileSourceStore"
import { FileSource, FileSourceType, SMBSourceConfig } from "../../../db/models/FileSourceEntity"
import { ValidationUtil } from "../../../utils/ValidationUtil"
import promptAction from '@ohos.promptAction'
import { SMBClient } from '../../../lib/SMBClient'

@ComponentV2
struct SMBConfigBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  // 表单状态
  @Local serverName: string = ''
  @Local host: string = ''
  @Local username: string = ''
  @Local password: string = ''
  @Local domain: string = ''
  @Local port: number = 445

  // Loading 状态
  @Local isLoading: boolean = false
  @Local loadingText: string = ''

  // 局域网设备发现
  @Local isDiscovering: boolean = false
  @Local discoveredHosts: string[] = []
  @Local focusedHost: string = ''

  // 焦点状态管理
  @Local currentFocusIndex: number = 0

  // 编辑模式
  private isEditMode: boolean = false
  private editingFileSourceId: number | undefined = undefined

  private focusNext(): void {
    this.currentFocusIndex++
  }

  aboutToAppear(): void {
    if (this.controller.params && this.controller.params['fileSourceId']) {
      this.isEditMode = true
      this.editingFileSourceId = this.controller.params['fileSourceId'] as number
      this.loadEditData()
    }
  }

  private async loadEditData(): Promise<void> {
    if (!this.editingFileSourceId) {
      return
    }
    this.isLoading = true
    this.loadingText = '加载中...'
    try {
      const store = FileSourceStore.getState()
      await store.loadFileSources()
      const fileSource = store.getFileSourceById(this.editingFileSourceId)
      if (fileSource) {
        const config = JSON.parse(fileSource.configJson) as SMBSourceConfig
        this.serverName = fileSource.name
        this.host = config.host
        this.username = config.username
        this.password = config.password
        this.domain = config.domain ?? ''
        this.port = config.port ?? 445
      } else {
        promptAction.showToast({ message: '文件源不存在', duration: 2000 })
        this.controller.popType()
      }
    } catch {
      promptAction.showToast({ message: '加载数据失败', duration: 2000 })
      this.controller.popType()
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  private buildConfig(): SMBSourceConfig {
    const config: SMBSourceConfig = {
      host: this.host.trim(),
      username: this.username,
      password: this.password,
      port: this.port
    }
    const trimmedDomain = this.domain.trim()
    if (trimmedDomain.length > 0) {
      config.domain = trimmedDomain
    }
    return config
  }

  private async handleTestConnection(): Promise<void> {
    const nameResult = ValidationUtil.validateNotEmpty(this.serverName, '名称')
    if (!nameResult.valid) {
      promptAction.showToast({ message: nameResult.message, duration: 2000 })
      return
    }
    const hostResult = ValidationUtil.validateNotEmpty(this.host, '服务器地址')
    if (!hostResult.valid) {
      promptAction.showToast({ message: hostResult.message, duration: 2000 })
      return
    }

    this.isLoading = true
    this.loadingText = '连接测试中...'

    try {
      const config = this.buildConfig()
      const client = SMBClient.fromSourceConfig(config)
      const result = await client.testConnection()
      if (result.success) {
        promptAction.showToast({ message: '连接成功', duration: 2000 })
      } else {
        promptAction.showToast({
          message: result.error ?? '连接失败',
          duration: 3000
        })
      }
    } catch {
      promptAction.showToast({ message: '连接测试异常', duration: 2000 })
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  /**
   * 发现局域网内开放 SMB(445) 端口的设备。
   * 从当前 host 提取子网前缀（若已填写），否则默认扫描 192.168.1.x。
   */
  private getSubnetPrefix(): string {
    const h = this.host.trim()
    if (h.length > 0) {
      const parts = h.split('.')
      if (parts.length === 4) {
        return parts[0] + '.' + parts[1] + '.' + parts[2] + '.'
      }
    }
    return '192.168.1.'
  }

  private async handleDiscoverHosts(): Promise<void> {
    this.isDiscovering = true
    this.discoveredHosts = []
    try {
      const prefix = this.getSubnetPrefix()
      promptAction.showToast({ message: `扫描 ${prefix}1-254:445...`, duration: 1500 })
      const result = await SMBClient.discoverHosts(prefix, 1, 254, 445, 5000)
      if (result.error) {
        promptAction.showToast({ message: `发现失败: ${result.error}`, duration: 3000 })
      } else if (result.hosts.length === 0) {
        promptAction.showToast({ message: '未发现局域网 SMB 设备', duration: 2000 })
      } else {
        this.discoveredHosts = result.hosts
      }
    } catch {
      promptAction.showToast({ message: '发现失败', duration: 2000 })
    } finally {
      this.isDiscovering = false
    }
  }

  private getDiscoverButtonText(): string {
    return this.isDiscovering ? '扫描中...' : '发现局域网设备'
  }

  private async handleSave(): Promise<void> {
    const nameResult = ValidationUtil.validateNotEmpty(this.serverName, '名称')
    if (!nameResult.valid) {
      promptAction.showToast({ message: nameResult.message, duration: 2000 })
      return
    }
    const hostResult = ValidationUtil.validateNotEmpty(this.host, '服务器地址')
    if (!hostResult.valid) {
      promptAction.showToast({ message: hostResult.message, duration: 2000 })
      return
    }
    const usernameResult = ValidationUtil.validateNotEmpty(this.username, '用户名')
    if (!usernameResult.valid) {
      promptAction.showToast({ message: usernameResult.message, duration: 2000 })
      return
    }
    const passwordResult = ValidationUtil.validateNotEmpty(this.password, '密码')
    if (!passwordResult.valid) {
      promptAction.showToast({ message: passwordResult.message, duration: 2000 })
      return
    }
    const portResult = ValidationUtil.validatePort(this.port)
    if (!portResult.valid) {
      promptAction.showToast({ message: portResult.message, duration: 2000 })
      return
    }

    this.isLoading = true
    this.loadingText = '保存中...'

    let originalCreatedAt: number = Date.now();
    if (this.isEditMode && this.editingFileSourceId !== undefined) {
      const existing = FileSourceStore.getState().getFileSourceById(this.editingFileSourceId);
      if (existing) {
        originalCreatedAt = existing.createdAt;
      }
    }

    try {
      const config = this.buildConfig()
      const fileSource: FileSource = {
        name: this.serverName,
        type: FileSourceType.SMB,
        configJson: JSON.stringify(config),
        createdAt: originalCreatedAt
      }
      const store = FileSourceStore.getState()
      if (this.isEditMode && this.editingFileSourceId !== undefined) {
        fileSource.id = this.editingFileSourceId
        await store.updateFileSource(fileSource)
      } else {
        await store.addFileSource(fileSource)
      }
      promptAction.showToast({ message: '保存成功', duration: 1500 })
      this.controller.popType()
    } catch {
      AlertDialog.show({
        title: '保存失败',
        message: '发生未知错误，请重试',
        primaryButton: {
          value: '确定',
          action: () => {}
        }
      })
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  build() {
    SettingContainer({
      title: this.isEditMode ? '编辑 SMB 源' : '添加 SMB 源'
    }) {
      Column({ space: 20 }) {
        // 名称（必填）
        TextInput({ text: this.serverName, placeholder: '名称（必填）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .defaultFocus(this.currentFocusIndex === 0)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.serverName = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 服务器地址（必填）
        TextInput({ text: this.host, placeholder: '服务器地址（如 192.168.3.10）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .defaultFocus(this.currentFocusIndex === 1)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.host = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 发现局域网设备按钮
        IBestButton({
          text: this.getDiscoverButtonText(),
          type: 'default',
          btnWidth: '100%',
          plain: true,
          btnFontSize: 18,
          loading: this.isDiscovering,
          onBtnClick: () => {
            this.handleDiscoverHosts()
          }
        })
          .width('100%')
          .enabled(!this.isLoading && !this.isDiscovering)

        // 发现的设备列表（点击填入服务器地址）
        if (this.discoveredHosts.length > 0) {
          Column({ space: 8 }) {
            Text('发现的设备（点击选择）')
              .fontSize(14)
              .fontColor(Color.Gray)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.discoveredHosts, (ip: string) => {
                Text(ip)
                  .fontSize(16)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .margin({ right: 8, bottom: 8 })
                  .borderRadius(4)
                  .backgroundColor(
                    this.host === ip ? '#1677FF'
                      : this.focusedHost === ip ? '#D0E8FF'
                      : '#F0F0F0'
                  )
                  .fontColor(this.host === ip ? Color.White : Color.Black)
                  .focusable(true)
                  .onFocus(() => { this.focusedHost = ip })
                  .onBlur(() => { this.focusedHost = '' })
                  .onClick(() => {
                    this.host = ip
                  })
              }, (ip: string) => ip)
            }
            .width('100%')
          }
          .width('100%')
        }

        // 用户名（必填）
        TextInput({ text: this.username, placeholder: '用户名（必填）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .defaultFocus(this.currentFocusIndex === 2)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.username = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 密码（必填）
        TextInput({ text: this.password, placeholder: '密码（必填）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .type(InputType.Password)
          .enabled(!this.isLoading)
          .defaultFocus(this.currentFocusIndex === 3)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.password = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 域（可选）
        TextInput({ text: this.domain, placeholder: '域（可选，如 WORKGROUP）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .defaultFocus(this.currentFocusIndex === 4)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.domain = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 端口（可选，默认 445）
        TextInput({ text: this.port.toString(), placeholder: '端口（默认 445）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .type(InputType.Number)
          .enabled(!this.isLoading)
          .defaultFocus(this.currentFocusIndex === 5)
          .enterKeyType(EnterKeyType.Done)
          .onChange((value: string) => {
            const portNum = parseInt(value)
            if (!isNaN(portNum)) {
              this.port = portNum
            }
          })
          .onSubmit(() => {})

        // 操作按钮
        Row({ space: 16 }) {
          IBestButton({
            text: '测试连接',
            loadingText: this.loadingText,
            type: 'default',
            btnWidth: '100%',
            plain: true,
            btnFontSize: 20,
            loading: this.isLoading && this.loadingText === '连接测试中...',
            onBtnClick: () => {
              this.handleTestConnection()
            }
          })
            .layoutWeight(1)
            .enabled(!this.isLoading)

          IBestButton({
            text: '保存',
            loadingText: this.loadingText,
            type: 'primary',
            color: Color.White,
            fontColor: Color.Black,
            btnWidth: '100%',
            btnFontSize: 20,
            loading: this.isLoading && this.loadingText === '保存中...',
            onBtnClick: () => {
              this.handleSave()
            }
          })
            .layoutWeight(1)
            .enabled(!this.isLoading)
        }
        .width('100%')
        .padding(16)
      }
    }
  }
}

@Builder
export function SMBConfigBuilder() {
  SMBConfigBuilderComponent()
}
