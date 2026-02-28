# Vidall TV

一个基于 OpenHarmony (HarmonyOS) 的电视媒体播放应用，支持本地和网络媒体文件的管理和播放。

## 主要特性

### 🎬 媒体管理
- 支持多种文件源（本地存储、WebDAV）
- 自动扫描和索引媒体文件
- TMDB 元数据刮削（海报、评分、剧情简介等）
- 电影和电视剧自动分类
- 合集归并（电视剧多集自动分组）

### 🔍 搜索与筛选 (Phase 1 - MVP)
- **搜索功能**: 支持片名关键词模糊匹配
- **多维度筛选**:
  - 类型筛选（全部/电影/电视剧）
  - 年份筛选
  - 类别筛选（动作、科幻、剧情等）
  - 评分筛选
- **灵活排序**: 最近更新/名称/年份/评分
- **组合筛选**: 支持多个筛选条件同时使用
- **实时响应**: 输入即搜索，带防抖优化
- **详细文档**: 查看 [分类与筛选功能说明](docs/FILTER_AND_SEARCH.md)

### 🎮 播放功能
- 支持多种视频格式
- 字幕支持
- 播放进度记录（计划中）
- 多音轨切换
- 播放控制条

### ⚙️ 设置管理
- 文件源配置
- TMDB API Key 配置
- 扫描目录管理
- 应用偏好设置

## 技术栈

- **开发语言**: TypeScript (ETS - Extended TypeScript)
- **框架**: OpenHarmony
- **状态管理**: @ObservedV2 + @Trace（响应式）
- **数据库**: 关系型数据库 (RDB)
- **UI 组件库**: @ibestservices/ibest-ui
- **图标库**: Lucide
- **测试框架**: @ohos/hypium

## 项目结构

```
vidall-tv/
├── entry/                          # 主应用模块
│   ├── src/
│   │   ├── main/
│   │   │   ├── ets/
│   │   │   │   ├── components/    # UI 组件
│   │   │   │   │   ├── core/      # 核心组件（播放器、文件浏览器）
│   │   │   │   │   └── common/    # 通用组件
│   │   │   │   ├── pages/         # 页面
│   │   │   │   │   ├── home/      # 首页（媒体库、文件源等）
│   │   │   │   │   ├── player/    # 播放器页面
│   │   │   │   │   ├── settings/  # 设置页面
│   │   │   │   │   └── files/     # 文件浏览页面
│   │   │   │   ├── stores/        # 状态管理
│   │   │   │   │   ├── media/     # 媒体库状态
│   │   │   │   │   ├── files/     # 文件源状态
│   │   │   │   │   ├── sidebar/   # 侧边栏状态
│   │   │   │   │   └── tabbar/    # 标签栏状态
│   │   │   │   ├── db/            # 数据库
│   │   │   │   │   ├── files/     # 数据库管理
│   │   │   │   │   └── models/    # 数据模型
│   │   │   │   ├── lib/           # 第三方集成
│   │   │   │   │   ├── WebDAVClient.ets
│   │   │   │   │   └── ScrapeClient.ets
│   │   │   │   └── utils/         # 工具函数
│   │   │   └── resources/         # 资源文件
│   │   └── test/                  # 单元测试
│   └── build-profile.json5
├── docs/                          # 文档
│   └── FILTER_AND_SEARCH.md      # 筛选功能说明
├── AppScope/                      # 应用全局资源
├── hvigor/                        # 构建系统
├── build-profile.json5            # 构建配置
└── oh-package.json5               # 依赖配置
```

## 核心模块说明

### 数据库 (FileSourceDatabase)
- 5 张表：file_sources, file_source_directories, videos, scrape_info, play_history
- 支持文件源管理、视频索引、元数据存储、播放历史
- 使用单例模式管理数据库连接

### 媒体库 (MediaLibraryModel)
- 管理媒体库状态（电影、电视剧、合集等）
- 实现搜索、筛选、排序功能
- 响应式状态管理，自动更新 UI

### 播放器 (VideoPlayer)
- 使用适配器模式 (AVPlayerAdapter)
- 支持字幕渲染
- 播放控制和进度管理

## 开发指南

### 环境要求
- DevEco Studio 4.0+
- OpenHarmony SDK API 11+
- Node.js 16+

### 安装依赖
```bash
ohpm install
```

### 构建项目
```bash
hvigorw assembleHap
```

### 运行测试
```bash
hvigorw test
```

## 功能路线图

### ✅ Phase 0 - 基础功能
- [x] 文件源管理（本地、WebDAV）
- [x] 视频扫描和索引
- [x] TMDB 元数据刮削
- [x] 基础播放功能
- [x] 媒体库展示

### ✅ Phase 1 - 搜索与筛选 (当前)
- [x] 片名搜索
- [x] 类型/年份/类别筛选
- [x] 多种排序方式
- [x] 组合筛选
- [x] 空态和错误态处理
- [ ] 分页加载
- [ ] 焦点导航优化

### 📋 Phase 2 - 播放历史 (计划中)
- [ ] 播放进度记录
- [ ] 继续播放功能
- [ ] 未看完列表
- [ ] 最近播放列表
- [ ] 播放统计

### 📋 Phase 3 - 高级功能 (计划中)
- [ ] 收藏夹
- [ ] 播放列表
- [ ] 多用户支持
- [ ] 远程控制 API
- [ ] 字幕下载

## 代码规范

### ArkTS 严格模式
- 遵循 OpenHarmony ArkTS 严格模式
- build() 方法不写临时变量
- 使用稳定 key 避免性能问题

### 命名约定
- 组件: PascalCase
- 文件: PascalCase (组件) / kebab-case (页面)
- 变量/函数: camelCase
- 常量: UPPER_SNAKE_CASE

### 状态管理
- 使用 @ObservedV2 装饰 Model 类
- 使用 @Trace 装饰响应式字段
- 单例模式管理全局状态

## 测试

项目包含完整的单元测试：

- **数据库测试**: FileSourceDatabase.test.ets
- **筛选功能测试**: MediaLibraryFilter.test.ets
- **工具函数测试**: TimeUtil.test.ets
- **WebDAV 测试**: WebDAV.test.ets

运行测试：
```bash
hvigorw test
```

## 贡献指南

欢迎贡献代码！请遵循以下步骤：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

### 提交规范

- feat: 新功能
- fix: 修复 Bug
- docs: 文档更新
- style: 代码格式调整
- refactor: 重构
- test: 测试相关
- chore: 构建/工具相关

## 许可证

待定

## 致谢

- [TMDB](https://www.themoviedb.org/) - 影片元数据 API
- [OpenHarmony](https://www.openharmony.cn/) - 开源操作系统
- [ibestservices/ibest-ui](https://github.com/ibestservices/ibest-ui) - UI 组件库

## 联系方式

- Issue: [GitHub Issues](https://github.com/yaoshining/vidall-tv/issues)
- 作者: [@yaoshining](https://github.com/yaoshining)
