import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { AnalyticsManager } from '../../../main/ets/analytics/AnalyticsManager';
import { EventType, SourceType, SubtitleFormatType, ErrorLevel, ErrorCode } from '../../../main/ets/analytics/AnalyticsTypes';

/**
 * 埋点管理器单元测试
 */
export default function AnalyticsManagerTest() {
  describe('AnalyticsManager', () => {
    let analyticsManager: AnalyticsManager;

    beforeAll(() => {
      console.info('[AnalyticsManagerTest] beforeAll');
    });

    beforeEach(() => {
      console.info('[AnalyticsManagerTest] beforeEach');
      analyticsManager = AnalyticsManager.getInstance();
    });

    afterEach(async () => {
      console.info('[AnalyticsManagerTest] afterEach');
      // 清理测试数据
      await analyticsManager.clearAllEvents();
    });

    afterAll(() => {
      console.info('[AnalyticsManagerTest] afterAll');
    });

    /**
     * 测试单例模式
     */
    it('test_singleton_instance', 0, () => {
      const instance1 = AnalyticsManager.getInstance();
      const instance2 = AnalyticsManager.getInstance();
      expect(instance1).assertEqual(instance2);
    });

    /**
     * 测试播放开始事件记录
     */
    it('test_track_play_start_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'test_video.mp4',
        sourceType: SourceType.LOCAL,
        duration: 120000
      });

      expect(analyticsManager.getQueueSize()).assertEqual(1);

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.PLAY_START);
    });

    /**
     * 测试播放准备成功事件记录
     */
    it('test_track_play_prepared_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_PREPARED,
        mediaId: 'test_video.mp4',
        sourceType: SourceType.URL,
        prepareTime: 500
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.PLAY_PREPARED);
    });

    /**
     * 测试播放失败事件记录
     */
    it('test_track_play_failed_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_FAILED,
        mediaId: 'test_video.mp4',
        sourceType: SourceType.LOCAL,
        errorCode: ErrorCode.PLAY_INIT_FAILED,
        errorMessage: 'Test error message',
        errorLevel: ErrorLevel.ERROR
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.PLAY_FAILED);
    });

    /**
     * 测试首帧时间事件记录
     */
    it('test_track_first_frame_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'test_video.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1200
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.PLAY_FIRST_FRAME);
    });

    /**
     * 测试字幕切换事件记录
     */
    it('test_track_subtitle_switch_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.SUBTITLE_SWITCH,
        mediaId: 'test_video.mp4',
        fromTrackIndex: -1,
        toTrackIndex: 0,
        subtitleFormat: SubtitleFormatType.SRT
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.SUBTITLE_SWITCH);
    });

    /**
     * 测试字幕加载成功事件记录
     */
    it('test_track_subtitle_load_success_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.SUBTITLE_LOAD_SUCCESS,
        mediaId: 'test_video.mp4',
        trackIndex: 0,
        subtitleFormat: SubtitleFormatType.EMBEDDED,
        loadTime: 300
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.SUBTITLE_LOAD_SUCCESS);
    });

    /**
     * 测试字幕加载失败事件记录
     */
    it('test_track_subtitle_load_failed_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.SUBTITLE_LOAD_FAILED,
        mediaId: 'test_video.mp4',
        trackIndex: 0,
        subtitleFormat: SubtitleFormatType.SRT,
        errorCode: ErrorCode.SUBTITLE_LOAD_FAILED,
        errorMessage: 'Failed to load subtitle',
        errorLevel: ErrorLevel.WARNING
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.SUBTITLE_LOAD_FAILED);
    });

    /**
     * 测试扫描完成事件记录
     */
    it('test_track_scan_completed_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.SCAN_COMPLETED,
        sourceId: '1',
        sourceName: 'Test Source',
        totalFiles: 100,
        successFiles: 98,
        failedFiles: 2,
        scanTime: 5000,
        coverageRate: 0.98
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.SCAN_COMPLETED);
    });

    /**
     * 测试扫描失败事件记录
     */
    it('test_track_scan_failed_event', 0, async () => {
      analyticsManager.track({
        eventType: EventType.SCAN_FAILED,
        sourceId: '1',
        sourceName: 'Test Source',
        failedFilesList: ['file1.mp4', 'file2.mkv'],
        errorCode: ErrorCode.SCAN_ACCESS_DENIED,
        errorMessage: 'Access denied',
        errorLevel: ErrorLevel.ERROR
      });

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.SCAN_FAILED);
    });

    /**
     * 测试按事件类型查询
     */
    it('test_get_events_by_type', 0, async () => {
      // 添加多个不同类型的事件
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1000
      });

      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video2.mp4',
        sourceType: SourceType.URL
      });

      const playStartEvents = await analyticsManager.getEventsByType(EventType.PLAY_START);
      expect(playStartEvents.length).assertEqual(2);
    });

    /**
     * 测试按时间范围查询
     */
    it('test_get_events_by_time_range', 0, async () => {
      const now = Date.now();

      // 添加事件
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      // 等待一小段时间
      await new Promise(resolve => setTimeout(resolve, 100));

      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1000
      });

      const events = await analyticsManager.getEventsByTimeRange(now - 1000, Date.now() + 1000);
      expect(events.length).assertEqual(2);
    });

    /**
     * 测试清空所有事件
     */
    it('test_clear_all_events', 0, async () => {
      // 添加事件
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1000
      });

      let events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(2);

      await analyticsManager.clearAllEvents();

      events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(0);
    });

    /**
     * 测试清除指定时间之前的事件
     */
    it('test_clear_events_before', 0, async () => {
      const now = Date.now();

      // 添加第一个事件
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      // 等待一段时间
      await new Promise(resolve => setTimeout(resolve, 100));
      const cutoffTime = Date.now();

      // 添加第二个事件
      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1000
      });

      await analyticsManager.clearEventsBefore(cutoffTime);

      const events = await analyticsManager.getAllEvents();
      expect(events.length).assertEqual(1);
      expect(events[0].eventType).assertEqual(EventType.PLAY_FIRST_FRAME);
    });

    /**
     * 测试导出事件数据
     */
    it('test_export_events', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      const exportedData = await analyticsManager.exportEvents();
      expect(exportedData.length).assertLarger(0);

      // 验证可以解析为 JSON
      const parsed = JSON.parse(exportedData);
      expect(Array.isArray(parsed)).assertTrue();
      expect(parsed.length).assertEqual(1);
    });

    /**
     * 测试会话 ID 生成
     */
    it('test_session_id', 0, () => {
      const sessionId = analyticsManager.getSessionId();
      expect(sessionId.length).assertLarger(0);
      expect(sessionId).assertContain('_');
    });

    /**
     * 测试队列大小
     */
    it('test_queue_size', 0, () => {
      expect(analyticsManager.getQueueSize()).assertEqual(0);

      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      expect(analyticsManager.getQueueSize()).assertEqual(1);

      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1000
      });

      expect(analyticsManager.getQueueSize()).assertEqual(2);
    });
  });
}
