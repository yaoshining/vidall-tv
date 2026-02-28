import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { CommonConstants } from '../common/constants/CommonConstants';
import { AnalyticsEvent, EventType } from './AnalyticsTypes';
import { util } from '@kit.ArkTS';

const TAG = '[AnalyticsManager]';

/**
 * 埋点管理器配置
 */
export interface AnalyticsConfig {
  maxQueueSize?: number;        // 最大队列大小，默认 1000
  flushInterval?: number;       // 刷新间隔(ms)，默认 30000 (30秒)
  batchSize?: number;           // 批量上传大小，默认 50
  enableLocalStorage?: boolean; // 是否启用本地存储，默认 true
  enableConsoleLog?: boolean;   // 是否启用控制台日志，默认 false
}

/**
 * 埋点管理器
 * 负责收集、存储和上传埋点事件
 * 使用单例模式确保全局唯一
 */
export class AnalyticsManager {
  private static instance: AnalyticsManager | null = null;
  private eventQueue: AnalyticsEvent[] = [];
  private sessionId: string = '';
  private config: Required<AnalyticsConfig>;
  private preferencesStore: preferences.Preferences | null = null;
  private flushTimer: number | null = null;
  private isInitialized: boolean = false;

  private constructor() {
    // 默认配置
    this.config = {
      maxQueueSize: 1000,
      flushInterval: 30000,
      batchSize: 50,
      enableLocalStorage: true,
      enableConsoleLog: false
    };
    this.sessionId = this.generateSessionId();
  }

  /**
   * 获取单例实例
   */
  public static getInstance(): AnalyticsManager {
    if (AnalyticsManager.instance === null) {
      AnalyticsManager.instance = new AnalyticsManager();
    }
    return AnalyticsManager.instance;
  }

  /**
   * 初始化埋点管理器
   */
  public async init(context: Context, config?: AnalyticsConfig): Promise<void> {
    if (this.isInitialized) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'AnalyticsManager already initialized');
      return;
    }

    try {
      // 合并配置
      if (config) {
        this.config = { ...this.config, ...config };
      }

      // 初始化本地存储
      if (this.config.enableLocalStorage) {
        this.preferencesStore = await preferences.getPreferences(context, 'analytics_store');
        // 加载未上传的事件
        await this.loadUnsentEvents();
      }

      // 启动定时刷新
      this.startFlushTimer();

      this.isInitialized = true;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `AnalyticsManager initialized with sessionId: ${this.sessionId}`);
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `init failed: ${JSON.stringify(err)}`);
      throw err;
    }
  }

  /**
   * 生成会话ID
   */
  private generateSessionId(): string {
    const timestamp = Date.now();
    const random = Math.random().toString(36).substring(2, 15);
    return `${timestamp}_${random}`;
  }

  /**
   * 记录埋点事件
   */
  public track(event: Omit<AnalyticsEvent, 'timestamp' | 'sessionId'>): void {
    try {
      // 构建完整的事件对象
      const fullEvent: AnalyticsEvent = {
        ...event,
        timestamp: Date.now(),
        sessionId: this.sessionId
      } as AnalyticsEvent;

      // 添加到队列
      this.eventQueue.push(fullEvent);

      // 控制台日志（调试用）
      if (this.config.enableConsoleLog) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `Event tracked: ${fullEvent.eventType}, data: ${JSON.stringify(fullEvent)}`);
      }

      // 检查队列大小
      if (this.eventQueue.length >= this.config.maxQueueSize) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `Queue size exceeded ${this.config.maxQueueSize}, flushing...`);
        this.flush();
      }

      // 检查是否需要批量上传
      if (this.eventQueue.length >= this.config.batchSize) {
        this.flush();
      }
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `track failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 刷新事件队列（保存到本地存储）
   */
  public async flush(): Promise<void> {
    if (this.eventQueue.length === 0) {
      return;
    }

    try {
      const eventsToFlush = [...this.eventQueue];
      this.eventQueue = [];

      // 保存到本地存储
      if (this.config.enableLocalStorage && this.preferencesStore) {
        await this.saveEvents(eventsToFlush);
      }

      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `Flushed ${eventsToFlush.length} events to local storage`);
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `flush failed: ${JSON.stringify(err)}`);
      // 失败时将事件放回队列
      this.eventQueue.unshift(...this.eventQueue);
    }
  }

  /**
   * 保存事件到本地存储
   */
  private async saveEvents(events: AnalyticsEvent[]): Promise<void> {
    if (!this.preferencesStore) {
      return;
    }

    try {
      // 获取现有事件
      const existingEventsJson = await this.preferencesStore.get('events', '[]') as string;
      const existingEvents: AnalyticsEvent[] = JSON.parse(existingEventsJson);

      // 合并新事件
      const allEvents = [...existingEvents, ...events];

      // 限制总数量，防止存储过大
      const maxStorageSize = this.config.maxQueueSize * 2;
      const eventsToSave = allEvents.slice(-maxStorageSize);

      // 保存
      await this.preferencesStore.put('events', JSON.stringify(eventsToSave));
      await this.preferencesStore.flush();

      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `Saved ${events.length} events, total: ${eventsToSave.length}`);
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `saveEvents failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 加载未上传的事件
   */
  private async loadUnsentEvents(): Promise<void> {
    if (!this.preferencesStore) {
      return;
    }

    try {
      const eventsJson = await this.preferencesStore.get('events', '[]') as string;
      const events: AnalyticsEvent[] = JSON.parse(eventsJson);

      if (events.length > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `Loaded ${events.length} unsent events from storage`);
      }
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `loadUnsentEvents failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 启动定时刷新
   */
  private startFlushTimer(): void {
    if (this.flushTimer !== null) {
      clearInterval(this.flushTimer);
    }

    this.flushTimer = setInterval(() => {
      this.flush();
    }, this.config.flushInterval);
  }

  /**
   * 停止定时刷新
   */
  private stopFlushTimer(): void {
    if (this.flushTimer !== null) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
  }

  /**
   * 获取所有事件（用于查询和导出）
   */
  public async getAllEvents(): Promise<AnalyticsEvent[]> {
    if (!this.preferencesStore) {
      return [...this.eventQueue];
    }

    try {
      const eventsJson = await this.preferencesStore.get('events', '[]') as string;
      const storedEvents: AnalyticsEvent[] = JSON.parse(eventsJson);
      return [...storedEvents, ...this.eventQueue];
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `getAllEvents failed: ${JSON.stringify(err)}`);
      return [...this.eventQueue];
    }
  }

  /**
   * 查询指定类型的事件
   */
  public async getEventsByType(eventType: EventType): Promise<AnalyticsEvent[]> {
    const allEvents = await this.getAllEvents();
    return allEvents.filter(event => event.eventType === eventType);
  }

  /**
   * 查询指定时间范围的事件
   */
  public async getEventsByTimeRange(startTime: number, endTime: number): Promise<AnalyticsEvent[]> {
    const allEvents = await this.getAllEvents();
    return allEvents.filter(event =>
      event.timestamp >= startTime && event.timestamp <= endTime
    );
  }

  /**
   * 清除所有事件
   */
  public async clearAllEvents(): Promise<void> {
    try {
      this.eventQueue = [];
      if (this.preferencesStore) {
        await this.preferencesStore.put('events', '[]');
        await this.preferencesStore.flush();
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'All events cleared');
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `clearAllEvents failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 清除指定时间之前的事件
   */
  public async clearEventsBefore(timestamp: number): Promise<void> {
    try {
      if (!this.preferencesStore) {
        this.eventQueue = this.eventQueue.filter(event => event.timestamp >= timestamp);
        return;
      }

      const eventsJson = await this.preferencesStore.get('events', '[]') as string;
      const events: AnalyticsEvent[] = JSON.parse(eventsJson);
      const filteredEvents = events.filter(event => event.timestamp >= timestamp);

      await this.preferencesStore.put('events', JSON.stringify(filteredEvents));
      await this.preferencesStore.flush();

      this.eventQueue = this.eventQueue.filter(event => event.timestamp >= timestamp);

      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `Cleared events before ${timestamp}, remaining: ${filteredEvents.length}`);
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `clearEventsBefore failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 导出事件数据为 JSON 字符串
   */
  public async exportEvents(): Promise<string> {
    try {
      const allEvents = await this.getAllEvents();
      return JSON.stringify(allEvents, null, 2);
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `exportEvents failed: ${JSON.stringify(err)}`);
      return '[]';
    }
  }

  /**
   * 销毁埋点管理器
   */
  public async destroy(): Promise<void> {
    try {
      this.stopFlushTimer();
      await this.flush();
      this.eventQueue = [];
      this.preferencesStore = null;
      this.isInitialized = false;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'AnalyticsManager destroyed');
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `destroy failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 获取当前队列大小
   */
  public getQueueSize(): number {
    return this.eventQueue.length;
  }

  /**
   * 获取会话ID
   */
  public getSessionId(): string {
    return this.sessionId;
  }
}
