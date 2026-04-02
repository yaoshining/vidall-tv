# GitHub Copilot 项目指令

## 全局规则

- **语言**：所有交互、文档、提交消息统一使用中文
- **Git 提交消息必须使用中文**，格式为：`<类型>: <简要说明>`

## 提交消息生成约束（IDE）

- 在 IDE 中使用「生成提交消息」时，**输出必须是中文**。
- 若生成结果为英文，必须立即改写为中文后再提交。
- 提交首行严格使用：`<类型>: <简要说明>`，类型仅限：`新增`、`修复`、`优化`、`重构`、`文档`、`测试`、`配置`、`样式`。

## 文档与计划文件存放规则

所有由 Copilot 生成的文档、计划、分析报告等 Markdown 文件，必须统一存放在项目根目录的 `.plans/` 文件夹下；允许在 `.plans/` 内按用途建立子目录，但文件名仍必须遵守 `plan-${camelCaseName}.md`。

- ✅ 正确路径：`.plans/reference/plan-videoPlayerStrategy.md`
- ✅ 正确路径：`.plans/product-rules/plan-productDecisionChecklist.md`
- ❌ 错误路径：`plan-videoPlayerStrategy.md`（直接放根目录）
- ❌ 错误路径：`.plans/plan-videoPlayerStrategy.prompt.md`（正式文档不再用 `.prompt.md` 结尾）

## Instructions 组织规则

- 全局共享规则继续保留在 `.github/copilot-instructions.md`
- 高频、可复用、可按文件范围收敛的经验，拆分到 `.github/instructions/*.instructions.md`
- `.github/instructions/githubWorkflow.instructions.md`：放 Git 提交、推分支、创建 PR、命令行执行方式等工作流规则
- `.github/instructions/arktsGuardrails.instructions.md`：放 ArkTS 编译约束、生命周期限制、Promise/catch 书写规范等代码护栏
- `.github/instructions/agentOrganization.instructions.md`：放 `.github/agents/*.agent.md` 的维护规则、命名稳定性和低风险改动原则
- 新增经验时优先追加到最贴近主题的 instructions 文件，避免继续把所有规则堆进一个总文件

## Git 提交规范（重要）

**所有 Git 提交消息必须使用中文，包括 IDE 自动生成的提交消息。**

- **提交消息语言**：统一使用中文（不使用英文）
- **格式**：`<类型>: <简要说明>`
- **常用类型**：
  - `新增`: 添加新功能
  - `修复`: 修复 bug
  - `优化`: 优化性能或代码结构
  - `重构`: 代码重构（不改变功能）
  - `文档`: 文档更新
  - `测试`: 添加或修改测试
  - `配置`: 配置文件修改
  - `样式`: 代码格式调整（不影响功能）
- **示例**：
  - `新增: 实现文件夹选择器功能`
  - `修复: parseFileName 函数处理发布组名称残留问题`
  - `优化: 增强文件名解析的截断策略`
  - `测试: 新增 parseFileName 边界测试用例`
  - `配置: 为测试环境配置 TMDB API Key`

## 项目基本信息

- 平台：HarmonyOS / ArkTS
- SDK：HarmonyOS 6.0.2(22)，compatibleSdkVersion = 5.1.1(19)
- 语言：ArkTS（严格模式，遵守 ArkTS 规范，禁止 any/unknown 类型）

## 项目简介

VidAll_TV 是一款鸿蒙 TV 端视频播放器 App，支持多种远程文件源（WebDAV、SMB 等），核心功能包括：
- 文件源管理（WebDAV 已实现，其他占位预留）
- 视频扫描（`VideoScannerUtil`）：按文件源 + 目录配置递归检索视频文件，支持深度限制和去重
- 视频媒体信息抓取（`VideoInfoUtil`）：通过 AVPlayer prepare 方式异步获取轨道信息
- 视频播放（`VideoPlayerController`）：基于 `media.AVPlayer`，支持字幕轨道切换

## 关键目录结构

```
entry/src/main/ets/
├── components/core/player/   # 播放器核心（VideoPlayerController、VideoData 等）
├── db/                       # 数据库（FileSourceDatabase、FileSourceEntity）
├── lib/                      # 底层库（WebDAVClient）
├── pages/                    # 页面
├── utils/                    # 工具类
│   ├── VideoScannerUtil.ets  # 视频扫描工具
│   └── VideoInfoUtil.ets     # 媒体信息抓取工具
```

## 核心模块说明

### WebDAVClient（`lib/WebDAVClient.ets`）
- 基于 TCP Socket 手动实现 HTTP/WebDAV 协议
- 关键公开方法：`listDirectory(path)`、`getFullUrl(path)`、`getAuthHeaderPublic()`、`testConnection()`
- 路径编码：`listDirectory` 内部已对路径做 `encodeURIPath`，避免空格/中文导致 400
- 认证：Basic Auth，Header 为 `Authorization: Basic <base64>`

### VideoScannerUtil（`utils/VideoScannerUtil.ets`）
- 从数据库读取文件源和目录配置，按协议类型分发到对应 Adapter
- 深度计算：`depth=0` 表示数据库配置的目录本身，`depth=1` 表示第一层子目录，`maxDepth=5` 默认
- 已实现：WebDAV Adapter；其他协议（SMB 等）占位跳过，预留接口
- 去重：通过 `Set<string>` 对文件路径去重

### VideoInfoUtil（`utils/VideoInfoUtil.ets`）
- 创建临时 AVPlayer，走到 `prepared` 状态后调用 `getTrackDescription()`，拿完立即 `release()`
- 并发控制：最多同时 2 个 AVPlayer 实例，超出排队
- URL 编码：自动对路径段编码，避免中文/空格导致 AVPlayer error
- 媒体源：使用 `setMediaSource(url, header)` + `PlaybackStrategy`，支持传 Authorization header
- **已知限制**：含 AC-3/Dolby Digital 音轨的文件会直接进入 error 状态（AVPlayer 不支持 AC-3 解码），不影响扫描结果

## 数据库模型

- `file_sources`：文件源（id、name、type、config_json、created_at）
- `file_source_directories`：目录配置（id、source_id、directory_path）
- `config_json` 结构（WebDAV）：`{ url, username, password, protocol, port, rootPath }`
  - `url`：纯 host，不含协议和端口（如 `192.168.3.59`）
  - `rootPath`：WebDAV 根路径（如 `/dav`），拼接后为 `http://host:port/dav`
  - `directoryPath`（目录表）：相对于 rootPath 的路径（如 `/nas/电影`）

## ArkTS 编码规范（重要）

- 禁止 `any` / `unknown` 类型，必须使用明确类型
- 禁止 spread 非数组类型（`arkts-no-spread`）
- `throw` 只能抛出 `Error` 及其子类，不能抛原始值
- 禁止声明合并（`arkts-no-decl-merging`）
- 错误处理统一用 `BusinessError`（`@kit.BasicServicesKit`）
- `atob` 不可用，base64 解码用 `buffer.from(str, 'base64').toString('utf-8')`（`@ohos.buffer`）
- **`build()` 方法内只能写 UI 组件语法，禁止写 `const`/`let` 变量声明、普通函数调用赋值等 JS 语句**（报错：`Only UI component syntax can be written here`）。需要中间变量时，必须提取为组件的普通方法或 `@Builder` 方法，在 `build()` 里直接调用方法取值或通过条件表达式内联。
  ```typescript
  // ❌ 错误：build() 内声明变量
  build() {
    if (this.isSelected(dir)) {
      const name = this.map.get(dir.path) ?? ''  // 报错！
      if (name.length > 0) { Text(name) }
    }
  }

  // ✅ 正确：提取为方法，build() 内直接调用
  private getName(dir: DirItem): string {
    return this.map.get(dir.path) ?? ''
  }
  build() {
    if (this.isSelected(dir) && this.getName(dir).length > 0) {
      Text(this.getName(dir))
    }
  }
  ```

## 播放器已知限制

| 问题 | 原因 | 解决路径 |
|------|------|---------|
| AC-3/DTS 音频无法 prepare | AVPlayer 不内置 AC-3 解码器 | 中期引入 FFmpeg NAPI |
| AVMetadataExtractor 不支持远程 URL | API 19 无 `setUrlSource`，该方法 API 20 起才有 | 升级到 API 20 后可用 |
| `getTrackDescription` 字幕语言为空 | AVPlayer 返回的 MediaDescription 部分字段缺失 | FFmpeg 可完整返回 |
| 帧率返回 x100（如 2397） | AVPlayer 内部单位问题 | VideoInfoUtil 已做 >200 时除以 100 的修正 |

## ArkTS 额外规范（补充）

- **`catch` 子句不允许类型注解**（`arkts-no-types-in-catch`）：写 `catch (e)` 即可，**不能**写 `catch (e: Error)` 或 `catch (e: unknown)`。需要访问 Error 属性时在 catch 体内用 `(e as BusinessError).message`。
  ```typescript
  // ❌ 错误
  catch (e: Error) { ... }

  // ✅ 正确
  catch (e) {
    const err = e as BusinessError;
    console.error(err.message);
  }
  ```

- **`.map()` 等回调里的对象字面量必须有显式类型**（`arkts-no-untyped-obj-literals`）：直接 `.map(x => ({ ... }))` 会报错，需提取变量并标注类型后返回。
  ```typescript
  // ❌ 错误
  const list = items.map(c => ({ name: c.name, role: c.character }));

  // ✅ 正确
  const list: MyInterface[] = items.map(c => {
    const item: MyInterface = { name: c.name, role: c.character };
    return item;
  });
  ```
