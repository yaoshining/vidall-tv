import timeUtilTest from './TimeUtil.test';
import playbackContextTest from './ets/PlaybackContextTest';
import settingsControllerTest from './SettingsController.test';
import validationUtilTest from './ValidationUtil.test';
import scrapeClientTest from './ScrapeClient.test';
import debounceUtilTest from './DebounceUtil.test';
import videoDataTest from './VideoData.test';
import ijkSubtitleBridgeTest from './IjkSubtitleBridge.test';
import subtitleBridgeAdapterTest from './SubtitleBridgeAdapter.test';
import webDAVClientUtilsTest from './WebDAVClientUtils.test';
import episodeListPanelTest from './EpisodeListPanel.test';
import videoControlsTest from './VideoControls.test';
import playerPageTest from './PlayerPage.test';
import videoPlayerControllerTest from './VideoPlayerController.test';
// 需要真实 Context 和 .so 的集成测试放在 UnitTestBuild 侧（entry 模块本身，包含 native .so）
// ohosTest(entry_test HAP) 不包含 .so，不能 import VideoScannerUtil / WebDAVClient
import fileSourceDatabaseTest from './FileSourceDatabase.test';
import videoScannerTest from './VideoScanner.test';

export default function testsuite() {
  timeUtilTest();
  playbackContextTest();
  settingsControllerTest();
  validationUtilTest();
  scrapeClientTest();
  debounceUtilTest();
  videoDataTest();
  ijkSubtitleBridgeTest();
  subtitleBridgeAdapterTest();
  webDAVClientUtilsTest();
  episodeListPanelTest();
  videoControlsTest();
  playerPageTest();
  videoPlayerControllerTest();
  // 集成测试：需要设备上的真实 Context（由 TestAbility.onCreate 设置到 globalThis）
  fileSourceDatabaseTest();
  videoScannerTest();
}
