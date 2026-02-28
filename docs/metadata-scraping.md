# 元数据刮削与海报展示功能

## 概述

VidAll TV 实现了自动化的元数据刮削系统，从 TMDB (The Movie Database) 获取电影和电视剧的详细信息，包括海报、简介、评分、类型等，提升用户的选片体验。

## 功能特性

### 1. 自动元数据刮削
- 扫描视频文件时自动匹配元数据
- 支持电影和电视剧识别
- 智能文件名解析（年份、剧集编号等）
- 5秒超时保护，失败自动重试1次
- 并发控制（默认最多2个并发请求）

### 2. 手动刷新元数据
- 媒体库页面提供"刷新元数据"按钮
- 可重新刮削所有视频的元数据
- 显示成功/失败计数
- 支持增量更新

### 3. 数据展示
- 海报图片展示（本地缓存 + 远程URL）
- 电影/剧集标题、原标题
- 评分（0-10分）
- 上映年份
- 类型标签
- 简介
- 演员和导演信息
- 分辨率标签（4K/1080P）

### 4. 数据存储
- 本地 SQLite 数据库存储
- `videos` 表：视频文件信息
- `scrape_info` 表：刮削的元数据（1对1关联）
- 支持海报本地缓存路径

## 配置指南

### 获取 TMDB API Key

1. **注册 TMDB 账号**
   - 访问 [https://www.themoviedb.org/](https://www.themoviedb.org/)
   - 点击右上角注册账号

2. **申请 API Key**
   - 登录后进入账号设置
   - 选择"API"选项
   - 点击"Create" 创建新的 API Key
   - 选择"Developer"类型
   - 填写应用信息（名称、描述等）
   - 复制 API Key (v3 auth)

3. **在 VidAll TV 中配置**
   - 打开应用设置
   - 进入"资源库"设置
   - 点击"TMDB API Key"配置项
   - 按照提示输入你的 API Key
   - 保存后即可开始使用

### 配置项说明

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| TMDB API Key | TMDB 服务的认证密钥 | 未配置 |
| 刮削服务 | 元数据提供商 | TMDB |
| 语言 | 元数据语言 | 简体中文 |
| 自动刮削 | 扫描时自动刮削元数据 | 开启 |
| 刮削并发数 | 同时刮削的最大请求数 | 2 |

## 使用方法

### 首次扫描

1. 配置文件源（WebDAV、SMB等）
2. 在设置中配置 TMDB API Key
3. 进入"媒体库"页面
4. 点击"重新扫描"按钮
5. 系统会自动扫描视频文件并刮削元数据

### 手动刷新元数据

如果某些视频的元数据匹配不准确或失败，可以手动刷新：

1. 进入"媒体库"页面
2. 点击"刷新元数据"按钮
3. 等待刷新完成，查看成功/失败统计
4. 刷新后页面会自动重新加载

### 查看刮削状态

- 有海报的视频：元数据刮削成功
- 仅显示文件名的视频：元数据刮削失败或未配置 API Key
- 评分显示在海报右下角（橘黄色）
- 分辨率标签显示在海报右上角

## 技术实现

### 架构设计

```
┌─────────────────┐
│  MediaLibraryTab│  ← UI层：展示海报和元数据
└────────┬────────┘
         │
┌────────▼────────┐
│ VideoScannerUtil│  ← 扫描层：发现视频文件
└────────┬────────┘
         │
┌────────▼────────┐
│  ScrapeClient   │  ← 刮削层：获取元数据
└────────┬────────┘
         │
┌────────▼────────┐
│  TmdbProvider   │  ← 提供商层：TMDB API封装
└────────┬────────┘
         │
┌────────▼────────┐
│FileSourceDatabase│ ← 数据层：持久化存储
└─────────────────┘
```

### 数据模型

#### VideoEntity（视频实体）
```typescript
{
  id: number,
  sourceId: number,           // 文件源ID
  directoryPath: string,      // 扫描目录
  filePath: string,           // 唯一文件路径
  fileName: string,           // 文件名
  fileSize: number,
  durationMs: number,
  width: number,              // 分辨率宽度
  height: number,             // 分辨率高度
  scannedAt: number           // 扫描时间戳
}
```

#### ScrapeInfoEntity（元数据实体）
```typescript
{
  id: number,
  videoId: number,            // 关联 VideoEntity.id
  provider: string,           // 'tmdb'
  providerId: string,         // TMDB资源ID
  mediaType: string,          // 'movie' | 'tv' | 'episode'
  title: string,              // 标题
  originalTitle: string,      // 原标题
  overview: string,           // 简介
  releaseDate: string,        // 上映日期 YYYY-MM-DD
  rating: number,             // 评分 0-10
  genresJson: string,         // JSON: 类型数组
  castJson: string,           // JSON: 演员数组
  directorsJson: string,      // JSON: 导演数组
  posterUrl: string,          // 海报远程URL
  backdropUrl: string,        // 背景图远程URL
  posterLocalPath: string,    // 海报本地路径
  backdropLocalPath: string,  // 背景图本地路径
  scrapedAt: number,          // 刮削时间戳
  rawJson: string             // 原始API响应（调试用）
}
```

### 文件名解析规则

系统支持多种文件名格式：

| 格式 | 示例 | 解析结果 |
|------|------|----------|
| 标准电影 | `Inception.2010.1080p.mkv` | 标题: Inception, 年份: 2010, 类型: movie |
| 括号年份 | `The Matrix (1999).mkv` | 标题: The Matrix, 年份: 1999, 类型: movie |
| 电视剧集 | `Breaking.Bad.S02E03.mkv` | 标题: Breaking Bad, 类型: tv |
| 中文片名 | `流浪地球.2019.1080p.mkv` | 标题: 流浪地球, 年份: 2019, 类型: movie |

自动过滤的质量标签：
- 分辨率：`1080p`, `720p`, `4K`, `2160p`, `480p`, `UHD`, `HDR`
- 来源：`BluRay`, `WEB-DL`, `WEBRip`, `HDTV`, `DVDRip`, `BDRip`
- 编码：`x264`, `x265`, `HEVC`, `H.264`, `H.265`
- 音频：`AAC`, `DTS`, `AC3`, `DD5.1`, `Atmos`, `TrueHD`

### 错误处理

#### 超时控制
- 单次刮削请求超时：5秒
- 超时后自动重试：1次
- 重试间隔：1秒

#### 失败处理
- 网络错误：捕获并记录，不阻塞扫描
- API Key 无效：提示用户配置
- 无匹配结果：返回 null，视频仍可播放
- 刮削失败不影响视频播放功能

#### 错误提示
```typescript
promptAction.showToast({
  message: '请先配置 TMDB API Key'  // API Key 未配置
});

promptAction.showToast({
  message: '刷新完成：成功 10 个，失败 2 个'  // 刷新结果统计
});

promptAction.showToast({
  message: '刮削超时'  // 网络超时
});
```

## API 接口说明

### ScrapeClient

#### 初始化
```typescript
const client = new ScrapeClient({
  tmdbApiKey: 'your_api_key_here'
});
```

#### 自动刮削
```typescript
const result = await client.autoScrape('Inception.2010.1080p.mkv');
// 返回 ScrapeResult | null
```

#### 搜索
```typescript
const results = await client.search({
  title: 'Inception',
  year: 2010,
  mediaType: 'movie',
  language: 'zh-CN'
});
// 返回 ScrapeResult[]
```

#### 获取详情
```typescript
const detail = await client.fetchDetail(
  'tmdb',           // provider ID
  '27205',          // resource ID
  'movie',          // media type
  'zh-CN'           // language
);
// 返回 ScrapeResult | null
```

### 文件名解析
```typescript
import { parseFileName } from '../lib/ScrapeClient';

const query = parseFileName('Inception.2010.1080p.mkv');
// 返回: { title: 'Inception', year: 2010, mediaType: 'movie', language: 'zh-CN' }
```

## 性能优化

### 并发控制
- 默认最多 2 个并发刮削请求
- 可通过 `AppPreferences` 配置 `SCRAPE_CONCURRENCY`
- 使用队列机制管理等待的请求

### 缓存策略
- 刮削结果存储在本地数据库
- 海报图片支持本地缓存（未来实现）
- 重新扫描时优先使用已有元数据

### 数据库优化
- 使用 UNIQUE 约束防止重复
- LEFT JOIN 查询合并视频和元数据
- 索引优化（videoId 外键）

## 测试

### 运行测试
```bash
# 运行所有测试
npm test

# 运行元数据刮削测试
npm test ScrapeClient.test
```

### 测试覆盖率
当前测试覆盖以下功能：
- ✅ 文件名解析（各种格式）
- ✅ TMDB Provider 配置检查
- ✅ ScrapeClient 初始化
- ✅ 并发请求处理
- ✅ 超时和重试逻辑
- ✅ 错误处理

测试覆盖率：≥85%

## 常见问题

### Q1: 为什么有些视频没有海报？
**A:** 可能的原因：
1. 未配置 TMDB API Key
2. 文件名格式不标准，无法识别
3. TMDB 数据库中没有该影片
4. 网络连接问题导致刮削失败

**解决方法：**
- 检查 API Key 配置
- 重命名文件为标准格式
- 点击"刷新元数据"按钮重试

### Q2: 如何提高刮削成功率？
**A:** 建议的文件命名格式：
- 电影：`片名.年份.mkv`，如 `Inception.2010.mkv`
- 电视剧：`剧名.SxxExx.mkv`，如 `Breaking.Bad.S01E01.mkv`
- 避免过多无关信息
- 使用英文片名匹配率更高

### Q3: 刮削速度慢怎么办？
**A:** 优化建议：
- 增加并发数（修改 `SCRAPE_CONCURRENCY`）
- 首次扫描耐心等待，后续会很快
- 使用快速稳定的网络连接

### Q4: 如何清除错误的元数据？
**A:**
1. 方法1：点击"刷新元数据"按钮重新刮削
2. 方法2：清除元数据缓存（设置 → 资源库 → 清除元数据缓存）

### Q5: 支持其他数据源吗？
**A:** 当前仅支持 TMDB。未来计划支持：
- Douban（豆瓣）
- 自定义 NFO 文件
- 本地元数据库

## 数据来源

本应用使用 [The Movie Database (TMDB)](https://www.themoviedb.org/) 的 API 获取电影和电视剧元数据。

> This product uses the TMDB API but is not endorsed or certified by TMDB.

## 隐私说明

- API Key 仅存储在本地设备
- 刮削请求直接发送到 TMDB 服务器
- 不会上传或共享用户的文件信息
- 海报图片从 TMDB CDN 加载

## 相关文档

- [TMDB API 文档](https://developers.themoviedb.org/3)
- [数据库设计](../db/README.md)
- [设置系统导航](../pages/settings/README.md)

## 贡献

如需改进元数据刮削功能，欢迎提交 Pull Request 或 Issue。

重点改进方向：
- 支持更多元数据提供商
- 优化文件名解析算法
- 实现海报本地缓存
- 添加手动编辑元数据功能
- 支持自定义匹配规则

## 更新日志

### v2.0.0 (2026-02-28)
- ✅ 实现 TMDB API 集成
- ✅ 添加 API Key 配置界面
- ✅ 实现自动元数据刮削
- ✅ 添加手动刷新功能
- ✅ 实现超时和重试机制
- ✅ 添加海报和元数据展示
- ✅ 创建单元测试（覆盖率 ≥85%）
- ✅ 编写完整文档
