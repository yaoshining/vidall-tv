## Why

设置页「账号」分组当前只有「已登录」占位（VidAll Pro / 全平台可用 / 退出登录），没有真实账号体系支撑：用户无法登录，「退出登录」也没有实际行为。需要接入华为账号授权登录，拿到 `unionID` 作为跨应用统一用户标识，并通过云数据库（Cloud DB）持久化用户信息，为后续跨端同步、个性化、会员权益等能力打基础。同时，架构需从一开始就支持接入更多认证平台（如微信）与一个账号绑定多个平台身份。

## What Changes

- 新增「未登录」状态 UI：在设置页「账号」分组中展示华为账号一键登录按钮（`LoginWithHuaweiIDButton`），替代当前的固定占位；未登录态按已注册的 provider 列表渲染按钮（当前仅华为，架构支持后续扩展）。
- 新增 `AuthProvider` 可插拔抽象：平台登录能力以接口注册，新增平台只需实现 `AuthProvider` 并注册，不改账号服务核心；首发实现 `HuaweiAuthProvider`。
- 新增一账号多绑定数据模型：Cloud DB 两张对象类型——`UserAccount`（账号主体）与 `AccountBinding`（平台绑定，一账号多条），同一 `(platform, platformUserId)` 全局唯一。
- 新增登录流程：用户点击登录按钮 → 拉起华为账号授权 → 成功回调拿到 `unionID`（及 `openID`、昵称、头像）→ 查/建 `AccountBinding` 与 `UserAccount` → 写入 Cloud DB → 本地持久化登录态 → UI 切换到「已登录」。
- 接通「退出登录」：点击后当前 provider 注销登录态、清空本地登录信息、UI 回到「未登录」状态（Cloud DB 的 `UserAccount` / `AccountBinding` 记录保留，作为历史数据与再登录命中）。
- 复用现有「已登录」占位 UI：登录成功后直接展示当前的 VidAll Pro / 全平台可用 / 退出登录结构，无需重新设计。
- 接入 AGC 云开发：依赖 `agconnect-services.json`（已存在）与 `@kit.CloudFoundationKit` 的 `cloudDatabase` 能力，需要在 AGC 控制台开启 Cloud DB 并定义 `UserAccount` + `AccountBinding` 两个对象类型。

## Capabilities

### New Capabilities

- `huawei-account-login`: 多平台可扩展的账号登录能力，覆盖 `AuthProvider` 可插拔抽象、华为首发 provider、一账号多绑定数据模型、未登录/登录中/已登录三态 UI、`LoginWithHuaweiIDButton` 授权、`unionID` 获取与 Cloud DB 持久化、本地登录态管理、退出登录全流程、登录态恢复。

### Modified Capabilities

<!-- 无现有 capability 的需求变更，本次为全新能力，不修改既有 spec。 -->

## Impact

- **受影响代码**：
  - `entry/src/main/ets/pages/settings/builders/HomeSettingBuilder.ets`：账号分组按登录态切换 UI，接通退出登录。
  - 新增 `services/account/`：账号服务层（`AuthProvider` 接口、`providers/HuaweiAuthProvider`、`AccountService` 编排 + provider 注册表、`repo/CloudAccountRepository` + `repo/CloudBindingRepository`）。
  - 新增 `db/models/UserAccount.ets` + `db/models/AccountBinding.ets`：Cloud DB 对象类型（`cloudDatabase.DatabaseObject` 子类）。
  - 扩展 `utils/AppPreferences` 的 `PrefKey`：本地登录态（accountId、当前 providerId、昵称、头像、登录时间、是否登录）。
- **依赖**：`@kit.AccountKit`（`LoginWithHuaweiIDButton` / `loginWithHuaweiID` / `signOut`）、`@kit.CloudFoundationKit`（`cloudDatabase`）均为 HarmonyOS 系统 Kit，无需新增 oh-package / npm 依赖。
- **AGC 控制台配置**：开启华为账号认证、开启 Cloud DB、创建 `UserAccount` + `AccountBinding` 两个对象类型与存储区、导出 schema 入 `entry/src/main/resources/rawfile/`。
- **`agconnect-services.json`**：已存在且含 `client_id` / `app_id` / `oauth_client`，无需改动（Cloud DB 服务在控制台侧开启，不写入此文件）。
- **签名与权限**：登录与 Cloud DB 调用依赖正确的 AGC 签名配置（`build-profile.json5` 已有 default / production 签名），无需新增系统权限。
