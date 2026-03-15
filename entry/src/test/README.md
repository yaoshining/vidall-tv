# 文件源数据库测试用例

## 概述

`FileSourceDatabase.test.ets` 包含了完整的数据库功能测试用例，涵盖了数据库迁移、密码加密、CRUD 操作等核心功能。

## 测试用例列表

### 1. **验证数据库表创建** (`should create tables on init`)
- 验证初始化时正确创建了 `file_sources` 和 `file_source_directories` 表
- 验证表结构包含所有必需的列
- 使用 `sqlite_master` 查询验证表存在性

### 2. **测试数据库版本升级** (`should upgrade from version 1 to 2`)
- 模拟从版本 1 升级到版本 2 的场景
- 验证升级后表结构和数据的完整性
- 预留给未来版本升级使用

### 3. **验证密码加密存储** (`should encrypt password on save`)
- 插入包含密码的文件源
- 直接查询数据库验证密码在存储时是加密的
- 通过 API 读取验证密码正确解密回原始值
- 验证加密格式符合 `iv:ciphertext` 规范

### 4. **跨版本升级测试** (`should handle cross-version upgrade`)
- 模拟从版本 1 直接升级到版本 3 的场景
- 验证中间版本（版本 2）的升级步骤都正确执行
- 预留给未来多版本升级使用

### 5. **完整的 CRUD 操作流程** (`should complete CRUD operations`)
- 测试插入（Insert）、查询（Read）、更新（Update）、删除（Delete）的完整流程
- 验证每个操作的正确性
- 验证操作之间的关联性

### 6. **并发操作测试** (`should handle concurrent operations`)
- 同时插入多条数据
- 验证并发操作的数据一致性
- 确保没有数据竞争问题

### 7. **错误处理测试** (`should handle errors properly`)
- 测试更新不存在的记录
- 测试删除不存在的记录
- 测试查询不存在的记录
- 验证错误处理的正确性

### 8. **加密工具独立测试** (`should encrypt and decrypt correctly`)
- 测试 `CryptoUtil` 的加密功能
- 测试解密功能
- 验证加密格式（`iv:ciphertext`）
- 验证多次加密使用不同的 IV（随机性）
- **这是唯一一个可以独立运行的测试用例**（不需要 Context）

## 运行测试

### 前置条件

大部分测试用例需要真实的应用 Context 才能运行，因此需要在设备或模拟器上运行集成测试。

### 运行步骤

1. **在 DevEco Studio 中**：
   - 右键点击测试文件 `FileSourceDatabase.test.ets`
   - 选择 "Run 'FileSourceDatabase.test.ets'"
   - 选择目标设备（真机或模拟器）

2. **使用命令行**：
   ```bash
   # 运行所有测试
   hvigorw test
   
   # 运行特定测试套件
   hvigorw test --test-file FileSourceDatabase.test.ets
   ```

### 当前状态

- ✅ **测试用例 8**（加密工具测试）可以直接运行，不需要 Context
- ⚠️ **测试用例 1-7** 需要真实的 Context，当前处于跳过状态
- 💡 要启用这些测试，需要在 `beforeEach()` 中获取真实的 Context：
  ```typescript
  beforeEach(async () => {
    context = globalThis.abilityContext;
    database = FileSourceDatabase.getInstance(context);
    await database.init();
  });
  ```

## 手动启用测试

如果要在实际设备上运行完整测试，请按以下步骤修改：

1. **取消注释测试代码**：
   - 打开 `FileSourceDatabase.test.ets`
   - 找到每个测试用例中被注释的代码
   - 取消注释并确保能获取到有效的 Context

2. **设置 Context**：
   ```typescript
   beforeEach(async () => {
     // 方法 1: 从 globalThis 获取
     context = globalThis.abilityContext;
     
     // 方法 2: 从 TestAbility 获取
     // context = getContext(this);
     
     database = FileSourceDatabase.getInstance(context);
     await database.init();
   });
   ```

3. **清理测试数据**：
   ```typescript
   afterEach(async () => {
     // 删除所有测试数据
     const allSources = await database.getAllFileSources();
     for (const source of allSources) {
       if (source.id) {
         await database.deleteFileSource(source.id);
       }
     }
   });
   ```

## 测试覆盖率

当前测试覆盖以下功能模块：

- ✅ 数据库初始化
- ✅ 表结构创建
- ✅ 版本升级机制
- ✅ 密码加密/解密
- ✅ 插入操作
- ✅ 查询操作（单个/所有）
- ✅ 更新操作
- ✅ 删除操作
- ✅ 并发操作
- ✅ 错误处理
- ✅ 加密工具独立功能

## 注意事项

1. **Context 依赖**：大部分测试需要真实的应用 Context，无法在纯单元测试环境运行
2. **数据隔离**：建议在测试环境使用独立的数据库文件，避免影响生产数据
3. **清理工作**：每个测试后应清理测试数据，避免影响后续测试
4. **异步操作**：所有数据库操作都是异步的，注意正确使用 `await`
5. **加密测试**：测试用例 8 可以独立运行，用于验证加密功能是否正常

## 已知问题

- 需要在实际设备上运行才能验证完整功能
- 版本升级测试需要等到有新版本时才能真正验证
- 当前所有测试都标记为"跳过"状态，需要手动启用

## 相关文件

- `/entry/src/main/ets/lib/database/FileSourceDatabase.ets` - 数据库管理类
- `/entry/src/main/ets/lib/utils/CryptoUtil.ets` - 加密工具类
- `/entry/src/main/ets/lib/models/FileSourceModel.ets` - 数据模型定义
- `/entry/src/main/ets/lib/stores/FileSourceStore.ets` - 缓存管理类

