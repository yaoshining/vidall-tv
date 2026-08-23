## Why

首次使用且媒体库尚无内容时，首页仍展示“继续播放”、统计与扫描区域，既造成无效信息干扰，也没有清楚告诉用户如何开始。需要将空媒体库收敛为单一引导空态，并提供可直接操作的配置入口。

## What Changes

- 当当前文件源媒体库没有可展示内容时，展示媒体库空态并隐藏“继续播放”和媒体分区；保留底部统计、扫描与刮削区域，确保尚未自动刮削时仍可手动建立媒体库。
- 优化空态标题与说明，明确引导用户添加文件源或连接影视服务器以建立媒体库。
- 在空态中增加“添加文件源”和“添加影视服务器”两个遥控器可聚焦入口，并分别直达对应设置页面。
- 保持加载态、有媒体内容状态及影视服务器现有错误态和内容展示行为不变。

## Capabilities

### New Capabilities

- `media-library-empty-state`: 定义媒体库无可展示内容时的精简空态、配置引导及 TV 焦点交互。

### Modified Capabilities


## Impact

- 主要影响 `entry/src/main/ets/pages/home/tabs/MediaLibraryTab.ets` 的文件源媒体库分支、空态组件和设置页导航。
- 复用现有 `SettingsPage`、`SettingType.FILE_SOURCE` 与 `SettingType.ADD_VIDEO_SERVER`，不新增依赖、Cloud DB 模型或外部 API。
- 需要验证首次空库、加载中、有媒体内容及遥控器焦点/点击导航场景。
