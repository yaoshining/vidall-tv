import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ServiceLocator } from '../main/ets/services/ServiceLocator';

/**
 * 测试套件：ServiceLocator - 依赖注入容器
 * 
 * 测试目标：
 * 1. 服务注册和检索功能
 * 2. 单例模式（同一服务名返回同一实例）
 * 3. 类型安全
 * 4. 错误处理（未注册服务）
 */

// 测试用的简单服务接口
interface TestService {
  getValue(): string;
}

class TestServiceImpl implements TestService {
  private value: string;
  
  constructor(value: string) {
    this.value = value;
  }
  
  getValue(): string {
    return this.value;
  }
}

export default function serviceLocatorTest() {
  
  beforeEach(() => {
    // 每次测试前重置 ServiceLocator
    ServiceLocator.reset();
  });

  describe('ServiceLocator - 服务注册', () => {
    
    it('应能注册服务', 0, () => {
      const service = new TestServiceImpl('test-value');
      
      let threw = false;
      try {
        ServiceLocator.register('test-service', service);
      } catch (e) {
        threw = true;
      }
      
      expect(threw).assertFalse();
    });

    it('应能注册多个不同名称的服务', 0, () => {
      const service1 = new TestServiceImpl('value1');
      const service2 = new TestServiceImpl('value2');
      
      ServiceLocator.register('service1', service1);
      ServiceLocator.register('service2', service2);
      
      const retrieved1 = ServiceLocator.get<TestService>('service1');
      const retrieved2 = ServiceLocator.get<TestService>('service2');
      
      expect(retrieved1.getValue()).assertEqual('value1');
      expect(retrieved2.getValue()).assertEqual('value2');
    });

    it('重复注册同名服务应覆盖原服务', 0, () => {
      const service1 = new TestServiceImpl('old-value');
      const service2 = new TestServiceImpl('new-value');
      
      ServiceLocator.register('service', service1);
      ServiceLocator.register('service', service2);
      
      const retrieved = ServiceLocator.get<TestService>('service');
      expect(retrieved.getValue()).assertEqual('new-value');
    });
  });

  describe('ServiceLocator - 服务检索', () => {
    
    it('应能检索已注册的服务', 0, () => {
      const service = new TestServiceImpl('test-value');
      ServiceLocator.register('test-service', service);
      
      const retrieved = ServiceLocator.get<TestService>('test-service');
      
      expect(retrieved).assertNotNull();
      expect(retrieved.getValue()).assertEqual('test-value');
    });

    it('多次检索同一服务应返回同一实例（单例）', 0, () => {
      const service = new TestServiceImpl('test-value');
      ServiceLocator.register('test-service', service);
      
      const retrieved1 = ServiceLocator.get<TestService>('test-service');
      const retrieved2 = ServiceLocator.get<TestService>('test-service');
      const retrieved3 = ServiceLocator.get<TestService>('test-service');
      
      // 验证是同一实例
      expect(retrieved1 === retrieved2).assertTrue();
      expect(retrieved2 === retrieved3).assertTrue();
      expect(retrieved1 === service).assertTrue();
    });

    it('检索未注册的服务应抛出错误', 0, () => {
      let threw = false;
      let errorMessage = '';
      
      try {
        ServiceLocator.get<TestService>('non-existent-service');
      } catch (e) {
        threw = true;
        if (e instanceof Error) {
          errorMessage = e.message;
        }
      }
      
      expect(threw).assertTrue();
      expect(errorMessage.includes('non-existent-service')).assertTrue();
    });
  });

  describe('ServiceLocator - 类型安全', () => {
    
    it('应支持泛型类型检查', 0, () => {
      const service = new TestServiceImpl('test-value');
      ServiceLocator.register('test-service', service);
      
      // TypeScript 编译时类型检查
      const retrieved: TestService = ServiceLocator.get<TestService>('test-service');
      expect(retrieved !== null).assertTrue();
    });
  });

  describe('ServiceLocator - 辅助功能', () => {
    
    it('reset() 应清空所有已注册服务', 0, () => {
      const service = new TestServiceImpl('test-value');
      ServiceLocator.register('test-service', service);
      
      ServiceLocator.reset();
      
      let threw = false;
      try {
        ServiceLocator.get<TestService>('test-service');
      } catch (e) {
        threw = true;
      }
      
      expect(threw).assertTrue();
    });

    it('has() 应正确判断服务是否已注册', 0, () => {
      const service = new TestServiceImpl('test-value');
      
      expect(ServiceLocator.has('test-service')).assertFalse();
      
      ServiceLocator.register('test-service', service);
      expect(ServiceLocator.has('test-service')).assertTrue();
    });
  });
}
