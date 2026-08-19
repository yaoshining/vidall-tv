# video-server-management Specification

## Purpose
让用户能够添加、编辑、删除并查看各类影视服务器（Jellyfin / Emby / Plex），配置信息中的敏感凭据加密持久化。
## Requirements
### Requirement: 添加影视服务器入口与类型选择
系统 SHALL 在顶部栏「添加/修改文件源」入口之后提供一个「添加影视服务器」入口；点击后 SHALL 展示一个包含 Jellyfin、Emby、Plex 三种服务器类型的选择弹层。

#### Scenario: 从顶部栏进入添加弹层
- **WHEN** 用户点击顶部栏「添加影视服务器」按钮
- **THEN** 出现包含 Jellyfin、Emby、Plex 三项的选择弹层

#### Scenario: 选择服务器类型进入配置表单
- **WHEN** 用户在弹层中选择某一类型（Jellyfin / Emby / Plex）
- **THEN** 出现对应该类型的配置表单

### Requirement: 配置并保存 Jellyfin / Emby 服务器
系统 SHALL 允许用户为 Jellyfin / Emby 服务器填写名称、协议、服务器地址、端口、可选基础路径，以及认证方式（API Key 或用户名 + 密码），并通过测试连接与保存完成添加。

#### Scenario: 使用 API Key 保存 Jellyfin 服务器
- **WHEN** 用户填写名称、地址与 API Key，并点击保存
- **THEN** 服务器被持久化，并在「影视服务器」标签页与设置列表中可见

#### Scenario: 使用用户名密码保存 Emby 服务器
- **WHEN** 用户填写名称、地址、用户名与密码，并点击保存
- **THEN** 服务器被持久化，密码以加密形式存储

#### Scenario: 必填字段缺失时阻止保存
- **WHEN** 用户未填写名称或服务器地址即点击保存
- **THEN** 系统提示缺失字段，且不保存该服务器

### Requirement: 配置并保存 Plex 服务器
系统 SHALL 允许用户为 Plex 服务器填写名称、协议、服务器地址、端口与 X-Plex-Token，并通过测试连接与保存完成添加。

#### Scenario: 保存 Plex 服务器
- **WHEN** 用户填写名称、地址与 X-Plex-Token，并点击保存
- **THEN** 服务器被持久化，Token 以加密形式存储，并在服务器列表中可见

### Requirement: 测试连接
系统 SHALL 在保存前支持「测试连接」，调用对应服务器类型的接口校验服务可达性与认证凭据，并给出成功或可读的失败提示（鉴权失败 / 超时 / 连接拒绝 / 证书错误）。

#### Scenario: 测试连接成功
- **WHEN** 用户填写正确的服务器地址与凭据并点击「测试连接」
- **THEN** 页面出现「连接成功」提示

#### Scenario: 认证失败
- **WHEN** 用户提供错误凭据并点击「测试连接」
- **THEN** 系统提示鉴权失败，且不保存该配置

### Requirement: 影视服务器列表展示
系统 SHALL 在「影视服务器」标签页以左右两列各占 50% 的网格展示所有已添加的服务器，每项显示服务器图标、名称与类型。

#### Scenario: 展示已添加的服务器
- **WHEN** 存在一台或多台已添加的影视服务器
- **THEN** 标签页以两列网格展示每台服务器的图标、名称与类型

#### Scenario: 无服务器时显示空态
- **WHEN** 不存在任何影视服务器
- **THEN** 标签页显示「暂无服务器」空态与添加引导

### Requirement: 编辑影视服务器
系统 SHALL 允许用户对已添加的服务器进入编辑表单，回填原配置并保存更新。

#### Scenario: 编辑并更新服务器
- **WHEN** 用户在服务器列表中选择「编辑」并修改配置后保存
- **THEN** 服务器配置被更新，列表展示新信息

### Requirement: 删除影视服务器
系统 SHALL 允许用户删除已添加的服务器，删除前需二次确认。

#### Scenario: 确认删除服务器
- **WHEN** 用户在服务器列表中选择「删除」并确认
- **THEN** 该服务器从持久化存储与列表中移除

### Requirement: 凭据加密存储
系统 SHALL 对服务器配置中的敏感凭据（密码 / API Key / Plex Token）进行加密后落库，读取时解密。

#### Scenario: 敏感字段加密落库
- **WHEN** 保存一台含凭据的服务器
- **THEN** 数据库中存储的凭据字段为密文而非明文

