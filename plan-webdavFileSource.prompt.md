# 计划：实现 WebDAV 文件源添加功能

实现点击"WebDAV / Alist"后打开 WebDAV 配置表单页面，支持添加、编辑、删除、测试连接等完整功能。用户可以配置 WebDAV 服务器信息并保存到关系型数据库，密码使用 AES 加密存储，支持多目录关联。包含数据库版本管理、URL 格式校验、Loading 状态优化、防抖优化（含取消机制）、缓存优化和完整的测试用例。

## 步骤

### 1. 提取图标 Builder 到独立文件方便复用

- 创建 [pages/settings/builders/IconBuilders.ets](pages/settings/builders/IconBuilders.ets)
- 将 [AddFileSourceBuilder.ets](pages/settings/builders/AddFileSourceBuilder.ets) 中的 8 个图标 Builder（`SmbIcon`, `WebdavIcon`, `AliyunIcon`, `Cloud139Icon`, `BaiduIcon`, `Cloud123Icon`, `Cloud115Icon`, `OtherIcon`）完整迁移到新文件并导出
- 修改 `AddFileSourceBuilder.ets` 导入这些图标 Builder

### 2. 创建加密工具类

- 创建 [lib/utils/CryptoUtil.ets](lib/utils/CryptoUtil.ets)
- 使用 `@ohos.security.cryptoFramework` 实现 AES-256-GCM 模式加密
- 实现密钥派生：使用 bundleName `"com.yao.vidalltv"` 加固定盐值通过 PBKDF2 派生 32 字节 AES 密钥
- 实现 `async encrypt(plaintext: string): Promise<string>` 方法，生成随机 IV，加密后返回 `${iv}:${ciphertext}:${authTag}` 格式的 Base64 编码字符串
- 实现 `async decrypt(encrypted: string): Promise<string>` 方法，解析加密字符串并解密
- 导出 `CryptoUtil` 类包含静态方法

### 3. 创建防抖工具函数（含取消机制）

- 创建 [lib/utils/DebounceUtil.ets](lib/utils/DebounceUtil.ets)
- 实现 `debounce<T extends (...args: any[]) => void>(func: T, delay: number): T & { cancel: () => void }` 函数
- 内部使用 `setTimeout` 实现延迟执行，保存 `timeoutId` 到闭包变量
- 返回的函数附加 `cancel()` 方法，调用时执行 `clearTimeout(timeoutId)` 清除待执行任务
- 默认延迟 300ms

### 4. 创建数据模型定义

- 创建 [lib/models/FileSourceModel.ets](lib/models/FileSourceModel.ets)
- 定义 `enum FileSourceType { WEBDAV = 'webdav', SMB = 'smb', ALIYUN = 'aliyun', CLOUD_139 = 'cloud139', BAIDU = 'baidu', CLOUD_123 = 'cloud123', CLOUD_115 = 'cloud115', OTHER = 'other' }`
- 定义 `interface WebDAVSourceConfig { url: string; username: string; password: string; protocol: 'http' | 'https'; port: number; rootPath: string }`
- 定义 `interface FileSource { id?: number; name: string; type: FileSourceType; configJson: string; createdAt: number }`
- 定义 `interface FileSourceDirectory { id?: number; sourceId: number; directoryPath: string }`

### 5. 实现数据库单例管理类（含版本升级机制）

- 创建 [lib/database/FileSourceDatabase.ets](lib/database/FileSourceDatabase.ets)
- 定义常量：`DB_VERSION = 1`, `DB_NAME = 'FILE_SOURCES_DB'`, `TABLE_FILE_SOURCES = 'file_sources'`, `TABLE_DIRECTORIES = 'file_source_directories'`
- 实现单例模式 `class FileSourceDatabase` 包含 `private static instance`, `static getInstance(context): FileSourceDatabase`
- 在 `async init()` 方法中使用 `relationalStore.getRdbStore(context, { name: DB_NAME, securityLevel: SecurityLevel.S1 }, version)` 创建数据库
- 实现 `onCreate(rdbStore)` 创建表：`file_sources`（id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, config_json TEXT NOT NULL, created_at INTEGER NOT NULL）和 `file_source_directories`（id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, directory_path TEXT NOT NULL, FOREIGN KEY(source_id) REFERENCES file_sources(id) ON DELETE CASCADE）
- 实现 `onUpgrade(rdbStore, oldVersion, newVersion)` 使用 switch-case 处理版本升级，当前为空（预留扩展）
- 实现 CRUD 方法：`async insertFileSource(fileSource: FileSource): Promise<number>`，`async updateFileSource(fileSource: FileSource): Promise<void>`，`async deleteFileSource(id: number): Promise<void>`，`async getFileSourceById(id: number): Promise<FileSource | null>`，`async getAllFileSources(): Promise<FileSource[]>`
- 在保存/更新时解析 `configJson`，对密码字段使用 `CryptoUtil.encrypt()` 加密后重新序列化；读取时解密

### 6. 实现文件源缓存管理类

- 创建 [lib/stores/FileSourceStore.ets](lib/stores/FileSourceStore.ets)
- 使用 `@ObservedV2 class FileSourceStore` 包含 `@Trace fileSources: FileSource[] = []`, `@Trace isLoaded: boolean = false`, `private lastUpdateTime: number = 0`
- 定义缓存有效期常量 `CACHE_DURATION = 5 * 60 * 1000`（5 分钟）
- 实现单例模式 `static getInstance(): FileSourceStore`
- 实现 `async loadFileSources(forceReload: boolean = false): Promise<void>` 方法，检查 `isLoaded` 和缓存时间戳，只在需要时调用 `FileSourceDatabase.getAllFileSources()`
- 实现 `async addFileSource(fileSource: FileSource): Promise<void>` 调用数据库插入，成功后更新缓存数组
- 实现 `async updateFileSource(fileSource: FileSource): Promise<void>` 调用数据库更新，成功后更新缓存数组对应项
- 实现 `async deleteFileSource(id: number): Promise<void>` 调用数据库删除，成功后从缓存数组移除
- 实现 `invalidateCache()` 设置 `isLoaded = false` 清空缓存

### 7. 在 EntryAbility 初始化数据库

- 修改 [entryability/EntryAbility.ets](entryability/EntryAbility.ets) 的 `onCreate()` 方法
- 在现有代码后添加数据库初始化：使用 `try-catch` 包装 `await FileSourceDatabase.getInstance(this.context).init()`
- 初始化失败时使用 `hilog.error(DOMAIN, 'testTag', 'Failed to init database: %{public}s', JSON.stringify(err))` 记录错误

### 8. 扩展 SettingsController 支持参数传递

- 修改 [SettingsController.ets](pages/settings/SettingsController.ets)
- 修改 `pushType()` 方法签名为 `pushType(newType: SettingType, params?: Record<string, Object>): void`
- 添加 `@Trace params: Record<string, Object> | undefined = undefined`
- 添加 `private paramsStack: (Record<string, Object> | undefined)[] = []`
- 在 `pushType()` 内将当前 `this.params` 压入 `paramsStack`，然后设置 `this.params = params`
- 在 `popType()` 内弹出 `paramsStack` 恢复 `this.params`
- 在 `reset()` 和 `clearStack()` 内清空 `paramsStack` 和 `params`

### 9. 添加 WebDAV 配置页面类型和导航

- 在 [SettingType.ets](pages/settings/SettingType.ets) 添加 `static WEBDAV_CONFIG = "webdavConfig"`
- 修改 [AddFileSourceBuilder.ets](pages/settings/builders/AddFileSourceBuilder.ets)，将 `@Builder export function AddFileSourceBuilder()` 改为 `@ComponentV2 struct AddFileSourceBuilderComponent` 包装，内部使用原有 Builder 逻辑
- 导出新的 `@Builder function AddFileSourceBuilder() { AddFileSourceBuilderComponent() }`
- 在组件内添加 `@Consumer('settingsController') controller: SettingsController = new SettingsController()`
- 为"WebDAV / Alist"的 `SettingListItem` 添加 `isLink: true` 和 `onItemClick: () => { this.controller.pushType(SettingType.WEBDAV_CONFIG) }`

### 10. 创建 URL 验证工具函数

- 创建 [lib/utils/ValidationUtil.ets](lib/utils/ValidationUtil.ets)
- 导出 `class ValidationUtil` 包含静态方法
- 实现 `static validateUrl(url: string): { valid: boolean; message: string }` 方法
- 使用正则表达式 `/^https?:\/\/[\w\-]+(\.[\w\-]+)+([\w\-\.,@?^=%&:/~\+#]*[\w\-\@?^=%&/~\+#])?$/i` 验证
- 验证失败返回 `{ valid: false, message: "请输入有效的 URL 地址，例如：http://example.com" }`
- 验证成功返回 `{ valid: true, message: "" }`

### 11. 创建 WebDAV 配置表单页面（含 Loading、验证和防抖）

- 创建 [pages/settings/builders/WebDAVConfigBuilder.ets](pages/settings/builders/WebDAVConfigBuilder.ets)
- 定义 `@ComponentV2 struct WebDAVConfigBuilderComponent` 包含 `@Consumer('settingsController') controller: SettingsController`
- 定义表单状态：`@Local serverName: string = ''`, `@Local serverUrl: string = ''`, `@Local username: string = ''`, `@Local password: string = ''`, `@Local protocol: 'http' | 'https' = 'https'`, `@Local port: number = 443`, `@Local rootPath: string = '/'`, `@Local urlError: string = ''`
- 定义 Loading 状态：`@Local isLoading: boolean = false`, `@Local loadingText: string = ''`
- 定义 `private debouncedValidateUrl: ((url: string) => void) & { cancel: () => void }`
- 在 `aboutToAppear()` 中：1) 创建防抖验证函数 `this.debouncedValidateUrl = DebounceUtil.debounce((url: string) => { const result = ValidationUtil.validateUrl(url); this.urlError = result.valid ? '' : result.message }, 300)` 2) 检查 `controller.params?.fileSourceId`，如果存在则加载编辑数据
- 在 `aboutToDisappear()` 中调用 `this.debouncedValidateUrl.cancel()` 取消待执行任务
- 使用 `SettingContainer({ title: "WebDAV 配置" })` 包装表单
- 使用 `SettingListItemGroup` 分组："基本信息"、"连接设置"、"高级设置"
- 基本信息：服务器名称使用 `TextInput` 绑定 `serverName`
- 连接设置：服务器地址使用 `TextInput` 绑定 `serverUrl`，`.onChange()` 调用 `this.debouncedValidateUrl(value)`，下方显示红色错误提示 `if (this.urlError) { Text(this.urlError).fontColor(Color.Red) }`；协议选择使用 `SettingListItem` 显示当前 `protocol`，点击弹出 `AlertDialog` 单选并更新端口默认值；端口使用 `TextInput` 配置 `type: InputType.Number`；用户名和密码使用 `TextInput`，密码配置 `type: InputType.Password`
- 高级设置：根目录路径使用 `TextInput` 绑定 `rootPath`
- 所有输入组件添加 `.enabled(!this.isLoading)`
- 底部 `Row` 包含两个 `Button`："测试连接"和"保存"，`.enabled(!this.isLoading)`，Loading 时按钮文本显示 `loadingText`
- 导出 `@Builder function WebDAVConfigBuilder() { WebDAVConfigBuilderComponent() }`

### 12. 实现 WebDAV 测试连接功能

- 在 [WebDAVClient.ets](lib/WebDAVClient.ets) 添加 `async testConnection(rootPath: string): Promise<{ success: boolean; message: string }>` 方法
- 实现测试逻辑：1) 构造 OPTIONS 请求测试连接 2) 构造 PROPFIND 请求测试认证和根目录访问
- 捕获异常返回友好错误消息：网络错误、401 认证失败、404 目录不存在等
- 在配置表单"测试连接"按钮 `onClick()` 中：1) 验证必填字段 2) 检查 `urlError` 是否为空 3) 设置 `isLoading = true, loadingText = '测试连接中...'` 4) 构造 `WebDAVConfig` 调用测试 5) 完成后 `isLoading = false` 6) 失败显示 `AlertDialog`，成功显示 `promptAction.showToast({ message: '连接成功' })`

### 13. 实现保存功能（含 Loading 和验证）

- 在"保存"按钮 `onClick()` 中：1) 验证必填字段非空 2) 检查 `urlError` 非空则提示修正 3) 验证端口范围 1-65535 4) 设置 `isLoading = true, loadingText = '保存中...'` 5) 构造 `WebDAVSourceConfig` 并序列化为 JSON 6) 构造 `FileSource` 对象 7) 根据是否有 `fileSourceId` 调用 `FileSourceStore.getInstance().addFileSource()` 或 `updateFileSource()` 8) 完成后 `isLoading = false` 9) 成功显示 Toast 并调用 `controller.popType()`，失败显示 `AlertDialog`

### 14. 更新文件源列表页面（含缓存、Loading 和删除确认）

- 修改 [FileSourceSettingBuilder.ets](pages/settings/builders/FileSourceSettingBuilder.ets)
- 将 `@Builder` 改为 `@ComponentV2 struct FileSourceSettingBuilderComponent`
- 添加 `@Consumer('settingsController') controller: SettingsController`，`@Local fileSourceStore: FileSourceStore = FileSourceStore.getInstance()`，`@Local isLoading: boolean = false`
- 在 `aboutToAppear()` 中调用 `this.fileSourceStore.loadFileSources().catch(err => hilog.error(...))`
- 移除"暂无文件源"项，使用 `ForEach(this.fileSourceStore.fileSources, ...)` 渲染列表
- 每项使用 `SettingListItem`，从 `IconBuilders` 导入图标，显示名称和类型标签（使用映射函数将 type 转换为中文）
- 右侧添加 `Text("⋮").fontSize(24)` 作为"更多"按钮，使用 `.bindMenu([{ value: '编辑', action: ... }, { value: '删除', action: ... }])`
- "编辑"点击调用 `this.controller.pushType(SettingType.WEBDAV_CONFIG, { fileSourceId: item.id })`
- "删除"点击弹出 `AlertDialog.show({ message: '确定删除此文件源？', buttons: [{ text: '取消' }, { text: '删除', action: () => { this.isLoading = true; this.fileSourceStore.deleteFileSource(id).then(...).finally(() => this.isLoading = false) } }] })`
- 导出 `@Builder function FileSourceSettingBuilder(controller: SettingsController) { FileSourceSettingBuilderComponent() }`

### 15. 注册 WebDAV 配置页面到主路由

- 在 [Index.ets](pages/settings/Index.ets) 导入 `{ WebDAVConfigBuilder } from './builders/WebDAVConfigBuilder'`
- 在 `build()` 方法的 `Column` 内添加条件渲染：`if (this.controller.type === SettingType.WEBDAV_CONFIG) { WebDAVConfigBuilder() }`

### 16. 创建数据库迁移测试用例

- 创建 [test/FileSourceDatabase.test.ets](test/FileSourceDatabase.test.ets)
- 使用 `describe('FileSourceDatabase', () => { ... })` 组织测试套件
- 测试用例 1：`it('should create tables on init', ...)` - 初始化数据库，查询 `sqlite_master` 验证表存在，查询表结构验证字段正确
- 测试用例 2：`it('should upgrade from version 1 to 2', ...)` - 手动创建版本 1 数据库，插入测试数据，修改版本号触发升级，验证表结构和数据完整性
- 测试用例 3：`it('should encrypt password on save', ...)` - 插入包含密码的文件源，直接查询数据库验证密码字段已加密，通过 API 读取验证密码正确解密
- 测试用例 4：`it('should handle cross-version upgrade', ...)` - 模拟从版本 1 直接升级到版本 3（假设存在），验证中间版本升级步骤都执行
- 使用 `beforeEach()` 初始化测试数据库上下文，`afterEach()` 删除测试数据库文件

## 进一步考虑

无

