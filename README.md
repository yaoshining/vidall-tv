# VidAll TV

一款面向家庭大屏场景的 HarmonyOS TV 端视频播放器，支持通过 WebDAV 挂载远程影音库，提供媒体元数据刮削、字幕管理与多轨道切换能力。

---

## 功能特性

| 功能 | 说明 |
|---|---|
| 🎬 视频播放 | AVPlayer 主链 + Native 实验后端 + IJKPlayer 兜底，支持 mp4/mkv 等主流格式 |
| 🌐 WebDAV 文件源 | 基于 libcurl 的 HTTPS WebDAV，支持 PikPak、群晖、Alist 等 |
| 🔍 视频扫描 | 递归扫描配置目录，自动去重，支持深度限制 |
| 🎭 元数据刮削 | 接入 TMDB API，自动匹配海报、简介、类型、年份 |
| 💬 字幕支持 | 内嵌字幕轨道切换 + 外挂 SRT/ASS 字幕，支持延迟调节 |
| 🎵 音轨切换 | 多音频轨道实时切换，显示语言与编码信息 |
| 🏠 TV 端交互 | 遥控器焦点导航，大屏排版优化 |

---

## 技术架构

```
┌─────────────────────────────────────────────┐
│              ArkTS UI 层                    │
│  pages/  components/  utils/  lib/          │
└──────────────────┬──────────────────────────┘
                   │ NAPI
┌──────────────────▼──────────────────────────┐
│           C++ Native 层                     │
│  vidall_core_player_napi.cpp                │
│  ├── AVPlayer 控制（XComponent 渲染）       │
│  ├── Native backend（OH_AVPlayer/FFmpeg/EGL）│
│  ├── ffprobe  媒体信息探测                  │
│  ├── webdavRequest  libcurl HTTPS 请求      │
│  └── downloadToFile  libcurl 文件下载       │
└──────────────────┬──────────────────────────┘
                   │
        libffmpeg.so / libcurl.so
```

### 播放器分层

```
VideoPlayerController (ArkTS)
  ├── AVPlayerAdapter      ← HarmonyOS 原生，主链
  ├── VidAllPlayerAdapter  ← Native 实验后端（AVPlayer 接管 + FFmpeg/EGL 回退）
  └── IjkPlayerAdapter     ← IJKPlayer，兜底
```

### WebDAV 请求链

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
│           │   ├── VidAllPlayerAdapter.ets
│           │   └── IjkPlayerAdapter.ets
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
│               └── FfprobeUtil.ets
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

WebDAV 连接默认使用 `allow_self_signed` 策略（跳过证书验证），兼容家庭 NAS、代理环境与自签名证书。

若需要严格校验（企业场景），在文件源配置中设置：

```json
{ "tlsCertPolicy": "strict" }
```

TLS 错误会记录审计日志，可通过以下命令提取：

```bash
hdc shell hilog | grep VidAll_TLS_Audit
```

---

## Native 后端当前状态

当前播放器默认仍以 `AVPlayer` 为主链，`native` 后端用于承接更可控的播放路径与格式兼容验证。

- `native + AVPlayer` 路径已完成 XComponent 接管，支持真实出画、`pause / play / seek` 与时间轴回调
- `native + FFmpeg` 路径已完成 demux、解码、OpenGL ES 渲染、`OH_AudioRenderer` 送显与基础字幕桥接
- Native 内嵌字幕已实现：可枚举、可切换、可显示
- `native + FFmpeg` 当前仍是**软解视频 + CPU `sws_scale` 转换 + GLES 贴图**，4K/10bit 片源吞吐仍偏紧
- `native + FFmpeg` 运行时音轨切换已拆分到 `#55`，不再阻塞 `#48` 收口
- 下一阶段主线为 `#50`：在保留 FFmpeg 容器与状态机控制的前提下，引入**硬解视频主路径 + 软解回退**

---

## 已知限制

| 问题 | 原因 | 状态 |
|---|---|---|
| Native 4K/10bit 片源偶发卡顿 | 当前为 FFmpeg 软解 + CPU `sws_scale` 路径，吞吐接近设备上限 | 后续转 #50 硬解主路径 |
| AVPlayer 无法直接播放 AC-3/DTS | AVPlayer 不内置 AC-3/DTS 解码器；需走 Native/FFmpeg 路径兜底 | Native/FFmpeg 基础链路已打通，持续完善中 |
| Native/FFmpeg 运行时音轨切换未完成 | 当前 FFmpeg 子路径仍以固定默认音轨运行为主，完整切轨能力已拆到 `#55` | 规划中 |
| SMB/NFS 文件源 | 尚未实现 | Phase 2 |
| AVMetadataExtractor 不支持远程 URL | API 20 起才有 `setUrlSource` | 待 SDK 升级 |
| 帧率显示偶有 ×100（如 2397） | AVPlayer 内部单位问题 | 已在 VideoInfoUtil 修正 |

---

## 开发与测试

### 本地单元测试（不需要设备）

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
