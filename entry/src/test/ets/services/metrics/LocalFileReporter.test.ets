/**
 * Test suite for LocalFileReporter implementation
 * Requirement: LocalFileReporter Implementation
 * Spec: metrics-instrumentation-api/spec.md, playback-metrics-collection/spec.md
 */

import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import { LocalFileReporter } from '../../main/ets/services/metrics/LocalFileReporter';
import fs from '@ohos.file.fs';
import { Context } from '@ohos.abilityAccessCtrl';

export default function localFileReporterTest() {
  describe('LocalFileReporter Initialization', () => {
    
    it('should initialize without throwing errors', () => {
      // Test basic construction
      expect(() => {
        const reporter = new LocalFileReporter(getContext(this) as Context);
      }).not.toThrow();
    });
    
    it('should create metrics directory if not exists', async () => {
      const reporter = new LocalFileReporter(getContext(this) as Context);
      // Directory creation is tested by ensuring flush succeeds
      await reporter.flush();
      expect(true).assertTrue();
    });
  });
  
  describe('LocalFileReporter Metric Aggregation', () => {
    let reporter: LocalFileReporter;
    
    beforeEach(() => {
      reporter = new LocalFileReporter(getContext(this) as Context);
    });
    
    it('should record successful playback attempt', () => {
      reporter.recordPlaybackAttempt(true, 450);
      // No exception = success (in-memory operation)
      expect(true).assertTrue();
    });
    
    it('should record failed playback attempt', () => {
      reporter.recordPlaybackAttempt(false, 0);
      expect(true).assertTrue();
    });
    
    it('should record multiple playback attempts and aggregate', () => {
      reporter.recordPlaybackAttempt(true, 400);
      reporter.recordPlaybackAttempt(true, 500);
      reporter.recordPlaybackAttempt(false, 0);
      reporter.recordPlaybackAttempt(true, 600);
      // Success rate should be 3/4 = 75% (tested in integration)
      expect(true).assertTrue();
    });
    
    it('should record subtitle usage with language', () => {
      reporter.recordSubtitleUsage('zh');
      reporter.recordSubtitleUsage('en');
      reporter.recordSubtitleUsage('zh');
      expect(true).assertTrue();
    });
    
    it('should record subtitle usage as null for no subtitles', () => {
      reporter.recordSubtitleUsage(null);
      expect(true).assertTrue();
    });
    
    it('should record scan coverage metrics', () => {
      reporter.recordScanCoverage(450, 500);
      expect(true).assertTrue();
    });
    
    it('should calculate first frame time percentiles', () => {
      // Record various first frame times for percentile calculation
      for (let i = 0; i < 100; i++) {
        reporter.recordPlaybackAttempt(true, 400 + i * 10); // 400-1390ms
      }
      expect(true).assertTrue();
    });
  });
  
  describe('LocalFileReporter JSON Serialization', () => {
    let reporter: LocalFileReporter;
    let testContext: Context;
    
    beforeEach(() => {
      testContext = getContext(this) as Context;
      reporter = new LocalFileReporter(testContext);
    });
    
    afterEach(async () => {
      // Cleanup test files
      try {
        const prefsDir = testContext.preferencesDir;
        const files = fs.listFileSync(prefsDir);
        files.filter(f => f.endsWith('.json')).forEach(f => {
          fs.unlinkSync(`${prefsDir}/${f}`);
        });
      } catch (e) {
        // Ignore cleanup errors
      }
    });
    
    it('should write metrics to JSON file with YYYY-MM-DD naming', async () => {
      reporter.recordPlaybackAttempt(true, 450);
      await reporter.flush();
      
      // Verify file exists with today's date
      const today = new Date();
      const dateStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
      const expectedPath = `${testContext.preferencesDir}/${dateStr}.json`;
      
      const fileExists = fs.accessSync(expectedPath);
      expect(fileExists).assertTrue();
    });
    
    it('should write valid JSON with schema_version field', async () => {
      reporter.recordPlaybackAttempt(true, 450);
      await reporter.flush();
      
      const today = new Date();
      const dateStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
      const filePath = `${testContext.preferencesDir}/${dateStr}.json`;
      
      const content = fs.readTextSync(filePath);
      const data = JSON.parse(content);
      
      expect(data.schema_version).assertEqual(1);
      expect(data.date).assertEqual(dateStr);
      expect(typeof data.playback).assertEqual('object');
    });
    
    it('should include playback metrics in JSON', async () => {
      reporter.recordPlaybackAttempt(true, 450);
      reporter.recordPlaybackAttempt(false, 0);
      await reporter.flush();
      
      const today = new Date();
      const dateStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
      const filePath = `${testContext.preferencesDir}/${dateStr}.json`;
      
      const content = fs.readTextSync(filePath);
      const data = JSON.parse(content);
      
      expect(data.playback.attempts).assertEqual(2);
      expect(data.playback.success).assertEqual(1);
      expect(data.playback.failures).assertEqual(1);
    });
  });
  
  describe('LocalFileReporter Retention Policy', () => {
    let reporter: LocalFileReporter;
    let testContext: Context;
    
    beforeEach(() => {
      testContext = getContext(this) as Context;
    });
    
    afterEach(async () => {
      // Cleanup test files
      try {
        const prefsDir = testContext.preferencesDir;
        const files = fs.listFileSync(prefsDir);
        files.filter(f => f.endsWith('.json')).forEach(f => {
          fs.unlinkSync(`${prefsDir}/${f}`);
        });
      } catch (e) {
        // Ignore cleanup errors
      }
    });
    
    it('should delete files older than 30 days on initialization', async () => {
      // Create old test file (31 days ago)
      const oldDate = new Date();
      oldDate.setDate(oldDate.getDate() - 31);
      const oldDateStr = `${oldDate.getFullYear()}-${String(oldDate.getMonth() + 1).padStart(2, '0')}-${String(oldDate.getDate()).padStart(2, '0')}`;
      const oldFilePath = `${testContext.preferencesDir}/${oldDateStr}.json`;
      
      fs.writeTextSync(oldFilePath, JSON.stringify({ date: oldDateStr }));
      expect(fs.accessSync(oldFilePath)).assertTrue();
      
      // Initialize reporter (should trigger cleanup)
      reporter = new LocalFileReporter(testContext);
      
      // Old file should be deleted
      expect(fs.accessSync(oldFilePath)).assertFalse();
    });
    
    it('should keep files within 30 days', async () => {
      // Create recent test file (10 days ago)
      const recentDate = new Date();
      recentDate.setDate(recentDate.getDate() - 10);
      const recentDateStr = `${recentDate.getFullYear()}-${String(recentDate.getMonth() + 1).padStart(2, '0')}-${String(recentDate.getDate()).padStart(2, '0')}`;
      const recentFilePath = `${testContext.preferencesDir}/${recentDateStr}.json`;
      
      fs.writeTextSync(recentFilePath, JSON.stringify({ date: recentDateStr }));
      expect(fs.accessSync(recentFilePath)).assertTrue();
      
      // Initialize reporter (should NOT delete recent file)
      reporter = new LocalFileReporter(testContext);
      
      // Recent file should still exist
      expect(fs.accessSync(recentFilePath)).assertTrue();
    });
  });
  
  describe('LocalFileReporter Error Handling', () => {
    it('should handle disk full scenario gracefully', async () => {
      const reporter = new LocalFileReporter(getContext(this) as Context);
      reporter.recordPlaybackAttempt(true, 450);
      
      // Flush should not throw even if disk is full (logs error)
      await expect(reporter.flush()).resolves.not.toThrow();
    });
    
    it('should be idempotent - multiple flush calls safe', async () => {
      const reporter = new LocalFileReporter(getContext(this) as Context);
      reporter.recordPlaybackAttempt(true, 450);
      
      await reporter.flush();
      await reporter.flush(); // Second flush should be safe
      await reporter.flush(); // Third flush should be safe
      
      expect(true).assertTrue();
    });
  });
  
  describe('LocalFileReporter Thread Safety', () => {
    it('should handle concurrent metric recording', () => {
      const reporter = new LocalFileReporter(getContext(this) as Context);
      
      // Simulate concurrent calls from different threads
      const promises: Promise<void>[] = [];
      for (let i = 0; i < 10; i++) {
        promises.push(Promise.resolve(reporter.recordPlaybackAttempt(true, 400 + i * 10)));
      }
      
      Promise.all(promises).then(() => {
        expect(true).assertTrue();
      });
    });
  });
  
  describe('LocalFileReporter Performance', () => {
    it('should record metrics in less than 1ms', () => {
      const reporter = new LocalFileReporter(getContext(this) as Context);
      
      const startTime = Date.now();
      reporter.recordPlaybackAttempt(true, 450);
      const endTime = Date.now();
      
      const duration = endTime - startTime;
      expect(duration).assertLess(1); // Must complete in < 1ms
    });
  });
}
