# Tasks: 华为账号授权登录 + Cloud DB + 退出登录

> 实现清单。依赖顺序：AGC 控制台前置 → 数据模型 → 抽象与 provider → 仓库层 → 编排服务 → 本地态 → UI 集成 → 自检。
> 参考 `specs/huawei-account-login/spec.md`（做什么）、`design.md`（怎么做）。

## 1. AGC 控制台前置配置（手动，前置）

- [ ] 1.1 AGC 控制台确认「华为账号」认证已开启（`agconnect-services.json` 已含 client_id/app_id/oauth_client，确认认证服务启用）。验证：控制台「增长 → 华为账号」页面显示已开启状态
- [x] 1.2 AGC 控制台开启「云数据库」服务，创建存储区（确认命名：沿用现有或新建 `VidAllZone`，记录最终名称供代码使用）。验证：控制台「云数据库」可见存储区列表含目标 zone
- [x] 1.3 AGC 控制台创建对象类型 `UserAccount`（字段：`accountId` String 主键、`displayName` String、`avatarUri` String、`createdAt` Date、`updatedAt` Date）与 `AccountBinding`（字段：`bindingId` String 主键、`accountId` String 索引、`platform` String 索引、`platformUserId` String 索引、`platformDisplayName` String、`platformAvatarUri` String、`boundAt` Date、`updatedAt` Date）。验证：控制台对象类型列表含两个类型且字段/索引配置正确
- [x] 1.4 导出 Cloud DB schema JSON 到 `entry/src/main/resources/rawfile/`（固定文件名 `schema.json`）。验证：`entry/src/main/resources/rawfile/schema.json` 存在且含 `UserAccount`/`AccountBinding` 定义
- [ ] 1.5 AGC 控制台确认 Authentication 服务已启用且华为账号登录方式可用。验证：认证服务配置页显示已启用，当前应用配置匹配签名与 Client ID
- [x] 1.6 将本地 `schema.json` 中 `UserAccount`、`AccountBinding` 收紧为仅 `Creator: Read + Upsert + Delete` 与 `Administrator: Read + Upsert + Delete`，移除 `World` 和宽泛 `Authenticated` 权限。验证：本地 schema 不再允许匿名或其他认证用户读取 unionID 等账号数据
- [ ] 1.7 在 AGC 控制台同步并重新发布最小权限 schema。验证：控制台已发布版本与本地 `schema.json` 权限一致，登录用户仅能读写自己创建的数据

## 2. Cloud DB 数据模型

- [x] 2.1 新增 `entry/src/main/ets/db/models/UserAccount.ets`：`export class UserAccount extends cloudDatabase.DatabaseObject`，字段 `accountId/displayName/avatarUri/createdAt/updatedAt`，实现 `naturalbase_ClassName()` 返回 `'UserAccount'`，空字段用 `''` 初始值。验证：文件存在，`import { cloudDatabase } from '@kit.CloudFoundationKit'` 正确，类字段类型为 `string`/`Date`
- [x] 2.2 新增 `entry/src/main/ets/db/models/AccountBinding.ets`：`export class AccountBinding extends cloudDatabase.DatabaseObject`，字段 `bindingId/accountId/platform/platformUserId/platformDisplayName/platformAvatarUri/boundAt/updatedAt`，实现 `naturalbase_ClassName()` 返回 `'AccountBinding'`。验证：同上，字段与 AGC 控制台定义一致

## 3. AuthProvider 抽象与 PlatformIdentity

- [x] 3.1 新增 `entry/src/main/ets/services/account/AuthProvider.ets`：定义 `export interface PlatformIdentity`（`platformUserId: string`、`displayName: string`、`avatarUri: string`、`openID: string`、`raw: Map<string, string>`）与 `export interface AuthProvider`（`providerId: string`、`displayName: string`、`login(): Promise<PlatformIdentity>`、`signOut(): Promise<void>`）。验证：文件存在，接口字段与 design.md 一致，无 `any`/`unknown`

## 4. HuaweiAuthProvider 实现

- [x] 4.1 新增 `entry/src/main/ets/services/account/providers/HuaweiAuthProvider.ets`：`export class HuaweiAuthProvider implements AuthProvider`，`providerId='huawei'`、`displayName='华为账号'`，持有 `loginComponentManager.LoginWithHuaweiIDButtonController`。验证：`import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit'` 正确，controller 可被 UI 获取
- [x] 4.2 实现 `login()`：用 controller 注册 `onClickLoginWithHuaweiIDButton` 回调，封装为 Promise；回调成功时从 `HuaweiIDCredential` 取 `unionID`→`platformUserId`、`openID`、`authorizationCode`（存 raw）、`idToken`（解码 JWT payload 取 `name`/`picture` claims 填 displayName/avatarUri，无则空字符串），resolve `PlatformIdentity`；回调失败或 err 非空时 reject `BusinessError`。验证：方法签名匹配接口，`catch` 无类型注解，BusinessError 错误码 1001502012（用户取消）有处理分支
- [x] 4.3 实现 `signOut()`：华为侧无显式 signOut API，不调 `CancelAuthorizationRequest`，方法体空（本地态清理由 AccountService 负责），直接 resolve。验证：方法返回 `Promise<void>`，不调用任何撤销授权 API
- [x] 4.4 在根级 `LoginDialog` 使用 `HuaweiAuthProvider.getController()` 渲染官方 `LoginWithHuaweiIDButton`，显式设置 `BUTTON_CUSTOM` 与 `loginType: LoginType.ID`，配置 TV 的 normal/focused/pressed/disabled 状态。验证：设置菜单不直接渲染平台按钮，未使用企业开发者限定的 `QUICK_LOGIN`
- [x] 4.5 基础凭据缺少昵称或头像时，通过页面一次性注入的 `UIAbilityContext` 执行 `AuthorizationWithHuaweiIDRequest` 并申请 `profile` scope，合并 `nickName/avatarUri`；用户拒绝或失败不阻断基础登录，请求完成后释放 context。验证：资料请求异常只记录非敏感错误码，仍返回含 unionID 的身份

## 5. Cloud DB 仓库层

- [x] 5.1 新增 `entry/src/main/ets/services/account/repo/CloudAccountRepository.ets`：`export class CloudAccountRepository`，方法 `upsert(account: UserAccount): Promise<number>`（`cloudDatabase.zone(zoneName).upsert(account)`）、`queryById(accountId: string): Promise<UserAccount | null>`（`cloudDatabase.DatabaseQuery(UserAccount).equalTo('accountId', accountId)` → `zone.query` → 返回首条或 null）。验证：zoneName 与 AGC 控制台一致，泛型约束 `T extends DatabaseObject` 正确
- [x] 5.2 新增 `entry/src/main/ets/services/account/repo/CloudBindingRepository.ets`：`export class CloudBindingRepository`，方法 `upsert(binding: AccountBinding): Promise<number>`、`findByPlatformUser(platform: string, platformUserId: string): Promise<AccountBinding | null>`（`DatabaseQuery(AccountBinding).equalTo('platform', platform).equalTo('platformUserId', platformUserId)` → query → 首条或 null）。验证：复合条件查询链式调用正确，返回类型明确

## 5A. AGC Authentication 与 Cloud Foundation 认证上下文

- [x] 5A.1 在 `entry/oh-package.json5` 新增 `@hw-agconnect/auth@^1.0.5` 并用 ohpm 恢复依赖。验证：锁文件包含该包，SDK `.d.ts` 可读取
- [x] 5A.2 按 SDK 权威类型定义建立 AGC Authentication 华为账号会话，不把 `idToken` 冒充 Cloud Foundation access token，不在客户端保存 client secret。验证：认证登录成功并可获取 `auth.getAuthProvider()`
- [x] 5A.3 在首次 Cloud DB 访问前调用 `cloudCommon.init()`，传入 AGC `authProvider` 与 `schema.json`，并保证初始化完成后才执行 query/upsert。验证：Authenticated 权限生效，写入不再报 `2001015`
- [x] 5A.4 退出登录时同步清理 AGC Authentication 会话；失败时仍清理本地态并记录可定位日志。验证：退出后再次登录可重新建立认证上下文

## 6. AccountService 编排

- [x] 6.1 新增 `entry/src/main/ets/services/account/AccountService.ets`：`export class AccountService`，内部 `providers: Map<string, AuthProvider>`、`accountRepo: CloudAccountRepository`、`bindingRepo: CloudBindingRepository`，方法 `registerProvider(p: AuthProvider)`。验证：依赖在构造或属性注入，类型明确
- [x] 6.2 实现 `loginWith(providerId: string): Promise<void>`：`provider.login()` → `PlatformIdentity` → `bindingRepo.findByPlatformUser(platformId, identity.platformUserId)` → 命中则按 `binding.accountId` 载入账号，未命中则以 `providerId:platformUserId` 作为账号和绑定的确定性主键新建记录 → 更新非空平台资料 → 依次 upsert 账号与绑定 → 写入本地登录态。验证：历史随机主键绑定仍可由复合条件查询命中；同一平台身份的并发首次登录写入相同主键；失败时不写本地登录态
- [x] 6.3 实现 `logout(): Promise<void>`：读 `AppPreferences.getCurrentProviderId()` → `provider.signOut()` → `AppPreferences.clearLoginState()` → 通知 UI 回未登录。验证：不删 Cloud DB 记录，仅清本地态
- [x] 6.4 再次登录时仅用非空授权资料更新 `UserAccount` 与 `AccountBinding`，空昵称/头像保留已有云端值；本地登录态写入最终合并值。验证：空资料不会覆盖历史值

## 7. 本地登录态持久化

- [x] 7.1 扩展 `entry/src/main/ets/utils/AppPreferences.ets`：新增 `PrefKey` 项 `account.accountId`、`account.currentProviderId`、`account.displayName`、`account.avatarUri`、`account.loginTime`、`account.isLogged`，新增方法 `setLoginState(accountId, providerId, displayName, avatarUri, loginTime)`、`clearLoginState()`、`getCurrentProviderId(): string`、`isLogged(): boolean`、`getAccountId(): string`、`getDisplayName(): string`、`getAvatarUri(): string`。验证：PrefKey 命名与现有风格一致，方法读写底层 preferences 正确

## 8. 启动初始化与登录态恢复

- [x] 8.1 修改 `entry/src/main/ets/entryability/EntryAbility.ets`：UI 构建前注册 `HuaweiAuthProvider`，在 `AppPreferences.init()` 完成后调用全局 `AccountModel.restore()`。验证：启动后所有页面直接读取同一恢复状态，不重新授权
- [x] 8.2 新增 `stores/account/AccountModel.ets`：使用 `AppStorageV2.connect()` + `@ObservedV2`/`@Trace` 维护应用级账号资料、登录弹层、登录进度与错误状态；登录、退出和恢复均连接固定 key 并更新同一模型。验证：任意页面修改后可驱动根组件即时刷新

## 9. UI 集成：全局登录弹层与设置页账号分组

- [x] 9.1 修改 `HomeSettingBuilder.ets`：未登录态仅展示与其他菜单一致的「登录」项，点击只调用 `AccountModel.showLoginDialog()`；不直接渲染华为按钮或自动授权。已登录态保留原结构。验证：进入设置不会拉起授权
- [x] 9.2 已登录态「退出登录」接通 `AccountService.logout()`，由服务在 `finally` 清理本地与全局状态。验证：退出完成后所有页面即时切回未登录
- [x] 9.3 新增根级 `LoginDialog.ets` 并挂载到 `Index.ets`：弹层集中承载官方华为按钮、未来平台提示、取消入口和错误提示；返回键优先关闭弹层。验证：任意业务可复用同一入口
- [x] 9.4 登录成功后由 `AccountService` 在云端和本地持久化完成后调用 `AccountModel.applyLoggedInState()`，弹层关闭且设置页即时展示昵称头像；空资料使用降级 UI。验证：无需重新进入页面
- [x] 9.5 弹层显示时预注册 provider controller 回调，授权取消/失败后展示提示并重新布防；关闭再打开时不重复注册等待流程。验证：只有点击官方按钮才授权，取消后可重试，无自动授权

## 10. 自检清单（验证阶段）

- [x] 10.1 编译通过：`assembleHap` 任务 BUILD SUCCESSFUL，无 ArkTS 报错（重点核查 `build()` 内无变量声明、`catch` 无类型注解、对象字面量有显式类型、无 `any`/`unknown`）。验证：hvigor 退出码 0 且日志含 BUILD SUCCESSFUL
- [x] 10.2 真机华为授权登录：局域网电视安装后，设置页未登录态点击华为登录按钮 → 拉起华为授权 → 同意后账号分组切换已登录态。验证：UI 状态切换成功，无异常
- [ ] 10.3 Cloud DB 双表写入验证：登录成功后在 AGC 控制台「云数据库 → 数据查询」查 `UserAccount` 与 `AccountBinding` 两表，确认有对应记录（accountId/bindingId/platform='huawei'/platformUserId=unionID）。验证：两表各有 1 条记录，字段值正确
- [ ] 10.4 退出登录回退：已登录态点退出登录 → 账号分组回未登录态 → Cloud DB 两表记录仍在（控制台查询确认）。验证：UI 回未登录，Cloud DB 记录未删
- [ ] 10.5 重启登录态恢复：已登录态杀进程重启 App → 设置页账号分组直接显示已登录态（不重新拉起华为授权）。验证：重启后无需授权即已登录
- [ ] 10.6 唯一入口与失败重试：进入设置不自动授权；点「登录」只打开弹层；点官方按钮后在授权页取消 → 弹层保留、全局状态未登录、不写 Cloud DB并显示可重试提示；关闭后再次打开不会出现重复回调。验证：各路径逐项通过
- [x] 10.7 ArkTS 护栏 lint：全文核查 `services/account/` 与 `db/models/` 下文件无 `any`/`unknown`/`catch(e: X)`/`build()` 内变量声明等违规。验证：grep 无命中违规模式
- [ ] 10.8 真机 profile 资料增强：同意资料授权后展示昵称头像；拒绝资料授权仍完成登录并显示降级 UI；重启后恢复资料，再登录空资料不覆盖 Cloud DB 历史值。验证：四条路径逐项通过
