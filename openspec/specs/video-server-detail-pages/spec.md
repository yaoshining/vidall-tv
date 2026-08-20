# video-server-detail-pages Specification

## Purpose
为影视服务器（Jellyfin / Emby / Plex）提供与文件源一致的详情页体验：电影 / 剧集详情页、季详情页、人员详情页，以及媒体库视频列表页；并通过抽离公用展示组件，避免文件源与服务器详情页的样式多处维护。
## Requirements
### Requirement: 剧集/电影详情页展示与播放
系统 SHALL 为服务器条目提供详情页：展示标题、年份、评分、时长、类别、简介、季列表、演职人员；续播卡片展示「接下来」单集（SxxExx 副标题、进度条、继续播放/开始播放），点击播放 SHALL 播放该单集而非直接串流剧集条目。

#### Scenario: 展示剧集详情
- **WHEN** 用户从服务器首页「接下来/最近添加的」进入某剧集详情页
- **THEN** 展示标题、年份、评分、类别、简介、季列表、演职人员

#### Scenario: 续播卡片展示下一集与进度
- **WHEN** 剧集详情页已拉取「接下来」单集
- **THEN** 续播卡片展示该单集的 SxxExx 副标题、进度条，并按是否有续播进度显示「继续播放」或「开始播放」

#### Scenario: 播放剧集详情页
- **WHEN** 用户在剧集详情页点击播放
- **THEN** 播放器播放「接下来」单集（有续播则从其续播位置起播），不黑屏、不直接串流 Series 条目

### Requirement: 季详情页展示与播放
系统 SHALL 为服务器季提供详情页：顶部 Hero 区展示剧名、季标题、年份、评分、总集数、类别、简介与「继续本季 / 从本季开始」按钮，并从季海报提取主色调作为页面背景；集列表支持 hover/focus 高亮、进度条、已看标记与操作按钮。

#### Scenario: 季详情页 Hero 信息
- **WHEN** 用户进入某季详情页
- **THEN** 顶部 Hero 区展示剧名、季标题、年份、评分、总集数、类别、简介，背景色取自季海报主色调

#### Scenario: 季详情页播放按钮
- **WHEN** 当前季存在未看完的续播进度
- **THEN** 主按钮显示「继续本季」；否则显示「从本季开始」

#### Scenario: 跨季继续上次观看
- **WHEN** 整剧的「接下来」单集位于其他季
- **THEN** 季详情页 Hero 区展示「继续上次观看 SxxExx」次级入口，点击后播放该跨季单集

#### Scenario: 集列表 hover/focus
- **WHEN** 用户在季详情页聚焦或悬停某一集
- **THEN** 该集行高亮，并展示进度条、已看标记与操作按钮（信息/已看/收藏/更多）

### Requirement: 人员详情页
系统 SHALL 允许从服务器详情页的演职人员列表点击头像进入人员详情页，展示照片、姓名、角色、生日、出生地、简介与参演作品。

#### Scenario: 点击演职人员头像
- **WHEN** 用户点击服务器详情页演职人员列表中的某位人员
- **THEN** 打开人员详情页，展示其照片、姓名、角色、简介与参演作品

#### Scenario: 演职人员头像展示
- **WHEN** 服务器详情页展示演职人员列表，且服务器提供人员头像
- **THEN** 头像通过服务器图片接口加载并展示

### Requirement: 公用详情展示组件
系统 SHALL 抽离文件源与影视服务器详情页共用的展示组件（Hero 区、季列表、集列表、演职人员、简介弹窗），使两类数据源使用同一套展示逻辑与样式。

#### Scenario: 共用组件渲染一致
- **WHEN** 文件源详情页与服务器详情页渲染同一区域（Hero / 季列表 / 集列表 / 演职人员 / 简介弹窗）
- **THEN** 两者使用同一公用组件，展示样式一致

### Requirement: 媒体库视频列表页
系统 SHALL 为每个媒体库提供视频列表页：以一行 7 个的竖版海报网格展示，按每页 100 条滚动加载，点击列表项进入对应详情页，背景色与媒体库首页一致。

#### Scenario: 从媒体库卡片进入列表页
- **WHEN** 用户点击媒体库首页「我的媒体库」中的某媒体库卡片
- **THEN** 打开该媒体库的视频列表页

#### Scenario: 网格布局与分页
- **WHEN** 视频列表页展示媒体库内容
- **THEN** 以一行 7 个的竖版海报网格展示，每页加载 100 条，滚动到底部自动加载下一页

#### Scenario: 点击列表项
- **WHEN** 用户点击视频列表页中的某一条目
- **THEN** 进入该条目的详情页

### Requirement: 服务器缩略图
系统 SHALL 对服务器首页「继续观看/接下来」的剧集缩略图使用剧集 Thumb（16:9 横版）。

#### Scenario: 继续观看/接下来缩略图
- **WHEN** 服务器首页展示「继续观看」或「接下来」分区的剧集条目
- **THEN** 缩略图使用该剧集的 Thumb 横版图（16:9），而非集截图

### Requirement: 最近添加接口（Jellyfin / Emby）
系统 SHALL 对 Jellyfin / Emby 服务器首页的「最近添加」分区通过 /Users/{userId}/Items/Latest 接口拉取，按媒体库拆分展示。

#### Scenario: Jellyfin / Emby 最近添加
- **WHEN** Jellyfin / Emby 服务器首页展示「最近添加的 X」分区
- **THEN** 通过 GET /Users/{userId}/Items/Latest?ParentId={libraryId}&Limit=16&Fields=PrimaryImageAspectRatio,Overview 接口拉取，请求头携带 X-Emby-Authorization（含 API Key 或用户名密码），按 ParentId 对应的媒体库拆分展示

### Requirement: 最近添加接口（Plex）
系统 SHALL 对 Plex 服务器首页的「最近添加」分区通过 /library/sections/{id}/recentlyAdded 接口拉取，请求携带 X-Plex-Token 认证，并将 MediaContainer.Metadata 映射为统一的媒体条目模型。

#### Scenario: Plex 最近添加
- **WHEN** Plex 服务器首页展示「最近添加的 X」分区
- **THEN** 通过 GET /library/sections/{sectionKey}/recentlyAdded?X-Plex-Token={token}&X-Plex-Container-Start=0&X-Plex-Container-Size=16 接口拉取，响应中的 MediaContainer.Metadata 数组映射为统一条目模型（title→标题、year→年份、thumb→缩略图、ratingKey→条目 ID、type→类型 movie/season/show），按 sectionKey 对应的媒体库拆分展示

#### Scenario: Plex 分页加载
- **WHEN** 用户滚动到 Plex「最近添加」分区底部
- **THEN** 递增 X-Plex-Container-Start 并保持 X-Plex-Container-Size=16 请求下一页
