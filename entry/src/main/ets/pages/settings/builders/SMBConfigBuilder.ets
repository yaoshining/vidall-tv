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
  @Local shareName: string = ''
  @Local username: string = ''
  @Local password: string = ''
  @Local domain: string = ''
  @Local port: number = 445

  // Loading 状态
  @Local isLoading: boolean = false
  @Local loadingText: string = ''

  // 焦点状态管理
  @Local currentFocusIndex: number = 0

  // 编辑模式
  private isEditMode: boolean = false
  private editingFileSourceId: number | undefined = undefined

  /**
   * 跳转到下一个输入框
   */
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

  /**
   * 加载已有配置（编辑模式）
   */
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
        this.shareName = config.shareName
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

  /**
   * 构造 SMBSourceConfig
   */
  private buildConfig(): SMBSourceConfig {
    const config: SMBSourceConfig = {
      host: this.host.trim(),
      shareName: this.shareName.trim(),
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

  /**
   * 测试连接：调用 SMBClient 真实 NAPI 桩函数
   */
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
    const shareResult = ValidationUtil.validateNotEmpty(this.shareName, '共享名')
    if (!shareResult.valid) {
      promptAction.showToast({ message: shareResult.message, duration: 2000 })
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
    } catch (e) {
      promptAction.showToast({ message: '连接测试异常', duration: 2000 })
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  /**
   * 保存配置
   */
  private async handleSave(): Promise<void> {
    // 必填字段校验
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
    const shareResult = ValidationUtil.validateNotEmpty(this.shareName, '共享名')
    if (!shareResult.valid) {
      promptAction.showToast({ message: shareResult.message, duration: 2000 })
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

    // 编辑模式下保留原 createdAt，避免每次编辑都重写创建时间戳
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
          .id('smbServerNameInput')
          .key(`smbServerName_${this.currentFocusIndex === 0 ? 'focus' : 'blur'}`)
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
          .id('smbHostInput')
          .key(`smbHost_${this.currentFocusIndex === 1 ? 'focus' : 'blur'}`)
          .defaultFocus(this.currentFocusIndex === 1)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.host = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 共享名（必填）
        TextInput({ text: this.shareName, placeholder: '共享名（如 nas-share）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .id('smbShareNameInput')
          .key(`smbShareName_${this.currentFocusIndex === 2 ? 'focus' : 'blur'}`)
          .defaultFocus(this.currentFocusIndex === 2)
          .enterKeyType(EnterKeyType.Next)
          .onChange((value: string) => {
            this.shareName = value
          })
          .onSubmit(() => {
            this.focusNext()
          })

        // 用户名（必填）
        TextInput({ text: this.username, placeholder: '用户名（必填）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .id('smbUsernameInput')
          .key(`smbUsername_${this.currentFocusIndex === 3 ? 'focus' : 'blur'}`)
          .defaultFocus(this.currentFocusIndex === 3)
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
          .id('smbPasswordInput')
          .key(`smbPassword_${this.currentFocusIndex === 4 ? 'focus' : 'blur'}`)
          .defaultFocus(this.currentFocusIndex === 4)
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
          .id('smbDomainInput')
          .key(`smbDomain_${this.currentFocusIndex === 5 ? 'focus' : 'blur'}`)
          .defaultFocus(this.currentFocusIndex === 5)
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
          .id('smbPortInput')
          .key(`smbPort_${this.currentFocusIndex === 6 ? 'focus' : 'blur'}`)
          .defaultFocus(this.currentFocusIndex === 6)
          .enterKeyType(EnterKeyType.Done)
          .onChange((value: string) => {
            const portNum = parseInt(value)
            if (!isNaN(portNum)) {
              this.port = portNum
            }
          })
          .onSubmit(() => {
            // 最后一个字段，无需跳转
          })

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
