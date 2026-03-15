import localUnitTest from './LocalUnit.test';
import fileSourceDatabaseTest from './FileSourceDatabase.test';
import scrapeClientTest from './ScrapeClient.test';
import ijkSubtitleBridgeTest from './IjkSubtitleBridge.test';
import subtitleBridgeAdapterTest from './SubtitleBridgeAdapter.test';
import webDAVClientUtilsTest from './WebDAVClientUtils.test';

// WebDAV 集成测试（需要网络）已移至 ohosTest/ets/test/WebDAV.test.ets（仪器化测试）
export default function testsuite() {
  localUnitTest();
  fileSourceDatabaseTest();
  scrapeClientTest();
  ijkSubtitleBridgeTest();
  subtitleBridgeAdapterTest();
  webDAVClientUtilsTest();
}