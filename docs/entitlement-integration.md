# 权限架构集成指南

## 目录

1. [概述](#概述)
2. [核心概念](#核心概念)
3. [快速开始](#快速开始)
4. [Feature Gating 模式](#feature-gating-模式)
5. [v2.0 迁移指南](#v20-迁移指南)
6. [最佳实践](#最佳实践)
7. [故障排查](#故障排查)

---

## 概述

VidAll_TV 权限架构提供了功能门控（Feature Gating）基础设施，支持：

- **v1.x**：所有功能免费开放（LocalFreeEntitlementService）
- **v2.0**：基于用户订阅的权限控制（AuthEntitlementService，未来实现）

### 核心价值

- ✅ 零破坏性变更：v1.x 用户体验完全不变
- ✅ 扩展点预埋：v2.0 可无缝集成，无需重构现有代码
- ✅ 类型安全：TypeScript 接口保证编译时类型检查
- ✅ 高性能：LocalFree 实现 < 1ms 响应时间

---

## 核心概念

### EntitlementService 接口

定义权限查询契约，所有实现必须遵守：

```typescript
interface EntitlementService {
  // 查询功能访问权限
  hasFeature(featureId: string): Promise<boolean>;
  
  // 查询内容访问权限
  canAccessContent(contentId: string, contentType: string): Promise<boolean>;
  
  // 获取用户订阅等级
  getUserTier(): Promise<UserTier>;
}

type UserTier = 'free' | 'basic' | 'premium';
```

### Feature ID 命名规范

功能标识符必须遵循格式：`feature:<kebab-case-name>`

预定义常量：

```typescript
import { FEATURE_ADVANCED_PLAYBACK } from './services/entitlement/FeatureIds';

// 可用常量：
FEATURE_ADVANCED_PLAYBACK  = 'feature:advanced-playback'
FEATURE_CLOUD_SYNC         = 'feature:cloud-sync'
FEATURE_PREMIUM_CONTENT    = 'feature:premium-content'
```

### 服务架构

```
┌─────────────────────────────────────────────┐
│          Component / Page                   │
│  ┌─────────────────────────────────────┐   │
│  │  ServiceLocator.get('entitlement')  │   │
│  └──────────────┬──────────────────────┘   │
└─────────────────┼──────────────────────────┘
                  │
                  v
┌─────────────────────────────────────────────┐
│        EntitlementService Interface         │
└─────────────────┬───────────────────────────┘
                  │
     ┌────────────┴────────────┐
     │                         │
     v                         v
┌────────────────┐    ┌────────────────────┐
│  LocalFree     │    │  AuthEntitlement   │
│  (v1.x)        │    │  (v2.0 未来)       │
│  All → true    │    │  Query remote API  │
└────────────────┘    └────────────────────┘
```

---

## 快速开始

### 1. 获取服务实例

在组件中获取 EntitlementService：

```typescript
import { ServiceLocator } from '../services/ServiceLocator';
import { EntitlementService } from '../services/entitlement/EntitlementService';

const entitlementService = ServiceLocator.get<EntitlementService>('entitlement');
```

### 2. 检查功能权限

```typescript
import { FEATURE_ADVANCED_PLAYBACK } from '../services/entitlement/FeatureIds';

const hasAccess = await entitlementService.hasFeature(FEATURE_ADVANCED_PLAYBACK);
if (hasAccess) {
  // 渲染功能 UI 或执行功能逻辑
}
```

### 3. 检查内容权限

```typescript
const canAccess = await entitlementService.canAccessContent('video-123', 'video');
if (canAccess) {
  // 播放视频
} else {
  // 显示升级提示
}
```

---

## Feature Gating 模式

### 模式 1: Hide Pattern（隐藏模式）

**适用场景**：实验性功能、Beta 功能、完全隐藏的付费功能

**效果**：用户看不到该功能，避免混淆

**实现示例**：

```typescript
@Component
struct AdvancedPlaybackControls {
  @State hasAccess: boolean = false;
  
  async aboutToAppear() {
    const service = ServiceLocator.get<EntitlementService>('entitlement');
    this.hasAccess = await service.hasFeature(FEATURE_ADVANCED_PLAYBACK);
  }
  
  build() {
    Column() {
      // 基础控制（始终显示）
      Button('播放')
      Button('暂停')
      
      // 高级控制（条件显示）
      if (this.hasAccess) {
        Button('倍速播放')
        Button('逐帧控制')
        Button('自定义步长')
      }
    }
  }
}
```

**优点**：
- UI 干净，不困扰免费用户
- 适合未完成或不稳定的功能

**缺点**：
- 用户不知道功能存在，无法引导升级

---

### 模式 2: Disable Pattern（禁用模式）

**适用场景**：可发现的付费功能、需要引导用户升级的场景

**效果**：用户可以看到功能，但无法使用，点击后显示升级提示

**实现示例**：

```typescript
@Component
struct CloudSyncButton {
  @State hasAccess: boolean = false;
  @State isLoading: boolean = true;
  
  async aboutToAppear() {
    const service = ServiceLocator.get<EntitlementService>('entitlement');
    this.hasAccess = await service.hasFeature(FEATURE_CLOUD_SYNC);
    this.isLoading = false;
  }
  
  handleClick() {
    if (!this.hasAccess) {
      // 显示升级提示对话框
      this.showUpgradePrompt();
      return;
    }
    
    // 执行云同步逻辑
    this.performCloudSync();
  }
  
  build() {
    Button('云同步')
      .enabled(this.hasAccess && !this.isLoading)
      .opacity(this.hasAccess ? 1.0 : 0.5)
      .onClick(() => this.handleClick())
      .overlay(
        // 可选：添加锁图标指示付费功能
        !this.hasAccess ? Image($r('app.media.ic_lock')) : null,
        { align: Alignment.TopEnd }
      )
  }
  
  showUpgradePrompt() {
    AlertDialog.show({
      title: '升级到高级版',
      message: '云同步功能需要高级订阅。立即升级以解锁跨设备同步能力。',
      primaryButton: {
        value: '立即升级',
        action: () => {
          // 跳转到订阅页面
        }
      },
      secondaryButton: {
        value: '稍后再说',
        action: () => {}
      }
    });
  }
}
```

**优点**：
- 功能可发现，促进转化
- 透明的付费模式

**缺点**：
- 可能让免费用户感到受限
- 需要额外的升级提示 UI

---

### 模式选择决策树

```
需要功能门控？
    │
    ├─ No  → 直接实现，无权限检查
    │
    └─ Yes → 功能是否面向最终用户？
              │
              ├─ No（开发/测试功能）→ Hide Pattern
              │
              └─ Yes → 是否需要引导用户升级？
                        │
                        ├─ No  → Hide Pattern
                        └─ Yes → Disable Pattern
```

---

## v2.0 迁移指南

### 架构变更概览

v2.0 将引入远程认证服务，但**不需要修改任何业务逻辑代码**。

| 组件 | v1.x | v2.0 变更 |
|------|------|-----------|
| EntitlementService 接口 | ✅ 已定义 | ⚠️ 无变更 |
| LocalFreeEntitlementService | ✅ 已实现 | ⚠️ 保留（作为降级方案） |
| AuthEntitlementService | ❌ 不存在 | ✅ 新增实现 |
| EntryAbility 服务注册 | `new LocalFree()` | ⚠️ 改为 `new Auth(config)` |
| 业务代码 (Pages/Components) | ✅ 使用接口 | ✅ 无需修改 |

### 迁移步骤

#### 步骤 1: 实现 AuthEntitlementService

```typescript
/**
 * v2.0 实现 - 基于远程 API 的权限服务
 */
export class AuthEntitlementService implements EntitlementService {
  private apiClient: AuthApiClient;
  private cache: EntitlementCache;
  
  constructor(config: AuthConfig) {
    this.apiClient = new AuthApiClient(config.apiBaseUrl, config.apiKey);
    this.cache = new EntitlementCache(config.cacheTTL);
  }
  
  async hasFeature(featureId: string): Promise<boolean> {
    try {
      // 1. 检查缓存
      const cached = this.cache.get(`feature:${featureId}`);
      if (cached !== null) {
        return cached;
      }
      
      // 2. 查询远程 API
      const response = await this.apiClient.checkFeatureAccess(featureId);
      
      // 3. 更新缓存
      this.cache.set(`feature:${featureId}`, response.hasAccess);
      
      return response.hasAccess;
    } catch (error) {
      // Fail-open 策略：网络错误时允许访问（可配置）
      hilog.error(DOMAIN, TAG, `hasFeature error: ${error}, failing open`);
      return true;
    }
  }
  
  async canAccessContent(contentId: string, contentType: string): Promise<boolean> {
    // 类似实现...
  }
  
  async getUserTier(): Promise<UserTier> {
    // 查询用户订阅信息...
  }
}
```

#### 步骤 2: 替换服务注册

在 `EntryAbility.ets` 中修改：

```typescript
// v1.x 代码
const entitlementService = new LocalFreeEntitlementService();
ServiceLocator.register('entitlement', entitlementService);

// v2.0 代码
const authConfig: AuthConfig = {
  apiBaseUrl: 'https://api.vidall.com/v2',
  apiKey: AppPreferences.get(PrefKey.API_KEY),
  cacheTTL: 300000 // 5 分钟缓存
};

const entitlementService = new AuthEntitlementService(authConfig);
ServiceLocator.register('entitlement', entitlementService);
```

#### 步骤 3: 测试验证

```typescript
// 测试 v2.0 集成
describe('v2.0 AuthEntitlementService Integration', () => {
  it('付费用户可以访问高级功能', async () => {
    const mockApiClient = createMockApiClient({
      userId: 'premium-user-123',
      tier: 'premium'
    });
    
    const service = new AuthEntitlementService({
      apiClient: mockApiClient
    });
    
    const hasAccess = await service.hasFeature(FEATURE_CLOUD_SYNC);
    expect(hasAccess).assertTrue();
  });
  
  it('免费用户无法访问高级功能', async () => {
    const mockApiClient = createMockApiClient({
      userId: 'free-user-456',
      tier: 'free'
    });
    
    const service = new AuthEntitlementService({
      apiClient: mockApiClient
    });
    
    const hasAccess = await service.hasFeature(FEATURE_CLOUD_SYNC);
    expect(hasAccess).assertFalse();
  });
});
```

---

## 最佳实践

### ✅ DO（推荐做法）

1. **使用常量而非魔法字符串**
   ```typescript
   // Good
   service.hasFeature(FEATURE_ADVANCED_PLAYBACK);
   
   // Bad
   service.hasFeature('feature:advanced-playback');
   ```

2. **异步处理权限检查**
   ```typescript
   // Good: 组件加载时检查
   async aboutToAppear() {
     this.hasAccess = await service.hasFeature(FEATURE_X);
   }
   
   // Bad: 同步阻塞
   build() {
     if (service.hasFeature(FEATURE_X)) { ... } // ❌ 编译错误
   }
   ```

3. **缓存权限结果到组件状态**
   ```typescript
   @State hasCloudSync: boolean = false;
   
   async aboutToAppear() {
     const service = ServiceLocator.get<EntitlementService>('entitlement');
     this.hasCloudSync = await service.hasFeature(FEATURE_CLOUD_SYNC);
   }
   ```

4. **优雅的加载状态处理**
   ```typescript
   @State isCheckingAccess: boolean = true;
   @State hasAccess: boolean = false;
   
   async aboutToAppear() {
     try {
       const service = ServiceLocator.get<EntitlementService>('entitlement');
       this.hasAccess = await service.hasFeature(FEATURE_X);
     } finally {
       this.isCheckingAccess = false;
     }
   }
   
   build() {
     if (this.isCheckingAccess) {
       LoadingSpinner()
     } else if (this.hasAccess) {
       FeatureUI()
     } else {
       EmptyPlaceholder()
     }
   }
   ```

### ❌ DON'T（避免的做法）

1. **不要硬编码功能 ID**
   ```typescript
   // Bad
   service.hasFeature('advanced-playback'); // ❌ 缺少 'feature:' 前缀，且无类型检查
   ```

2. **不要在性能敏感路径频繁调用**
   ```typescript
   // Bad: 每次 build() 都调用（会触发大量重绘）
   build() {
     List() {
       ForEach(this.items, (item) => {
         // ❌ 每个 item 都异步查询
         if (await service.hasFeature(FEATURE_X)) {
           ItemWithFeature(item)
         }
       })
     }
   }
   
   // Good: 一次性检查并缓存
   @State hasFeature: boolean = false;
   async aboutToAppear() {
     this.hasFeature = await service.hasFeature(FEATURE_X);
   }
   build() {
     List() {
       ForEach(this.items, (item) => {
         if (this.hasFeature) {
           ItemWithFeature(item)
         }
       })
     }
   }
   ```

3. **不要忽略错误处理**
   ```typescript
   // Bad
   const hasAccess = await service.hasFeature(FEATURE_X);
   
   // Good
   try {
     const hasAccess = await service.hasFeature(FEATURE_X);
     // 使用 hasAccess
   } catch (error) {
     hilog.error(DOMAIN, TAG, `权限检查失败: ${error}`);
     // Fail-open: 默认允许访问
     const hasAccess = true;
   }
   ```

---

## 故障排查

### 问题 1: `Service 'entitlement' not found`

**原因**：EntitlementService 未在应用启动时注册

**解决方案**：

1. 检查 `EntryAbility.onCreate()` 是否包含注册代码：
   ```typescript
   const entitlementService = new LocalFreeEntitlementService();
   ServiceLocator.register('entitlement', entitlementService);
   ```

2. 确认应用重启后问题是否解决（热重载可能不会重新执行 onCreate）

---

### 问题 2: 功能未正确隐藏/禁用

**症状**：v1.x 所有功能应该可见，但部分功能被隐藏

**排查步骤**：

1. 确认使用的是 LocalFreeEntitlementService（v1.x）
   ```typescript
   const service = ServiceLocator.get<EntitlementService>('entitlement');
   console.log(service.constructor.name); // 应输出 'LocalFreeEntitlementService'
   ```

2. 检查权限检查逻辑是否正确：
   ```typescript
   const hasAccess = await service.hasFeature(FEATURE_X);
   console.log(`hasAccess: ${hasAccess}`); // v1.x 应始终为 true
   ```

3. 验证组件状态更新：
   ```typescript
   @State hasAccess: boolean = false;
   
   async aboutToAppear() {
     this.hasAccess = await service.hasFeature(FEATURE_X);
     console.log(`State updated: ${this.hasAccess}`); // 添加日志
   }
   ```

---

### 问题 3: 性能问题（权限检查耗时过长）

**症状**：UI 渲染卡顿，权限检查延迟明显

**排查步骤**：

1. 检查是否在循环中重复调用：
   ```typescript
   // Bad
   ForEach(items, (item) => {
     const hasAccess = await service.hasFeature(FEATURE_X); // ❌
   })
   ```

2. 启用性能日志：
   ```typescript
   const startTime = Date.now();
   const hasAccess = await service.hasFeature(FEATURE_X);
   const duration = Date.now() - startTime;
   console.log(`权限检查耗时: ${duration}ms`); // v1.x 应 < 1ms
   ```

3. 确认 LocalFreeEntitlementService 性能：
   - v1.x: 应 < 1ms（立即返回 Promise.resolve）
   - v2.0: 应 < 100ms（含网络缓存）

---

## 附录

### A. 完整代码示例

参见项目中的示例实现：

- **接口定义**：`entry/src/main/ets/services/entitlement/EntitlementService.ets`
- **LocalFree 实现**：`entry/src/main/ets/services/entitlement/LocalFreeEntitlementService.ets`
- **Feature IDs**：`entry/src/main/ets/services/entitlement/FeatureIds.ets`
- **ServiceLocator**：`entry/src/main/ets/services/ServiceLocator.ets`
- **集成示例**：`entry/src/main/ets/entryability/EntryAbility.ets`

### B. API 参考

#### EntitlementService API

| 方法 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `hasFeature` | `featureId: string` | `Promise<boolean>` | 查询功能权限 |
| `canAccessContent` | `contentId: string, contentType: string` | `Promise<boolean>` | 查询内容权限 |
| `getUserTier` | 无 | `Promise<UserTier>` | 获取订阅等级 |

#### ServiceLocator API

| 方法 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `register` | `name: string, service: T` | `void` | 注册服务 |
| `get` | `name: string` | `T` | 获取服务 |
| `has` | `name: string` | `boolean` | 检查服务是否存在 |
| `reset` | 无 | `void` | 清空服务（仅测试用） |

---

## 更新日志

- **v1.0.0** (2024-05-01): 初始版本，LocalFreeEntitlementService 实现
- **v2.0.0** (计划中): AuthEntitlementService 实现，远程权限查询

---

## 支持与反馈

遇到问题或有改进建议？

- 📋 提交 Issue: [GitHub Issues](https://github.com/yaoshining/vidall-tv/issues)
- 📧 联系团队: dev@vidall.com
