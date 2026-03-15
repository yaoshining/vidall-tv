# SettingListItem 图标使用指南

## 功能说明

`SettingListItem` 组件现在支持在标题前插入自定义图标，通过 `@BuilderParam iconBuilder` 参数实现。

## ⚠️ 重要提示

**推荐使用 `@Builder` 方法，避免直接使用箭头函数，否则可能导致应用崩溃！**

## 使用方法

### 1. 推荐方式 - 使用 @Builder 方法 ✅

在组件中定义 `@Builder` 方法，然后传递方法引用：

```typescript
@ComponentV2
struct MySettingPage {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  // 定义图标 Builder
  @Builder
  folderIcon() {
    Text("📁")
      .fontSize(20)
  }

  @Builder
  serverIcon() {
    Text("🖥️")
      .fontSize(20)
  }

  build() {
    SettingContainer({
      title: "设置"
    }) {
      SettingListItemGroup({
        title: "网络"
      }) {
        SettingListItem({
          title: "文件源",
          isLink: true,
          iconBuilder: this.folderIcon  // ✅ 传递方法引用
        })
        SettingListItem({
          title: "服务器",
          isLink: true,
          iconBuilder: this.serverIcon  // ✅ 传递方法引用
        })
      }
    }
  }
}
```

### 2. ❌ 避免使用箭头函数（可能崩溃）

```typescript
// ❌ 错误 - 可能导致 "Cannot read property fontSize of undefined" 崩溃
SettingListItem({
  title: "文件源",
  iconBuilder: () => {
    Text("📁")
      .fontSize(20)
  }
})
```

### 3. 不使用图标（默认行为）

```typescript
SettingListItem({
  title: "隐藏剧透",
  value: "关闭"
  // 不传 iconBuilder 参数，不显示图标
})
```

---

## 📚 更多示例

### 使用不同的 Emoji

```typescript
@ComponentV2
struct SettingsPage {
  @Builder
  userIcon() {
    Text("👤").fontSize(20)
  }

  @Builder
  cloudIcon() {
    Text("☁️").fontSize(20)
  }

  @Builder
  videoIcon() {
    Text("🎬").fontSize(20)
  }

  build() {
    SettingContainer({ title: "设置" }) {
      SettingListItemGroup({ title: "账号" }) {
        SettingListItem({
          title: "用户信息",
          iconBuilder: this.userIcon
        })
      }
    }
  }
}
```

### 使用 Image 图标

```typescript
@ComponentV2
struct SettingsPage {
  @Builder
  customIcon() {
    Image($r("app.media.my_icon"))
      .width(24)
      .height(24)
  }

  build() {
    SettingListItem({
      title: "自定义",
      iconBuilder: this.customIcon
    })
  }
}
```

### 复杂图标（带颜色）

```typescript
@ComponentV2
struct SettingsPage {
  @Builder
  colorfulIcon() {
    Text("●")
      .fontSize(20)
      .fontColor(Color.Green)
  }

  build() {
    SettingListItem({
      title: "在线状态",
      iconBuilder: this.colorfulIcon
    })
  }
}
```

## 完整示例

```typescript
@ComponentV2
struct MySettingPage {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  @Builder
  folderIcon() {
    Text("📁")
      .fontSize(20)
  }

  @Builder
  serverIcon() {
    Text("🖥️")
      .fontSize(20)
  }

  build() {
    SettingContainer({
      title: "网络设置"
    }) {
      SettingListItemGroup({
        title: "服务器"
      }) {
        // 带 Emoji 图标的菜单项
        SettingListItem({
          title: "文件源",
          value: "2 个",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.FILE_SOURCE)
          },
          iconBuilder: this.folderIcon
        })
        
        SettingListItem({
          title: "影视服务器",
          value: "Jellyfin",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.VIDEO_SERVER)
          },
          iconBuilder: this.serverIcon
        })
        
        // 不带图标的菜单项
        SettingListItem({
          title: "自动同步",
          value: "开启"
        })
      }
    }
  }
}
```

## 布局说明

图标会显示在标题文字的左侧，两者之间有 6px 的间距：

```
┌────────────────────────────────────────┐
│  [图标] 标题文字           值  →       │
│  └─6px─┘                               │
└────────────────────────────────────────┘
```

- 图标和标题在同一个 Row 中，通过 `space: 6` 设置间距
- 图标和标题垂直居中对齐（`VerticalAlign.Center`）
- 建议图标尺寸为 20-24px

## 常用图标参考

### 推荐：Emoji 图标

Emoji 图标简单易用，跨平台兼容性好：

```typescript
// 账号相关
Text("👤").fontSize(20)  // 用户
Text("👥").fontSize(20)  // 用户组
Text("🔐").fontSize(20)  // 登录/安全
Text("🚪").fontSize(20)  // 退出

// 网络和服务器
Text("📁").fontSize(20)  // 文件夹/文件源
Text("🖥️").fontSize(20)  // 服务器/电脑
Text("📚").fontSize(20)  // 资源库/书籍
Text("☁️").fontSize(20)  // 云服务
Text("📡").fontSize(20)  // 网络

// 媒体相关
Text("🎬").fontSize(20)  // 视频/电影
Text("📺").fontSize(20)  // 电视
Text("🎵").fontSize(20)  // 音乐
Text("📷").fontSize(20)  // 图片

// 操作相关
Text("⚙️").fontSize(20)  // 设置
Text("📥").fontSize(20)  // 下载
Text("🔔").fontSize(20)  // 通知
Text("🔍").fontSize(20)  // 搜索
Text("⭐").fontSize(20)  // 收藏
```

### HarmonyOS SymbolGlyph 系统图标

使用系统提供的 Symbol 图标（需要 HarmonyOS API 11+）：

```typescript
// 常用 Symbol 图标
SymbolGlyph($r('sys.symbol.settings'))      // 设置
SymbolGlyph($r('sys.symbol.folder'))        // 文件夹
SymbolGlyph($r('sys.symbol.person'))        // 用户
SymbolGlyph($r('sys.symbol.wifi'))          // WiFi
SymbolGlyph($r('sys.symbol.cloud'))         // 云
SymbolGlyph($r('sys.symbol.video'))         // 视频
SymbolGlyph($r('sys.symbol.download'))      // 下载
SymbolGlyph($r('sys.symbol.arrow_right'))   // 右箭头
```

**注意**：SymbolGlyph 的具体可用图标名称需要查看 HarmonyOS 官方文档。

## 样式建议

### 图标尺寸
- **小**: 16-18px（用于次要信息）
- **标准**: 20-24px（推荐，默认大小）
- **大**: 28-32px（用于强调）

### 图标颜色
```typescript
// 白色（默认）
.fillColor(Color.White)

// 主题色
.fillColor("#4A90E2")

// 灰色（次要）
.fillColor("#999999")

// 彩色（根据功能）
.fillColor("#50C878")  // 绿色 - 成功/在线
.fillColor("#FF6B6B")  // 红色 - 错误/离线
.fillColor("#FFA500")  // 橙色 - 警告
```

## 注意事项

1. **iconBuilder 是可选的**：不传入时不显示图标，保持原有布局
2. **图标尺寸建议**：为了保持视觉一致性，建议所有图标使用统一尺寸（如 24x24）
3. **颜色协调**：注意图标颜色与背景色的对比度，确保可见性
4. **性能考虑**：避免在 iconBuilder 中执行复杂的计算或网络请求

## 技术细节

### 参数说明

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| title | string | 否 | '' | 菜单项标题 |
| value | string | 否 | '' | 右侧显示的值 |
| isLink | boolean | 否 | false | 是否显示右箭头 |
| onItemClick | () => void | 否 | () => {} | 点击回调 |
| iconBuilder | @BuilderParam | 否 | undefined | 自定义图标构建器 |

### 实现原理

```typescript
Row({ space: 6 }) {
  // 条件渲染图标
  if (this.iconBuilder) {
    this.iconBuilder()
  }
  // 标题文字
  Text(this.title)
    .fontSize($r("app.float.font_subtitle_1"))
}
.alignItems(VerticalAlign.Center)
```

通过 `@BuilderParam` 装饰器，允许父组件传入自定义的 UI 构建函数，实现灵活的图标定制。







