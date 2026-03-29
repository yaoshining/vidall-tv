# VidAll TV

面向家庭大屏的 HarmonyOS TV 视频播放器。挂载 WebDAV 远程影音库，自动刮削元数据，原生支持内嵌字幕与多轨道切换，一遥控器搞定。

---

## 功能特性

| 功能 | 说明 |
|---|---|
| 🎬 视频播放 | AVPlayer 主链 + IJKPlayer 兜底，覆盖 mp4 / mkv 等主流格式 |
| 🌐 WebDAV 文件源 | 基于 libcurl 的 HTTPS WebDAV，兼容 PikPak、群晖、Alist 等 |
| 🔍 视频扫描 | 递归扫描配置目录，自动去重，支持深度限制 |
| 🎭 元数据刮削 | 接入 TMDB API，自动匹配海报、简介、类型、年份 |
| 💬 字幕 | 内嵌字幕（ASS/SRT，含简/繁体标注）优先 + 外挂 SRT/ASS/VTT 兜底，支持延迟调节，seek 后 ≤200ms 恢复 |
| 🎵 音轨切换 | 多音频轨道实时切换，显示语言与编码信息 |
| ✨ AI 画质增强 | 接入鸿蒙 VideoProcessingEngine（VPE），低/中/高三档，按需开关 |
| 🏠 TV 端交互 | 遥控器焦点导航，大屏排版优化 |

---

## 技术架构

整体分为 ArkTS UI 层与 C++ Native 层，通过 NAPI 桥接：

```
┌─────────────────────────────────────────────┐
│              ArkTS UI 层                    │
│  pages/  components/  utils/  lib/          │
└──────────────────┬──────────────────────────┘
                   │ NAPI
┌──────────────────▼──────────────────────────┐
│           C++ Native 层                     │
│  vidall_core_player_napi.cpp                │
│  ├── ffprobe  媒体信息探测                  │
│  ├── VPE     VideoProcessingEngine 画质增强 │
│  ├── webdavRequest  libcurl HTTPS 请求      │
│  └── downloadToFile  libcurl 文件下载       │
└──────────────────┬──────────────────────────┘
                   │
        libffmpeg.so / libcurl.so / libvideo_processing.so
```

### 播放器分层

```
VideoPlayerController (ArkTS)
  ├── AVPlayerAdapter         ← HarmonyOS 原生，主链
  │     └── VPE 画质增强管线（AVPlayer → VPE → XComponent）
  └── IjkPlayerAdapter        ← IJKPlayer，兜底

字幕适配层（统一接口 ISubtitleBridgeAdapter）
  ├── AvSubtitleBridgeAdapter   ← AVPlayer 内嵌 + 外置字幕
  ├── IjkSubtitleBridgeAdapter  ← ijk 内嵌字幕（onTimedText 实时回调，ASS/SRT）+ 外置字幕
  └── NoSubtitleBridgeAdapter   ← 无字幕回退
```

### VPE 画质增强管线

```
AVPlayer（解码输出）
  └──► VPE 输入 Surface（VideoProcessingEngine）
         └──► XComponent 显示
```

VPE 仅在 AVPlayer 后端下生效，IJKPlayer 路径不经过 VPE。

### WebDAV 请求链

所有 WebDAV 网络请求在 C++ 工作线程执行，不阻塞 UI：

```
WebDAVClient.sendViaNative()
  └── await webdavRequest(url, headers, tlsPolicy)
        └── C++ RunCurlRequest()（工作线程，不阻塞 UI）
```

---

## 环境要求

| 项目 | 要求 |
|---|---|
| HarmonyOS SDK | 6.0.2（API 22），兼容 5.1.1（API 19） |
| DevEco Studio | 5.x 及以上 |
| 目标设备 | HarmonyOS TV（支持 XComponent 与 Media Kit） |

---

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/yaoshining/vidall-tv.git
cd VidAll_TV
```

### 2. 配置 TMDB API Key（可选，用于元数据刮削）

在 `entry/src/main/resources/rawfile/` 下创建 `tmdb_config.json`：

```json
{ "api_key": "YOUR_TMDB_API_KEY" }
```

### 3. 用 DevEco Studio 打开并运行

1. 打开 DevEco Studio → **File → Open** → 选择项目根目录
2. 等待 hvigor 同步完成
3. 连接 HarmonyOS TV 设备或启动模拟器
4. 点击 **Run 'entry'**

### 4. 添加 WebDAV 文件源

1. 进入「设置」→「文件源管理」→「添加 WebDAV」
2. 填写服务器地址、用户名、密码（支持 http/https）
3. 选择要扫描的目录
4. 返回首页等待扫描完成

---

## 目录结构

```
VidAll_TV/
├── entry/
│   └── src/main/
│       ├── cpp/                          # C++ NAPI 层
│       │   ├── vidall_core_player_napi.cpp
│       │   └── types/libvidall_core_player_napi/
│       │       └── index.d.ts           # NAPI TypeScript 类型声明
│       └── ets/
│           ├── components/core/player/  # 播放器核心
│           │   ├── VideoPlayerController.ets
│           │   ├── AVPlayerAdapter.ets
│           │   ├── IjkPlayerAdapter.ets
│           │   ├── SubtitleBridgeAdapter.ets  # 统一字幕适配层
│           │   └── SubtitleRenderer.ets       # SRT/ASS/VTT 渲染
│           ├── db/                      # 数据库（RelationalStore）
│           │   └── FileSourceDatabase.ets
│           ├── lib/                     # 底层库
│           │   ├── WebDAVClient.ets     # WebDAV 客户端（libcurl）
│           │   └── ScrapeClient.ets     # TMDB 刮削客户端
│           ├── pages/                   # 页面
│           │   ├── home/                # 首页（媒体库、文件源）
│           │   ├── player/              # 播放器页面
│           │   ├── detail/              # 影片/剧集详情
│           │   └── settings/            # 设置页
│           └── utils/                   # 工具类
│               ├── VideoScannerUtil.ets
│               ├── VideoInfoUtil.ets
│               ├── FfprobeUtil.ets
│               ├── VpeEnhancerUtil.ets  # VPE 画质增强工具
│               └── DeviceCapabilityUtil.ets
└── entry/src/test/                      # 本地单元测试
    ├── List.test.ets                    # 测试套件入口
    ├── WebDAVClientUtils.test.ets       # TLS 工具函数测试（30 个用例）
    ├── ScrapeClient.test.ets
    └── ...
```

---

## 数据库模型

| 表 | 说明 |
|---|---|
| `file_sources` | 文件源配置（WebDAV 等） |
| `file_source_directories` | 每个文件源的扫描目录 |
| `videos` | 扫描到的视频文件 |
| `scrape_info` | 刮削元数据 |
| `movies` | 电影信息 |
| `tv_series` / `tv_seasons` / `tv_episodes` | 剧集信息 |
| `play_progress` | 播放进度记录 |

---

## TLS 与证书策略

WebDAV 连接默认使用 `allow_self_signed` 策略，兼容家庭 NAS、代理环境与自签名证书。企业场景如需严格校验，在文件源配置中指定：

```json
{ "tlsCertPolicy": "strict" }
```

TLS 错误会写入审计日志：

```bash
hdc shell hilog | grep VidAll_TLS_Audit
```

---

## 已知限制

| 问题 | 原因 | 状态 |
|---|---|---|
| AC-3/DTS 音频无法播放 | AVPlayer 不内置 AC-3 解码器 | 规划引入 FFmpeg NAPI |
| SMB/NFS 文件源 | 尚未实现 | Phase 2 |
| AVMetadataExtractor 不支持远程 URL | `setUrlSource` API 20 起才有 | 待 SDK 升级 |
| 帧率偶有 ×100 显示（如 2397） | AVPlayer 内部单位问题 | 已在 VideoInfoUtil 修正 |
| VPE 画质增强仅支持 AVPlayer | IJKPlayer 渲染机制与 VPE 管线不兼容 | 设计限制，不影响 ijk 正常播放 |
| AVPlayer 内嵌字幕元信息可能为空 | `getTrackDescription()` 返回字段不稳定 | 规划 #63 增强识别 |
| IJKPlayer 内嵌字幕 ASS Dialogue 行头部字节损坏 | `rect->ass` 在 HarmonyOS 上"Dialogue"关键字被乱码替换，已在 ArkTS 侧用 `": "` 定位绕过 | 已修复 |
| IJKPlayer 内嵌字幕简/繁体标注依赖 MKV title 字段 | 无 title 的轨道只显示语言名，无法区分简繁 | 设计限制 |

---

## 开发与测试

### 本地单元测试（无需设备）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony

# 首次运行前需生成测试模板文件（之后无需重复）
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/node_modules/@ohos/coverage/lib/src/commandLine/localTest/fileOperte.js

# 构建单测
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=entry@default \
  -p unit.test.replace.page=../../../.test/testability/pages/Index \
  -p product=default -p pageType=page -p isLocalTest=true -p unitTestMode=true \
  -p buildRoot=.test UnitTestBuild --parallel --incremental
```

### 编译验证

```bash
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=entry@default -p product=default assembleHap --parallel
```

---

## 许可证

本项目仅供个人学习与家庭使用。

