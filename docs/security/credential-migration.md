# 凭据系统密钥保护与迁移

基线：`main` 的 `6af67e19ea88c635490d92c155297e1c0ef3085d`（包含 PR #338）。独立分支 `codex/huks-credential-migration`，等待独立验收，不自动合并。

## 问题与范围

原 `CryptoUtil` 使用公开固定字符串派生 AES-256-CBC 密钥，密文没有完整性校验。文件源解密失败会保留密文供连接调用；影视服务器失败字段被替换为空，编辑保存可能擦除凭据。

本次只调整凭据存储、读取失败传递、必要的连接入口检查、设置页恢复提示及隔离测试。不调整播放器或文件浏览器实现。

- `FileSourceDao`：保护 `password`。
- `VideoServerDao`：保护 `password / apiKey / token`。
- 全部 CryptoUtil 调用收敛到 CredentialStorage；旧算法仅存在于 LegacyCredentialReader 的解密路径。
- WebDAVAdapter、SMBAdapter、JellyfinClient、PlexClient、SourceAdapterService、MissingMediaVerifier、首页文件源/媒体库及设置目录选择入口使用 `parseCredentialConfig`，在构造连接前拒绝读取失败的配置。
- 三个编辑页保留可编辑的非敏感配置，显示失败字段和恢复提示，重新进入编辑会强制刷新。SMB 连接测试也拒绝读取失败后的空密码。

## 格式与密钥生命周期

新格式：`v2:<Base64 12-byte nonce>:<Base64 ciphertext || 16-byte tag>`。AES-256-GCM 在 HUKS 内执行，密钥不导出；每次加密使用平台安全随机数生成 nonce。AAD 为 `vidall:v2:<table>:<field>`，绑定版本、表与字段。加密内容为 UTF-8 `1 + plaintext`，该内部前缀也受认证，用于可靠支持空串。格式与 Base64 均作严格检查。

应用共享 HUKS 别名 `vidall.credentials.aesgcm.v2`，它是标识而非密钥材料。首次非空新写入查询后生成；同一运行时合并并发创建请求，后续复用已有密钥。不使用群组密钥或用户生物认证能力。明确使用 API 11 起的 `HUKS_AUTH_STORAGE_LEVEL_DE`，避免 API 23 前后默认存储级别变化影响密钥查找。

读取缺失、失效或错误密钥时不会生成/覆盖密钥，不降级为明文或旧算法。不自动删除或轮换共享密钥；删除单个数据源及级联删除均只操作数据库。只有用户输入新的非空凭据进行保存时，才可能为缺失别名生成新密钥；它无法恢复已失去原密钥的旧密文，旧字段仍保留，必须逐项重新输入。

此方案保护静态存储；已授权的应用进程仍能在连接时使用解密后的凭据。旧 CBC 数据没有认证，历史上已被修改但仍能通过 CBC 解密的数据无法追溯检测。

## 可重试迁移与保存

1. 读取并保留原始 `config_json` 快照，逐字段解密；没有凭据与读取失败分开表示。
2. 任何敏感字段失败，返回配置中该字段为空并附 `_credentialReadFailures` 字段名列表；数据库整行不迁移，连接入口拒绝使用该配置。
3. 全部字段解密成功后，生成全部所需 v2 密文；最后只以 `id AND config_json = 原始快照` 条件更新配置列。
4. 加密失败或数据库拒绝更新保留原值；并发编辑导致匹配 0 行也不覆盖，后续读取重试。已是 v2 的行不重复迁移。
5. 用户保存先读取数据库快照，生成新密文后同样条件更新；0 行视为冲突，要求重新加载重试。不会在数据库事务中等待 HUKS。
6. 保存中的非空新值统一加密。空值/省略表示保留已有凭据，不能隐式清除；成功读取的旧值会升级，失败旧值原样保留。该约定也覆盖“表单读取失败，保存时密钥已恢复”的竞态。

恢复方法：退出并重新进入编辑页重试读取；或按提示逐项输入新凭据保存。需要清除整条配置时使用既有删除数据源功能。此版本不提供把现有凭据清空的单字段按钮。对保留失败字段的保存，不宣称凭据已恢复；重新读取仍显示失败状态。

## 备份、导入与回滚

工程仅有 `EntryBackupAbility` 和允许系统备份恢复的配置，未发现应用内数据源导入/导出实现。系统备份配置保持不变，数据库密文不被清空；本次没有导出 HUKS 密钥的能力。

- 原设备、原应用密钥仍存在：v2 数据应继续由同一别名读取。
- 跨设备、卸载重装或密钥丢失后恢复数据库：不能假定系统会恢复原密钥。读取失败保留密文，设置页明确提示跨设备需重新输入，不自动以空密码连接。
- 直接把旧/v2 密文作为 DAO 的“新密码”导入会被拒绝，防止二次加密；加密备份不能冒充明文编辑数据。
- 已验证隔离数据库下的密钥缺失/替换与恢复式读写；未执行系统备份向导、真正跨设备传输或卸载生产应用。

**回滚限制：**旧版本不认识 v2，且原 FileSourceDao 可能把解密失败的密文继续向连接端传递。因此迁移后不能直接降级运行旧版本。应保留本次读取/失败保护层进行前向修复；确需降级，只能在受控恢复流程下恢复迁移前数据库快照，并评估会丢失快照之后的编辑。不要删除 HUKS 密钥、清空应用数据或把所有凭据重新写成固定密钥格式作为回滚手段。旧备份本身仍受旧算法弱点影响。

## 官方兼容性依据

通过 `devecocli docs` 查询并读取：

- `开发指南/安全/Universal_Keystore_Kit_密钥管理服务/本地密钥管理/密钥使用/加密_解密/加密_解密介绍及算法规格/huks-encryption-decryption-overview`：TV 的 AES/GCM/NoPadding 从 API 8 支持。
- 同目录 `加解密_ArkTS/huks-encryption-decryption-arkts`：使用 initSession/finishSession，解密指定 NONCE、AE_TAG，密文尾部 16 字节为认证标签。
- `开发指南/安全/Universal_Keystore_Kit_密钥管理服务/本地密钥管理/其他操作/查询密钥是否存在/查询密钥是否存在_ArkTS/huks-check-key-arkts`：hasKeyItem 查询。
- 本机官方 SDK `@ohos.security.huks.d.ts`：generateKeyItem/initSession/finishSession 从 API 9；hasKeyItem、存储级别枚举/标签从 API 11。`@kit.UniversalKeystoreKit` 可用于本项目最低 API 19。未使用 API 23 群组能力。

项目 `compatibleSdkVersion=5.1.1(19)`、`targetSdkVersion=6.0.2(22)` 均未变更。接口声明与构建兼容性不等于 API 19 实机通过。

## 执行证据

平台：`Huawei_TV_6_1_1`，HarmonyOS 6.1.1(24) Beta1，TV 模拟器 `127.0.0.1:5555`。主模块 `entry` 已存在，本次仅安装 `entry_test`。测试直接实例化两个生产 DAO 和生产 CredentialCipher，注入独立 HUKS 别名；真实调用 HUKS 和 relationalStore。仅失败注入/并发调度由测试 codec 控制，不用主机加密或数据库 mock 替代。

测试数据库前缀 `VIDALL_CREDENTIAL_TEST_`，密钥别名前缀 `vidall.credential.test.`；每例 finally 关闭并删除自己的数据库及密钥，不连接生产库、不更改全局数据库名、不读取真实凭据。

构建与入口：

```sh
devecocli build --modules entry
devecocli build --modules entry@ohosTest
# devecocli 没有 aa test/shell 子命令，执行器使用同一 SDK 的 hdc：
hdc -t 127.0.0.1:5555 shell aa test -b com.yao.vidalltv -m entry_test \
  -s unittest OpenHarmonyTestRunner -s CREDENTIAL_STORAGE_SMOKE true -s timeout 90000
```

最终 **21/21 通过，0 failure、0 error、0 ignore**。包括：随机性/Unicode/空串/复用、篡改/错 AAD/未知版本/错误及缺失密钥；两个 DAO 的真实 CRUD、删除保留共享密钥、旧数据迁移及幂等、加密失败/数据库触发器失败/并发保存、失败字段保存保留、重新输入恢复、密钥缺失恢复式读写、密文导入拒绝、多敏感字段部分失败与全部字段迁移。

首轮 15/16 通过，空串边界报错；修复后重新构建并执行，没有把旧失败结果改绿。最终执行记录、完整逐例结果、现有严格门禁状态、源码摘要及 HAP 摘要在 [证据目录](credential-migration-evidence/)。`scripts/ci/test_gate.py` 和 CI workflow 均未修改；其主机回归 17/17 通过。平台测试不是主机 mock，也不代表完整项目 CI 或真机验收。

未验证：API 19 实机、硬件 TEE 安全强度/断电重启、系统备份向导和跨物理设备恢复、真实服务器连接、恢复提示的遥控器视觉验收，以及完整远端 CI。不得把这些边界写成已通过。PR 保持草稿，等待独立验收。
