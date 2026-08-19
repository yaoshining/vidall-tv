import { SettingContainer } from "../SettingContainer"
import { SettingsController } from "../SettingsController"
import { IBestButton } from "@ibestservices/ibest-ui"
import { VideoServerStore } from "../../../stores/servers/VideoServerStore"
import { VideoServerModel } from "../../../stores/servers/VideoServerModel"
import { SourceSwitchModel } from "../../../stores/media/SourceSwitchModel"
import {
  VideoServer, VideoServerType,
  JellyfinServerConfig, PlexServerConfig
} from "../../../db/models/VideoServerEntity"
import { JellyfinClient, ConnectionTestResult } from "../../../lib/JellyfinClient"
import { PlexClient } from "../../../lib/PlexClient"
import { ValidationUtil } from "../../../utils/ValidationUtil"

type ServerTypeParam = 'jellyfin' | 'emby' | 'plex'

@ComponentV2
struct VideoServerConfigBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  // 表单状态
  @Local serverName: string = ''
  @Local serverUrl: string = ''
  @Local protocol: 'http' | 'https' = 'http'
  @Local port: number = 8096
  @Local basePath: string = ''
  @Local authMethod: 'apikey' | 'password' = 'apikey'
  @Local apiKey: string = ''
  @Local username: string = ''
  @Local password: string = ''
  @Local token: string = ''

  // Loading 状态
  @Local isLoading: boolean = false
  @Local loadingText: string = ''

  private serverType: ServerTypeParam = 'jellyfin'
  private isEditMode: boolean = false
  private editingServerId: number | undefined = undefined

  private showToastSafe(message: string, duration: number = 2000): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration })
    } catch (_e) {}
  }

  private isPlex(): boolean {
    return this.serverType === 'plex'
  }

  private defaultPort(): number {
    return this.isPlex() ? 32400 : 8096
  }

  /** 从配置 JSON 读取端口：兼容 number（现格式）与 string（历史数据），无效时回退默认端口 */
  private parsePort(raw: Object): number {
    if (typeof raw === 'number' && !isNaN(raw) && raw > 0) {
      return raw
    }
    if (typeof raw === 'string' && raw.trim().length > 0) {
      const parsed = parseInt(raw.trim(), 10)
      if (!isNaN(parsed) && parsed > 0) {
        return parsed
      }
    }
    return this.defaultPort()
  }

  private typeTitle(): string {
    switch (this.serverType) {
      case 'jellyfin': return 'Jellyfin'
      case 'emby': return 'Emby'
      case 'plex': return 'Plex'
      default: return '服务器'
    }
  }

  private videoServerType(): VideoServerType {
    switch (this.serverType) {
      case 'jellyfin': return VideoServerType.JELLYFIN
      case 'emby': return VideoServerType.EMBY
      case 'plex': return VideoServerType.PLEX
      default: return VideoServerType.JELLYFIN
    }
  }

  aboutToAppear(): void {
    const params = this.controller.params
    if (params && params['serverType']) {
      this.serverType = params['serverType'] as ServerTypeParam
      this.port = this.defaultPort()
    }
    if (params && params['serverId']) {
      this.isEditMode = true
      this.editingServerId = params['serverId'] as number
      this.loadEditData()
    }
  }

  private async loadEditData(): Promise<void> {
    if (!this.editingServerId) {
      return
    }
    this.isLoading = true
    this.loadingText = '加载中...'
    try {
      const store: VideoServerModel = VideoServerStore.getState()
      await store.loadVideoServers()
      const server = store.getVideoServerById(this.editingServerId)
      if (server) {
        this.serverName = server.name
        if (server.type === VideoServerType.PLEX) {
          this.serverType = 'plex'
        } else if (server.type === VideoServerType.EMBY) {
          this.serverType = 'emby'
        } else {
          this.serverType = 'jellyfin'
        }
        const config = JSON.parse(server.configJson) as Record<string, Object>
        this.serverUrl = typeof config['url'] === 'string' ? config['url'] : ''
        this.protocol = config['protocol'] === 'https' ? 'https' : 'http'
        this.port = this.parsePort(config['port'])
        this.basePath = typeof config['basePath'] === 'string' ? config['basePath'] : ''
        this.authMethod = config['authMethod'] === 'password' ? 'password' : 'apikey'
        this.apiKey = typeof config['apiKey'] === 'string' ? config['apiKey'] : ''
        this.username = typeof config['username'] === 'string' ? config['username'] : ''
        this.password = typeof config['password'] === 'string' ? config['password'] : ''
        this.token = typeof config['token'] === 'string' ? config['token'] : ''
      } else {
        this.showToastSafe('服务器不存在')
        this.controller.popType()
      }
    } catch {
      this.showToastSafe('加载数据失败')
      this.controller.popType()
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  private validateCommon(): boolean {
    const nameResult = ValidationUtil.validateNotEmpty(this.serverName, '名称')
    if (!nameResult.valid) {
      this.showToastSafe(nameResult.message)
      return false
    }
    const urlResult = ValidationUtil.validateUrl(this.serverUrl)
    if (!urlResult.valid) {
      this.showToastSafe(urlResult.message)
      return false
    }
    const portResult = ValidationUtil.validatePort(this.port)
    if (!portResult.valid) {
      this.showToastSafe(portResult.message)
      return false
    }
    return true
  }

  private buildConfigJson(): string {
    if (this.isPlex()) {
      const config: PlexServerConfig = {
        url: this.serverUrl.trim(),
        port: this.port,
        protocol: this.protocol,
        token: this.token
      }
      return JSON.stringify(config)
    }
    const config: JellyfinServerConfig = {
      url: this.serverUrl.trim(),
      port: this.port,
      protocol: this.protocol,
      authMethod: this.authMethod,
      apiKey: this.apiKey.trim(),
      username: this.username,
      password: this.password
    }
    const trimmedBase = this.basePath.trim()
    if (trimmedBase.length > 0) {
      config.basePath = trimmedBase
    }
    return JSON.stringify(config)
  }

  private async testConnectionInternal(): Promise<ConnectionTestResult> {
    if (this.isPlex()) {
      const client = PlexClient.fromConfigJson(this.buildConfigJson())
      return client.testConnection()
    }
    const client = JellyfinClient.fromConfigJson(this.buildConfigJson())
    return client.testConnection()
  }

  private async handleTestConnection(): Promise<void> {
    if (!this.validateCommon()) {
      return
    }
    if (this.isPlex()) {
      const tokenResult = ValidationUtil.validateNotEmpty(this.token, 'X-Plex-Token')
      if (!tokenResult.valid) {
        this.showToastSafe(tokenResult.message)
        return
      }
    } else if (this.authMethod === 'apikey') {
      const keyResult = ValidationUtil.validateNotEmpty(this.apiKey, 'API Key')
      if (!keyResult.valid) {
        this.showToastSafe(keyResult.message)
        return
      }
    } else {
      const uResult = ValidationUtil.validateNotEmpty(this.username, '用户名')
      if (!uResult.valid) {
        this.showToastSafe(uResult.message)
        return
      }
      const pResult = ValidationUtil.validateNotEmpty(this.password, '密码')
      if (!pResult.valid) {
        this.showToastSafe(pResult.message)
        return
      }
    }

    this.isLoading = true
    this.loadingText = '连接测试中...'
    try {
      const result = await this.testConnectionInternal()
      if (result.success) {
        this.showToastSafe('连接成功')
      } else {
        this.showToastSafe(result.message, 3000)
      }
    } catch (e) {
      const message = (e as Error).message ?? '未知错误'
      this.showToastSafe(message, 3000)
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  private async handleSave(): Promise<void> {
    if (!this.validateCommon()) {
      return
    }
    if (this.isPlex()) {
      const tokenResult = ValidationUtil.validateNotEmpty(this.token, 'X-Plex-Token')
      if (!tokenResult.valid) {
        this.showToastSafe(tokenResult.message)
        return
      }
    } else if (this.authMethod === 'apikey') {
      const keyResult = ValidationUtil.validateNotEmpty(this.apiKey, 'API Key')
      if (!keyResult.valid) {
        this.showToastSafe(keyResult.message)
        return
      }
    } else {
      const uResult = ValidationUtil.validateNotEmpty(this.username, '用户名')
      if (!uResult.valid) {
        this.showToastSafe(uResult.message)
        return
      }
      const pResult = ValidationUtil.validateNotEmpty(this.password, '密码')
      if (!pResult.valid) {
        this.showToastSafe(pResult.message)
        return
      }
    }

    this.isLoading = true
    this.loadingText = '保存中...'

    let originalCreatedAt: number = Date.now()
    if (this.isEditMode && this.editingServerId !== undefined) {
      const existing = VideoServerStore.getState().getVideoServerById(this.editingServerId)
      if (existing) {
        originalCreatedAt = existing.createdAt
      }
    }

    try {
      const server: VideoServer = {
        name: this.serverName.trim(),
        type: this.videoServerType(),
        configJson: this.buildConfigJson(),
        createdAt: originalCreatedAt
      }
      const store: VideoServerModel = VideoServerStore.getState()
      if (this.isEditMode && this.editingServerId !== undefined) {
        server.id = this.editingServerId
        await store.updateVideoServer(server)
      } else {
        await store.addVideoServer(server)
      }
      // 服务器改名后同步当前源名称（Home 按钮 / 切换弹窗实时刷新）
      SourceSwitchModel.getState().syncServerName(server)
      this.showToastSafe('保存成功', 1500)
      this.controller.popType()
    } catch {
      this.getUIContext().showAlertDialog({
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

  @Builder
  protocolSelect() {
    Select([
      { value: 'HTTP' },
      { value: 'HTTPS' }
    ])
      .selected(this.protocol === 'https' ? 1 : 0)
      .value(this.protocol.toUpperCase())
      .font({ size: 16 })
      .selectedOptionFont({ size: 16 })
      .optionFont({ size: 16 })
      .height(40)
      .width("100%")
      .enabled(!this.isLoading)
      .onSelect((index: number) => {
        this.protocol = index === 1 ? 'https' : 'http'
      })
  }

  @Builder
  authMethodSelect() {
    Select([
      { value: 'API Key' },
      { value: '用户名/密码' }
    ])
      .selected(this.authMethod === 'password' ? 1 : 0)
      .value(this.authMethod === 'password' ? '用户名/密码' : 'API Key')
      .font({ size: 16 })
      .selectedOptionFont({ size: 16 })
      .optionFont({ size: 16 })
      .height(40)
      .width("100%")
      .enabled(!this.isLoading)
      .onSelect((index: number) => {
        this.authMethod = index === 1 ? 'password' : 'apikey'
      })
  }

  build() {
    SettingContainer({
      title: this.isEditMode ? `编辑 ${this.typeTitle()}` : `添加 ${this.typeTitle()}`
    }) {
      Column({ space: 20 }) {
        TextInput({ text: this.serverName, placeholder: '名称（必填）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .onChange((value: string) => {
            this.serverName = value
          })

        this.protocolSelect()

        TextInput({ text: this.serverUrl, placeholder: '服务器地址（如 192.168.1.100）' })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .enabled(!this.isLoading)
          .onChange((value: string) => {
            this.serverUrl = value
          })

        TextInput({ text: this.port.toString(), placeholder: `端口（默认 ${this.defaultPort()}）` })
          .height(40)
          .fontSize(16)
          .placeholderFont({ size: 16 })
          .type(InputType.Number)
          .enabled(!this.isLoading)
          .onChange((value: string) => {
            const trimmed = value.trim()
            if (trimmed.length === 0) {
              this.port = this.defaultPort()
              return
            }
            const portNum = parseInt(trimmed, 10)
            if (!isNaN(portNum)) {
              this.port = portNum
            }
          })

        if (this.isPlex()) {
          TextInput({ text: this.token, placeholder: 'X-Plex-Token（必填）' })
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .type(InputType.Password)
            .enabled(!this.isLoading)
            .onChange((value: string) => {
              this.token = value
            })
        } else {
          TextInput({ text: this.basePath, placeholder: '基础路径（可选，如 /jellyfin）' })
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .enabled(!this.isLoading)
            .onChange((value: string) => {
              this.basePath = value
            })

          this.authMethodSelect()

          if (this.authMethod === 'apikey') {
            TextInput({ text: this.apiKey, placeholder: 'API Key（必填）' })
              .height(40)
              .fontSize(16)
              .placeholderFont({ size: 16 })
              .type(InputType.Password)
              .enabled(!this.isLoading)
              .onChange((value: string) => {
                this.apiKey = value
              })
          } else {
            TextInput({ text: this.username, placeholder: '用户名（必填）' })
              .height(40)
              .fontSize(16)
              .placeholderFont({ size: 16 })
              .enabled(!this.isLoading)
              .onChange((value: string) => {
                this.username = value
              })
            TextInput({ text: this.password, placeholder: '密码（必填）' })
              .height(40)
              .fontSize(16)
              .placeholderFont({ size: 16 })
              .type(InputType.Password)
              .enabled(!this.isLoading)
              .onChange((value: string) => {
                this.password = value
              })
          }
        }

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
        .width("100%")
        .padding(16)
      }
    }
  }
}

@Builder
export function VideoServerConfigBuilder() {
  VideoServerConfigBuilderComponent()
}
