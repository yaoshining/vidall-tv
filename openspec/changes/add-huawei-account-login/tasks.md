# Tasks: 华为账号授权登录 + Cloud DB + 退出登录

> 实现清单。依赖顺序：AGC 控制台前置 → 数据模型 → 抽象与 provider → 仓库层 → 编排服务 → 本地态 → UI 集成 → 自检。
> 参考 `specs/huawei-account-login/spec.md`（做什么）、`design.md`（怎么做）。

## 1. AGC 控制台前置配置（手动，前置）

- [ ] 1.1 AGC 控制台确认「华为账号」认证已开启（`agconnect-services.json` 已含 client_id/app_id/oauth_client，确认认证服务启用）。验证：控制台「增长 → 华为账号」页面显示已开启状态
- [ ] 1.2 AGC 控制台开启「云数据库」服务，创建存储区（确认命名：沿用现有或新建 `VidAllZone`，记录最终名称供代码使用）。验证：控制台「云数据库」可见存储区列表含目标 zone
- [ ] 1.3 AGC 控制台创建对象类型 `UserAccount`（字段：`accountId` String 主键、`displayName` String、`avatarUri` String、`createdAt` Date、`updatedAt` Date）与 `AccountBinding`（字段：`bindingId` String 主键、`accountId` String 索引、`platform` String 索引、`platformUserId` String 索引、`platformDisplayName` String、`platformAvatarUri` String、`boundAt` Date、`updatedAt` Date）。验证：控制台对象类型列表含两个类型且字段/索引配置正确
- [ ] 1.4 导出 Cloud DB schema JSON 到 `entry/src/main/resources/rawfile/`（文件名如 `VidAllZone_schema.json`，按控制台导出命名）。验证：`entry/src/main/resources/rawfile/` 下存在 schema 文件且含 `UserAccount`/`AccountBinding` 定义

## 2. Cloud DB 数据模型

- [x] 2.1 新增 `entry/src/main/ets/db/models/UserAccount.ets`：`export class UserAccount extends cloudDatabase.DatabaseObject`，字段 `accountId/displayName/avatarUri/createdAt/updatedAt`，实现 `naturalbase_ClassName()` 返回 `'UserAccount'`，空字段用 `''` 初始值。验证：文件存在，`import { cloudDatabase } from '@kit.CloudFoundationKit'` 正确，类字段类型为 `string`/`Date`
- [x] 2.2 新增 `entry/src/main/ets/db/models/AccountBinding.ets`：`export class AccountBinding extends cloudDatabase.DatabaseObject`，字段 `bindingId/accountId/platform/platformUserId/platformDisplayName/platformAvatarUri/boundAt/updatedAt`，实现 `naturalbase_ClassName()` 返回 `'AccountBinding'`。验证：同上，字段与 AGC 控制台定义一致

## 3. AuthProvider 抽象与 PlatformIdentity

- [x] 3.1 新增 `entry/src/main/ets/services/account/AuthProvider.ets`：定义 `export interface PlatformIdentity`（`platformUserId: string`、`displayName: string`、`avatarUri: string`、`openID: string`、`raw: Map<string, string>`）与 `export interface AuthProvider`（`providerId: string`、`displayName: string`、`login(): Promise<PlatformIdentity>`、`signOut(): Promise<void>`）。验证：文件存在，接口字段与 design.md 一致，无 `any`/`unknown`

## 4. HuaweiAuthProvider 实现

- [x] 4.1 新增 `entry/src/main/ets/services/account/providers/HuaweiAuthProvider.ets`：`export class HuaweiAuthProvider implements AuthProvider`，`providerId='huawei'`、`displayName='华为账号'`，持有 `loginComponentManager.LoginWithHuaweiIDButtonController`。验证：`import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit'` 正确，controller 可被 UI 获取
- [x] 4.2 实现 `login()`：用 controller 注册 `onClickLoginWithHuaweiIDButton` 回调，封装为 Promise；回调成功时从 `HuaweiIDCredential` 取 `unionID`→`platformUserId`、`openID`、`authorizationCode`（存 raw）、`idToken`（解码 JWT payload 取 `name`/`picture` claims 填 displayName/avatarUri，无则空字符串），resolve `PlatformIdentity`；回调失败或 err 非空时 reject `BusinessError`。验证：方法签名匹配接口，`catch` 无类型注解，BusinessError 错误码 1001502012（用户取消）有处理分支
- [x] 4.3 实现 `signOut()`：华为侧无显式 signOut API，不调 `CancelAuthorizationRequest`，方法体空（本地态清理由 AccountService 负责），直接 resolve。验证：方法返回 `Promise<void>`，不调用任何撤销授权 API
- [x] 4.4 新增 `huaweiLoginButtonBuilder`（`@Builder`）：渲染 `LoginWithHuaweiIDButton({ params: { style: BUTTON_RED, borderRadius: 24, supportDarkMode: true }, controller: this.getController() })`，供 UI 未登录态调用。验证：Builder 内只用 UI 组件语法，无 `const`/`let` 声明

## 5. Cloud DB 仓库层

- [x] 5.1 新增 `entry/src/main/ets/services/account/repo/CloudAccountRepository.ets`：`export class CloudAccountRepository`，方法 `upsert(account: UserAccount): Promise<number>`（`cloudDatabase.zone(zoneName).upsert(account)`）、`queryById(accountId: string): Promise<UserAccount | null>`（`cloudDatabase.DatabaseQuery(UserAccount).equalTo('accountId', accountId)` → `zone.query` → 返回首条或 null）。验证：zoneName 与 AGC 控制台一致，泛型约束 `T extends DatabaseObject` 正确
- [x] 5.2 新增 `entry/src/main/ets/services/account/repo/CloudBindingRepository.ets`：`export class CloudBindingRepository`，方法 `upsert(binding: AccountBinding): Promise<number>`、`findByPlatformUser(platform: string, platformUserId: string): Promise<AccountBinding | null>`（`DatabaseQuery(AccountBinding).equalTo('platform', platform).equalTo('platformUserId', platformUserId)` → query → 首条或 null）。验证：复合条件查询链式调用正确，返回类型明确

## 6. AccountService 编排

- [x] 6.1 新增 `entry/src/main/ets/services/account/AccountService.ets`：`export class AccountService`，内部 `providers: Map<string, AuthProvider>`、`accountRepo: CloudAccountRepository`、`bindingRepo: CloudBindingRepository`，方法 `registerProvider(p: AuthProvider)`。验证：依赖在构造或属性注入，类型明确
- [x] 6.2 实现 `loginWith(providerId: string): Promise<void>`：`provider.login()` → `PlatformIdentity` → `bindingRepo.findByPlatformUser(platformId, identity.platformUserId)` → 命中则 `accountRepo.queryById(binding.accountId)` 载入账号，未命中则新建 `UserAccount`（UUID accountId）+ `AccountBinding`（UUID bindingId）→ 更新 binding 的 `platformDisplayName`/`platformAvatarUri`/`updatedAt` + account 的 `displayName`/`avatarUri`/`updatedAt` → `accountRepo.upsert` + `bindingRepo.upsert` → `AppPreferences.setLoginState(...)` → 通知 UI。验证：先 query 后 upsert 顺序正确，UUID 生成用 `util.generateRandomUUID`（`@ohos.util`），失败时不写 Cloud DB
- [x] 6.3 实现 `logout(): Promise<void>`：读 `AppPreferences.getCurrentProviderId()` → `provider.signOut()` → `AppPreferences.clearLoginState()` → 通知 UI 回未登录。验证：不删 Cloud DB 记录，仅清本地态

## 7. 本地登录态持久化

- [x] 7.1 扩展 `entry/src/main/ets/utils/AppPreferences.ets`：新增 `PrefKey` 项 `account.accountId`、`account.currentProviderId`、`account.displayName`、`account.avatarUri`、`account.loginTime`、`account.isLogged`，新增方法 `setLoginState(accountId, providerId, displayName, avatarUri, loginTime)`、`clearLoginState()`、`getCurrentProviderId(): string`、`isLogged(): boolean`、`getAccountId(): string`、`getDisplayName(): string`、`getAvatarUri(): string`。验证：PrefKey 命名与现有风格一致，方法读写底层 preferences 正确

## 8. 启动初始化与登录态恢复

- [x] 8.1 修改 `entry/src/main/ets/entryability/EntryAbility.ets`（或等价入口）：`onCreate` 中初始化 `AccountService`，`registerProvider(new HuaweiAuthProvider())`；读 `AppPreferences.isLogged()`，若为 true 则服务置已登录态供 UI 直接展示。验证：启动后 UI 直接显示已登录态（不重新授权），provider 注册在 UI 构建前完成

## 9. UI 集成：设置页账号分组

- [x] 9.1 修改 `entry/src/main/ets/pages/settings/builders/HomeSettingBuilder.ets` 账号分组（当前 lines 118-129）：读登录态 `isLogged`，未登录态渲染 `HuaweiAuthProvider.huaweiLoginButtonBuilder`（独立 `@Builder`，不走 `SettingListItem`），不展示 VidAll Pro/全平台可用/退出登录；已登录态保留现有结构。验证：未登录态只看到华为登录按钮，已登录态看到原有三行
- [x] 9.2 已登录态「退出登录」项接通 `AccountService.logout()`：点击 → 调用 logout → 成功后 UI 自动回未登录态（由 `@Local`/store 驱动刷新）。验证：点击退出后账号分组切换为未登录态，不报错
- [x] 9.3 登录成功后 UI 自动刷新为已登录态：`HuaweiAuthProvider.login()` → `AccountService.loginWith` 成功 → 通知 store/`@Local` → 账号分组重渲染。验证：授权成功后无需手动刷新，账号分组自动展示已登录

## 10. 自检清单（验证阶段）

- [x] 10.1 编译通过：`assembleHap` 任务 BUILD SUCCESSFUL，无 ArkTS 报错（重点核查 `build()` 内无变量声明、`catch` 无类型注解、对象字面量有显式类型、无 `any`/`unknown`）。验证：hvigor 退出码 0 且日志含 BUILD SUCCESSFUL
- [ ] 10.2 真机华为授权登录：局域网电视安装后，设置页未登录态点击华为登录按钮 → 拉起华为授权 → 同意后账号分组切换已登录态。验证：UI 状态切换成功，无异常
- [ ] 10.3 Cloud DB 双表写入验证：登录成功后在 AGC 控制台「云数据库 → 数据查询」查 `UserAccount` 与 `AccountBinding` 两表，确认有对应记录（accountId/bindingId/platform='huawei'/platformUserId=unionID）。验证：两表各有 1 条记录，字段值正确
- [ ] 10.4 退出登录回退：已登录态点退出登录 → 账号分组回未登录态 → Cloud DB 两表记录仍在（控制台查询确认）。验证：UI 回未登录，Cloud DB 记录未删
- [ ] 10.5 重启登录态恢复：已登录态杀进程重启 App → 设置页账号分组直接显示已登录态（不重新拉起华为授权）。验证：重启后无需授权即已登录
- [ ] 10.6 失败处理：未登录态点华为登录 → 在华为授权页取消 → UI 回未登录态，不写 Cloud DB，提示失败。验证：取消后 UI 状态正确，控制台无新增记录
- [x] 10.7 ArkTS 护栏 lint：全文核查 `services/account/` 与 `db/models/` 下文件无 `any`/`unknown`/`catch(e: X)`/`build()` 内变量声明等违规。验证：grep 无命中违规模式
