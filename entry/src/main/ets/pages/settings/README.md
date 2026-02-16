# 设置页面导航堆栈系统

## 概述

设置页面实现了一个堆栈系统来管理多层级菜单的导航历史。当用户在不同的设置菜单之间切换时，系统会自动记录导航路径，允许用户通过返回键回到上一个菜单。

## 核心功能

### 1. SettingsController

控制器提供以下方法来管理导航堆栈：

- **`pushType(newType: SettingType)`** - 推入新的设置类型到堆栈，并切换到新菜单
- **`popType(): boolean`** - 弹出上一个设置类型，返回是否成功
- **`canGoBack(): boolean`** - 检查是否可以返回（是否有历史记录）
- **`clearStack()`** - 清空堆栈
- **`reset(initialType: SettingType)`** - 重置到初始状态

### 2. 导航流程

```
HOME (主菜单)
  ├── FILE_SOURCE (文件源)
  ├── VIDEO_SERVER (影视服务器)
  └── RESOURCE_LIBRARY (资源库)
```

## 使用示例

### 在菜单项中添加导航

在 `HomeSettingBuilder.ets` 中：

```typescript
@ComponentV2
struct HomeSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  build() {
    SettingContainer({
      title: "配置"
    }) {
      SettingListItemGroup({
        title: "网络"
      }) {
        SettingListItem({
          title: "文件源",
          isLink: true,
          onItemClick: () => {
            // 点击时推入新的菜单类型
            this.controller.pushType(SettingType.FILE_SOURCE)
          }
        })
      }
    }
  }
}
```

### 创建新的设置菜单

1. 在 `SettingType.ets` 中添加新类型：
```typescript
static MY_NEW_SETTING = "myNewSetting"
```

2. 创建新的 Builder 文件 `MyNewSettingBuilder.ets`：
```typescript
import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";

@Builder
export function MyNewSettingBuilder() {
  SettingContainer({
    title: "我的新设置"
  }) {
    SettingListItemGroup({
      title: "设置组"
    }) {
      SettingListItem({
        title: "设置项",
        value: "值"
      })
    }
  }
}
```

3. 在 `Index.ets` 中导入并渲染：
```typescript
import { MyNewSettingBuilder } from "./builders/MyNewSettingBuilder"

// 在 build 方法中添加
if (this.controller.type === SettingType.MY_NEW_SETTING) {
  MyNewSettingBuilder()
}
```

4. 在父菜单中添加导航链接：
```typescript
SettingListItem({
  title: "我的新设置",
  isLink: true,
  onItemClick: () => {
    this.controller.pushType(SettingType.MY_NEW_SETTING)
  }
})
```

## 返回键处理

系统会自动处理返回键：
- 如果有导航历史，返回上一个菜单
- 如果已经是根菜单（HOME），关闭设置页面

用户也可以点击设置页面外的区域触发返回。

## 注意事项

1. **Provider/Consumer 模式**：确保在组件中使用 `@Consumer('settingsController')` 来获取控制器实例
2. **Builder 组件包装**：需要导航功能的 Builder 必须包装在 `@ComponentV2` 组件中才能使用 `@Consumer`
3. **堆栈自动管理**：`pushType` 会自动将当前类型压入堆栈，无需手动管理
4. **初始化**：通过 `SettingsPageParam` 传递初始类型时，使用 `reset()` 方法来清空历史堆栈

## 扩展功能

如需更复杂的导航需求，可以扩展 `SettingsController`：

- 添加面包屑导航
- 记录每个页面的标题
- 实现前进功能
- 添加导航动画



