# build-env-injection Specification

## Purpose
定义构建期环境变量注入机制的通用契约：以 `build-profile.json5` 的 `buildProfileFields` 声明为可注入字段清单，按约定键名从 `local.properties` / 环境变量取值并在构建期写入，供 ArkTS 侧通过 `BuildProfile.<FIELD>` 读取。该机制仅用于注入客户端可见配置或受客户端约束的凭据。
## Requirements
### Requirement: buildProfileFields 声明即 schema

系统 SHALL 将 `build-profile.json5` 中 `buildOption.arkOptions.buildProfileFields` 声明的字段视为唯一的可注入字段清单，注入机制 SHALL 只处理该清单内的字段。声明的空默认值（如 `"FOO": ""`）SHALL 随仓库提交。

#### Scenario: 已声明字段作为注入候选
- **WHEN** `buildProfileFields` 声明了字段 `FOO`
- **THEN** 构建期注入机制将该字段识别为可注入候选

#### Scenario: 未声明字段不注入
- **WHEN** `local.properties` 或环境变量存在 `app.env.X` / `APP_ENV_X`，但 `X` 未在 `buildProfileFields` 声明
- **THEN** 系统 SHALL NOT 将 `X` 注入 `BuildProfile`

### Requirement: buildProfileFields 仅承载客户端可见配置

`buildProfileFields` 及本注入机制 SHALL 仅用于注入客户端可见的配置或受客户端约束的凭据（如客户端直接使用的 Caller Key）。注入值会随客户端构建产物发布，因此系统 SHALL NOT 注入服务端私有密钥（如签名私钥、数据库密码、仅服务端持有的 API Key）。

#### Scenario: 注入客户端可见配置
- **WHEN** 声明的字段为客户端直接使用的配置或凭据（如 Caller Key）
- **THEN** 系统允许通过本机制注入

#### Scenario: 禁止注入服务端私有密钥
- **WHEN** 某字段的值属于仅服务端应持有的私有密钥
- **THEN** 该字段 SHALL NOT 被声明到 `buildProfileFields`
- **AND** 系统 SHALL NOT 通过本机制将其注入客户端构建产物

### Requirement: 从 local.properties 的 app.env.<FIELD> 读取

对每个已声明的字段 `<FIELD>`，系统 SHALL 从 gitignored 的 `local.properties` 读取键 `app.env.<FIELD>` 的值（不存在、为空或解析失败按未配置处理）。

#### Scenario: local.properties 提供字段值
- **WHEN** `local.properties` 存在 `app.env.FOO=bar` 且 `FOO` 已声明
- **THEN** 构建期将 `BuildProfile.FOO` 注入为 `bar`

#### Scenario: local.properties 无该键
- **WHEN** `local.properties` 不存在 `app.env.FOO` 键
- **THEN** 系统按未配置处理，回退到环境变量（若配置）

### Requirement: 从环境变量 APP_ENV_<FIELD> 读取

对每个已声明的字段 `<FIELD>`，系统 SHALL 从环境变量 `APP_ENV_<FIELD>` 读取其值（未定义或为空按未配置处理）。

#### Scenario: 环境变量提供字段值
- **WHEN** 环境变量 `APP_ENV_FOO=bar` 且 `FOO` 已声明
- **THEN** 构建期将 `BuildProfile.FOO` 注入为 `bar`

#### Scenario: 环境变量未定义
- **WHEN** 环境变量 `APP_ENV_FOO` 未定义
- **THEN** 系统按未配置处理，保留空默认值

### Requirement: 注入优先级为 local.properties → 环境变量 → 空默认值

对每个已声明的字段 `<FIELD>`，系统 SHALL 按 `local.properties` 的 `app.env.<FIELD>` → 环境变量 `APP_ENV_<FIELD>` → 空默认值的顺序解析；首个非空值生效。

#### Scenario: 两侧都配置时 local.properties 优先
- **WHEN** `local.properties` 的 `app.env.FOO` 与环境变量 `APP_ENV_FOO` 均配置了非空值
- **THEN** `BuildProfile.FOO` 取 `local.properties` 的值

#### Scenario: 都未配置时保留空默认值
- **WHEN** `local.properties` 与环境变量均未提供 `FOO` 的非空值
- **THEN** `BuildProfile.FOO` 保持 `build-profile.json5` 中的空默认值
- **AND** 构建仍成功，不因缺失该值而失败

### Requirement: 字段名原样拼接且大小写敏感

系统 SHALL 以声明的字段名原样拼接注入键名：`local.properties` 键为 `app.env.` + `<FIELD>`，环境变量名为 `APP_ENV_` + `<FIELD>`，不改变字段名大小写。

#### Scenario: 大小写敏感拼接
- **WHEN** 声明字段为 `SUBHUB_API_KEY`
- **THEN** 读取 `local.properties` 的 `app.env.SUBHUB_API_KEY` 与环境变量 `APP_ENV_SUBHUB_API_KEY`

