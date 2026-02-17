import { SettingContainer } from "../SettingContainer"
import { SettingListItem } from "../SettingListItem"
import { SettingListItemGroup } from "../SettingListItemGroup"
import { SettingsController } from "../SettingsController"
import { FileSourceStore } from "../../../lib/stores/FileSourceStore"
import { FileSource, FileSourceType, WebDAVSourceConfig } from "../../../lib/models/FileSourceModel"
import { DebounceUtil, CancellableFunction } from "../../../lib/utils/DebounceUtil"
import { ValidationUtil } from "../../../lib/utils/ValidationUtil"
import { WebDAVClient, WebDAVConfig } from "../../../lib/WebDAVClient"
import promptAction from '@ohos.promptAction'

@ComponentV2
struct WebDAVConfigBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  // 表单状态
  @Local serverName: string = 'mynas'
  @Local serverUrl: string = '192.168.3.59'
  @Local username: string = 'yao'
  @Local password: string = 'ys198756'
  @Local protocol: 'http' | 'https' = 'http'
  @Local port: number = 80
  @Local rootPath: string = '/dav'
  @Local urlError: string = ''

  // Loading 状态
  @Local isLoading: boolean = false
  @Local loadingText: string = ''

  // 焦点状态管理
  @Local currentFocusIndex: number = 0

  // 防抖验证函数
  private debouncedValidateUrl: CancellableFunction =
    DebounceUtil.debounce((url: string) => {
      const result = ValidationUtil.validateUrl(url);
      this.urlError = result.valid ? '' : result.message;
    }, 300)

  // 是否为编辑模式
  private isEditMode: boolean = false
  private editingFileSourceId: number | undefined = undefined

  /**
   * 跳转到下一个输入框
   */
  private focusNext(): void {
    this.currentFocusIndex++
  }

  aboutToAppear(): void {
    // 创建防抖验证函数已在成员变量初始化时完成

    // 检查是否为编辑模式
    if (this.controller.params && this.controller.params['fileSourceId']) {
      this.isEditMode = true
      this.editingFileSourceId = this.controller.params['fileSourceId'] as number
      this.loadEditData()
    }
  }

  aboutToDisappear(): void {
    // 取消防抖任务
    this.debouncedValidateUrl.cancel()
  }

  /**
   * 加载编辑数据
   */
  private async loadEditData(): Promise<void> {
    if (!this.editingFileSourceId) {
      return
    }

    this.isLoading = true
    this.loadingText = '加载中...'

    try {
      const store = FileSourceStore.getInstance()
      const fileSource = store.getFileSourceById(this.editingFileSourceId)

      if (fileSource) {
        const config = JSON.parse(fileSource.configJson) as WebDAVSourceConfig
        this.serverName = fileSource.name
        this.serverUrl = config.url
        this.username = config.username
        this.password = config.password
        this.protocol = config.protocol
        this.port = config.port
        this.rootPath = config.rootPath
      }
    } catch (error) {
      console.error('Failed to load edit data:', JSON.stringify(error))
      promptAction.showToast({ message: '加载数据失败' })
    } finally {
      this.isLoading = false
      this.loadingText = ''
    }
  }

  /**
   * 处理协议选择
   */
  private handleProtocolSelect(): void {
    AlertDialog.show({
      title: '选择协议',
      message: '',
      primaryButton: {
        value: 'HTTP',
        action: () => {
          this.protocol = 'http'
          if (this.port === 443) {
            this.port = 80
          }
        }
      },
      secondaryButton: {
        value: 'HTTPS',
        action: () => {
          this.protocol = 'https'
          if (this.port === 80) {
            this.port = 443
          }
        }
      }
    })
  }

  /**
   * 测试连接
   */
  private async handleTestConnection(): Promise<void> {
    // 验证必填字段
    const nameResult = ValidationUtil.validateNotEmpty(this.serverName, '服务器名称')
    if (!nameResult.valid) {
      promptAction.showToast({ message: nameResult.message })
      return
    }

    const urlResult = ValidationUtil.validateNotEmpty(this.serverUrl, '服务器地址')
    if (!urlResult.valid) {
      promptAction.showToast({ message: urlResult.message })
      return
    }

    // 检查 URL 格式错误
    if (this.urlError) {
      promptAction.showToast({ message: '请先修正 URL 格式错误' })
      return
    }

    const usernameResult = ValidationUtil.validateNotEmpty(this.username, '用户名')
    if (!usernameResult.valid) {
      promptAction.showToast({ message: usernameResult.message })
      return
    }

    const passwordResult = ValidationUtil.validateNotEmpty(this.password, '密码')
    if (!passwordResult.valid) {
      promptAction.showToast({ message: passwordResult.message })
      return
    }

    this.isLoading = true
    this.loadingText = '测试连接中...'

    try {
      // 构造 WebDAV 配置
      // 组合协议、服务器地址、端口和路径为完整 URL

      let serverAddress = this.serverUrl
      let port = this.port

      // 如果服务器地址中已经包含端口（如 192.168.1.100:5445），提取它们
      if (serverAddress.includes(':')) {
        const parts = serverAddress.split(':')
        serverAddress = parts[0]
        const portInUrl = parseInt(parts[1])
        if (!isNaN(portInUrl)) {
          port = portInUrl  // 使用 URL 中的端口
        }
      }

      // 构造基础 URL（协议://服务器:端口）
      let baseUrl = `${this.protocol}://${serverAddress}:${port}`

      // 处理路径：如果为空或只有空格，使用默认值 /
      let path = this.rootPath.trim()
      if (!path) {
        path = '/'
      }

      // 如果有路径且不是根路径，添加路径
      if (path !== '/') {
        // 确保路径以 / 开头
        const formattedPath = path.startsWith('/') ? path : '/' + path
        baseUrl = baseUrl + formattedPath
      }

      const config: WebDAVConfig = {
        baseUrl: baseUrl,
        username: this.username,
        password: this.password,
        timeout: 10000
      }

      console.info('Testing connection with baseUrl:', baseUrl)
      console.info('Server:', serverAddress, 'Port:', port, 'Path:', path)

      const client = new WebDAVClient(config)
      const result = await client.testConnection()

      if (result.success) {
        promptAction.showToast({ message: '连接成功' })
      } else {
        AlertDialog.show({
          title: '连接失败',
          message: result.message,
          primaryButton: {
            value: '确定',
            action: () => {}
          }
        })
      }
    } catch (error) {
      AlertDialog.show({
        title: '连接失败',
        message: '发生未知错误：' + JSON.stringify(error),
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

  /**
   * 保存配置
   */
  private async handleSave(): Promise<void> {
    // 验证必填字段
    const nameResult = ValidationUtil.validateNotEmpty(this.serverName, '服务器名称')
    if (!nameResult.valid) {
      promptAction.showToast({ message: nameResult.message })
      return
    }

    const urlResult = ValidationUtil.validateNotEmpty(this.serverUrl, '服务器地址')
    if (!urlResult.valid) {
      promptAction.showToast({ message: urlResult.message })
      return
    }

    // 检查 URL 格式错误
    if (this.urlError) {
      promptAction.showToast({ message: '请先修正 URL 格式错误' })
      return
    }

    const usernameResult = ValidationUtil.validateNotEmpty(this.username, '用户名')
    if (!usernameResult.valid) {
      promptAction.showToast({ message: usernameResult.message })
      return
    }

    const passwordResult = ValidationUtil.validateNotEmpty(this.password, '密码')
    if (!passwordResult.valid) {
      promptAction.showToast({ message: passwordResult.message })
      return
    }

    // 验证端口
    const portResult = ValidationUtil.validatePort(this.port)
    if (!portResult.valid) {
      promptAction.showToast({ message: portResult.message })
      return
    }

    this.isLoading = true
    this.loadingText = '保存中...'

    try {
      // 处理路径：如果为空或只有空格，使用默认值 /
      let path = this.rootPath.trim()
      if (!path) {
        path = '/'
      }

      // 构造配置对象
      const webdavConfig: WebDAVSourceConfig = {
        url: this.serverUrl,
        username: this.username,
        password: this.password,
        protocol: this.protocol,
        port: this.port,
        rootPath: path
      }

      const fileSource: FileSource = {
        name: this.serverName,
        type: FileSourceType.WEBDAV,
        configJson: JSON.stringify(webdavConfig),
        createdAt: Date.now()
      }

      const store = FileSourceStore.getInstance()

      if (this.isEditMode && this.editingFileSourceId) {
        // 更新模式
        fileSource.id = this.editingFileSourceId
        await store.updateFileSource(fileSource)
      } else {
        // 新增模式
        await store.addFileSource(fileSource)
      }

      promptAction.showToast({ message: '保存成功' })
      this.controller.popType()
    } catch (error) {
      AlertDialog.show({
        title: '保存失败',
        message: '发生错误：' + JSON.stringify(error),
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
      title: this.isEditMode ? "编辑 WebDAV" : "添加 WebDAV"
    }) {
      SettingListItemGroup({
        title: ""
      }) {
        // 服务器名称
        Row() {
          Text("服务器名称")
            .fontSize(16)
            .width(100)
            .textAlign(TextAlign.End)
            .margin({ right: 12 })

          TextInput({ text: this.serverName, placeholder: "必填" })
            .layoutWeight(1)
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .enabled(!this.isLoading)
            .id('serverNameInput')
            .key(`serverName_${this.currentFocusIndex === 0 ? 'focus' : 'blur'}`)
            .defaultFocus(this.currentFocusIndex === 0)
            .enterKeyType(EnterKeyType.Next)
            .onChange((value: string) => {
              this.serverName = value
            })
            .onSubmit(() => {
              this.focusNext()
            })
        }
        .width("100%")
        .padding(16)
        .alignItems(VerticalAlign.Center)

        // 协议选择
        Row() {
          Text("协议")
            .fontSize(16)
            .width(100)
            .textAlign(TextAlign.End)
            .margin({ right: 12 })

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
            .layoutWeight(1)
            .enabled(!this.isLoading)
            .onSelect((index: number) => {
              if (index === 0) {
                this.protocol = 'http'
                if (this.port === 443) {
                  this.port = 80
                }
              } else {
                this.protocol = 'https'
                if (this.port === 80) {
                  this.port = 443
                }
              }
            })
        }
        .width("100%")
        .padding(16)
        .alignItems(VerticalAlign.Center)

        // 服务器地址
        Column() {
          Row() {
            Text("服务器地址")
              .fontSize(16)
              .width(100)
              .textAlign(TextAlign.End)
              .margin({ right: 12 })

            TextInput({ text: this.serverUrl, placeholder: "必填" })
              .layoutWeight(1)
              .height(40)
              .fontSize(16)
              .placeholderFont({ size: 16 })
              .enabled(!this.isLoading)
              .id('serverUrlInput')
              .key(`serverUrl_${this.currentFocusIndex === 1 ? 'focus' : 'blur'}`)
              .defaultFocus(this.currentFocusIndex === 1)
              .enterKeyType(EnterKeyType.Next)
              .onChange((value: string) => {
                this.serverUrl = value
                this.debouncedValidateUrl.call(value)
              })
              .onSubmit(() => {
                this.focusNext()
              })
          }
          .width("100%")
          .alignItems(VerticalAlign.Center)

          if (this.urlError) {
            Row() {
              Text("")
                .width(100)
                .margin({ right: 12 })
              Text(this.urlError)
                .fontSize(12)
                .fontColor(Color.Red)
                .layoutWeight(1)
                .margin({ top: 4 })
            }
            .width("100%")
          }
        }
        .width("100%")
        .padding(16)

        // 路径（可选）
        Row() {
          Text("路径")
            .fontSize(16)
            .width(100)
            .textAlign(TextAlign.End)
            .margin({ right: 12 })

          TextInput({ text: this.rootPath, placeholder: "选填" })
            .layoutWeight(1)
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .enabled(!this.isLoading)
            .id('rootPathInput')
            .key(`rootPath_${this.currentFocusIndex === 2 ? 'focus' : 'blur'}`)
            .defaultFocus(this.currentFocusIndex === 2)
            .enterKeyType(EnterKeyType.Next)
            .onChange((value: string) => {
              this.rootPath = value
            })
            .onSubmit(() => {
              this.focusNext()
            })
        }
        .width("100%")
        .padding(16)
        .alignItems(VerticalAlign.Center)

        // 端口
        Row() {
          Text("端口")
            .fontSize(16)
            .width(100)
            .textAlign(TextAlign.End)
            .margin({ right: 12 })

          TextInput({ text: this.port.toString(), placeholder: "必填" })
            .layoutWeight(1)
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .type(InputType.Number)
            .enabled(!this.isLoading)
            .id('portInput')
            .key(`port_${this.currentFocusIndex === 3 ? 'focus' : 'blur'}`)
            .defaultFocus(this.currentFocusIndex === 3)
            .enterKeyType(EnterKeyType.Next)
            .onChange((value: string) => {
              const portNum = parseInt(value)
              if (!isNaN(portNum)) {
                this.port = portNum
              }
            })
            .onSubmit(() => {
              this.focusNext()
            })
        }
        .width("100%")
        .padding(16)
        .alignItems(VerticalAlign.Center)

        // 用户名
        Row() {
          Text("用户名")
            .fontSize(16)
            .width(100)
            .textAlign(TextAlign.End)
            .margin({ right: 12 })

          TextInput({ text: this.username, placeholder: "必填" })
            .layoutWeight(1)
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .enabled(!this.isLoading)
            .id('usernameInput')
            .key(`username_${this.currentFocusIndex === 4 ? 'focus' : 'blur'}`)
            .defaultFocus(this.currentFocusIndex === 4)
            .enterKeyType(EnterKeyType.Next)
            .onChange((value: string) => {
              this.username = value
            })
            .onSubmit(() => {
              this.focusNext()
            })
        }
        .width("100%")
        .padding(16)
        .alignItems(VerticalAlign.Center)

        // 密码
        Row() {
          Text("密码")
            .fontSize(16)
            .width(100)
            .textAlign(TextAlign.End)
            .margin({ right: 12 })

          TextInput({ text: this.password, placeholder: "必填" })
            .layoutWeight(1)
            .height(40)
            .fontSize(16)
            .placeholderFont({ size: 16 })
            .type(InputType.Password)
            .enabled(!this.isLoading)
            .id('passwordInput')
            .key(`password_${this.currentFocusIndex === 5 ? 'focus' : 'blur'}`)
            .defaultFocus(this.currentFocusIndex === 5)
            .enterKeyType(EnterKeyType.Done)
            .onChange((value: string) => {
              this.password = value
            })
            .onSubmit(() => {
              // 最后一个输入框，关闭键盘
            })
        }
        .width("100%")
        .padding(16)
        .alignItems(VerticalAlign.Center)
      }

      // 操作按钮
      Row({ space: 16 }) {
        Button(this.isLoading && this.loadingText === '测试连接中...' ? this.loadingText : '测试连接')
          .fontSize(16)
          .layoutWeight(1)
          .enabled(!this.isLoading)
          .onClick(() => {
            this.handleTestConnection()
          })

        Button(this.isLoading && this.loadingText === '保存中...' ? this.loadingText : '保存')
          .fontSize(16)
          .layoutWeight(1)
          .type(ButtonType.Normal)
          .backgroundColor('#007DFF')
          .enabled(!this.isLoading)
          .onClick(() => {
            this.handleSave()
          })
      }
      .width("100%")
      .padding(16)
    }
  }
}

@Builder
export function WebDAVConfigBuilder() {
  WebDAVConfigBuilderComponent()
}



