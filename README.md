# VidAll TV

VidAll TV 是一款面向 HarmonyOS TV 的家庭影视播放器与媒体管理应用，围绕远程文件源接入、媒体扫描、元数据整理、大屏浏览和视频播放构建。当前仓库已实现 WebDAV 与 SMB 文件源接入，并提供搜索、播放历史、详情页、字幕与音轨切换等能力。

## 当前状态

| 模块 | 状态 | 说明 |
|---|---|---|
| 🌐 WebDAV 文件源 | 已实现 | 支持连接测试、目录选择、递归扫描、流式播放 |
| 🗂️ SMB 文件源 | 已实现 | 支持连接测试、目录浏览、扫描、播放；播放链路使用 SMB 代理 |
| 🎞️ 媒体库 | 已实现 | 海报墙展示电影与剧集，支持详情页与继续观看 |
| 🎭 元数据刮削 | 已实现 | 接入 TMDB，用于电影、剧集、演员等信息展示 |
| 🔎 搜索 | 已实现 | 支持库内搜索与结果页浏览 |
| 🎬 播放器 | 已实现 | AVPlayer、IJKPlayer、原生桥接能力协同工作 |
| ✨ AI 画质增强 | 已实现 | 基于 VPE，当前仅在 AVPlayer 路径可用 |

## 功能概览

| 功能 | 说明 |
|---|---|
| 🧩 远程文件源 | 管理 WebDAV、SMB 文件源与扫描目录 |
| 🔍 视频扫描 | 递归扫描视频文件，支持深度限制、去重与目录状态跟踪 |
| 🏷️ 媒体整理 | 将本地扫描结果与 TMDB 元数据关联，生成电影与剧集视图 |
| 🖼️ 媒体库浏览 | 首页海报墙、详情页、文件浏览器、搜索结果页 |
| ▶️ 视频播放 | 支持播放、暂停、跳转、续播、字幕切换、音轨切换 |
| 🕘 播放历史 | 保存播放进度、继续观看入口、历史记录页 |
| 🛋️ 大屏交互 | 适配遥控器焦点导航与电视端布局 |

## 文件源协议支持

| 协议 | 状态 | 说明 |
|---|---|---|
| 🌐 WebDAV | 已实现 | 支持 HTTP/HTTPS、目录选择、远程扫描、鉴权请求 |
| 🗂️ SMB/CIFS | 已实现 | 支持连接测试、目录浏览、扫描、播放；部分链路经本地 HTTP 代理接入播放器 |
| 📦 NFS | 计划中 | 暂未实现 |
| ☁️ 其他网盘协议 | 计划中 | 预留扩展空间，当前仓库未落地 |

## 技术架构

项目主要由三层组成：

1. ArkTS UI 与业务层：负责页面、交互、状态管理、文件源配置、媒体库展示与播放控制。
2. 原生桥接层：通过 NAPI 暴露 WebDAV、SMB、播放器、VPE 等原生能力给 ArkTS 调用。
3. 本地数据层：使用关系型数据库保存文件源、扫描结果、刮削结果、搜索历史与播放进度。

当前关键实现包括：

- WebDAVClient：远程 WebDAV 请求、目录读取、播放 URL 构建
- SMBClient：SMB 连接测试、目录浏览、SMB URL 构建
- VideoScannerUtil：按文件源与目录递归扫描视频
- VideoInfoUtil / FfprobeUtil：补充媒体信息探测与轨道信息整理
- VideoPlayerController：协调 AVPlayer、IJKPlayer、字幕桥接与 AI 画质增强
- FileSourceDatabase：管理 file_sources、videos、scrape_info、movies、tv_series、play_progress 等表

## 环境要求

| 项目 | 要求 |
|---|---|
| DevEco Studio | 5.x 及以上 |
| HarmonyOS SDK | 6.0.2（API 22），兼容 5.1.1（API 19） |
| 目标设备 | HarmonyOS TV 或兼容大屏设备 |

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/yaoshining/vidall-tv.git
cd VidAll_TV
```

### 2. 使用 DevEco Studio 打开工程

1. 打开 DevEco Studio。
2. 选择 File -> Open。
3. 选择项目根目录。
4. 等待 hvigor 同步完成。

### 3. 运行到设备

1. 连接 HarmonyOS TV 设备或模拟器。
2. 选择 entry 模块运行。
3. 首次启动后进入首页即可开始配置文件源。

### 4. 配置 TMDB API Key（可选）

应用内可通过“设置 -> 资源库 -> TMDB API Key”配置刮削所需的 API Key。未配置时，媒体库仍可使用本地扫描与基础播放能力。

### 5. 添加文件源

当前支持两类文件源：

- WebDAV：填写地址、端口、账号、密码并选择扫描目录
- SMB：填写主机、共享名、账号、密码并选择扫描目录

## 目录结构

```text
VidAll_TV/
├── docs/                             # 协议与设计文档
├── entry/
│   └── src/main/
│       ├── cpp/                      # C++ NAPI 与原生桥接
│       ├── ets/
│       │   ├── components/core/player/   # 播放器核心与字幕桥接
│       │   ├── db/                        # 数据库与实体模型
│       │   ├── lib/                       # WebDAV / SMB / 刮削客户端
│       │   ├── pages/                     # 首页、设置、搜索、详情、历史、播放器页面
│       │   └── utils/                     # 扫描、媒体信息、偏好设置等工具
│       └── resources/
├── entry/src/test/                  # 本地单元测试
├── package/                         # 本地依赖 HAR 包
└── .plans/soft-copyright/           # 软著材料与导出脚本
```

## 数据存储

当前数据库围绕以下核心数据组织：

- file_sources：文件源配置
- file_source_directories：文件源对应扫描目录
- videos：扫描到的视频文件
- scrape_info：扫描结果与刮削数据的关联桥表
- movies / tv_series / tv_seasons / tv_episodes：媒体库实体
- play_progress / media_progress：播放进度与媒体级续播信息
- search_history：搜索历史

## 开发与测试

### 本地单测构建

```bash
zsh -f -c 'cd /Users/yaoshining/DevEcoStudioProjects/VidAll_TV && \
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && \
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
export HARMONY_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
--mode module -p module=entry@default \
-p unit.test.replace.page=../../../.test/testability/pages/Index \
-p product=default -p pageType=page -p isLocalTest=true -p unitTestMode=true \
-p buildRoot=.test UnitTestBuild --analyze=normal --parallel --incremental --daemon'
```

### 同步工程

```bash
zsh -f -c 'cd /Users/yaoshining/DevEcoStudioProjects/VidAll_TV && \
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && \
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
export HARMONY_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
--sync -p product=default --analyze=normal --parallel --incremental --daemon'
```

### 编译 HAP

#### 开发包（product=default）

开发调试使用，代理 Worker 指向 `localhost:8787`（需本地运行 `wrangler dev`）。

```bash
zsh -f -c 'cd /Users/yaoshining/DevEcoStudioProjects/VidAll_TV && \
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && \
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
export HARMONY_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
--mode module -p module=entry@default -p product=default assembleHap --analyze=normal --parallel --incremental --daemon'
```

#### 发布包（product=production）

正式发布使用，代理 Worker 指向 `https://os-proxy.vidall.app/v1`，需配置 release 签名。

```bash
zsh -f -c 'cd /Users/yaoshining/DevEcoStudioProjects/VidAll_TV && \
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && \
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
export HARMONY_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony && \
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
--mode module -p module=entry@default -p product=production assembleHap --analyze=normal --parallel --incremental --daemon'
```

> **注意**：`product=production` 使用 `release` signingConfig，需确保证书路径 `certs/release/` 下文件完整。

#### DevEco Studio 切换环境

Product > default（开发调试）或 production（正式发布）

#### 多环境配置说明

| 配置项 | default（开发） | production（发布） |
|--------|-----------------|-------------------|
| 签名 | debug key | release key |
| OpenSubtitles 代理 | `localhost:8787/v1` | `os-proxy.vidall.app/v1` |
| `AppEnv.IS_PRODUCTION` | `false` | `true` |

环境判断逻辑见 `entry/src/main/ets/config/AppEnv.ets`。

### OpenSubtitles Worker（Cloudflare）

Worker 代码位于 `proxy/opensubtitles-worker/`，对应两套环境：

| 命令 | 说明 |
|------|------|
| `npm run dev` | 本地开发，KV 模拟，监听 localhost:8787 |
| `npm run dev:remote` | 本地开发，连接真实 Cloudflare KV |
| `npm run deploy:production` | 部署到生产环境 |

首次部署步骤见 [proxy/opensubtitles-worker/README.md](proxy/opensubtitles-worker/README.md)。

## 相关文档

- [docs/webdav-libcurl.md](docs/webdav-libcurl.md)
- [docs/smb-protocol.md](docs/smb-protocol.md)
- [docs/metadata-scraping.md](docs/metadata-scraping.md)
- [.plans/soft-copyright/plan-softCopyrightExportSummary.md](.plans/soft-copyright/plan-softCopyrightExportSummary.md)

## 已知限制

| 问题 | 说明 |
|---|---|
| AC-3 / DTS 兼容性有限 | AVPlayer 对部分音频格式支持不足，个别资源需要回退或后续增强 |
| VPE 仅支持 AVPlayer 路径 | IJKPlayer 与 SMB 相关回退链路不走 VPE |
| SMB 媒体信息预探测能力有限 | 部分 SMB 资源的轨道信息依赖播放阶段或额外探测逻辑 |
| 运行效果依赖设备能力 | 不同电视设备在解码、VPE、字幕轨信息上存在差异 |

## 许可证

本项目当前以个人学习、家庭影音场景验证为主，未提供独立开源许可证文本。

