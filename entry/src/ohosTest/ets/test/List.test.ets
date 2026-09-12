import { TestContext } from './TestContext';
import mediaLibraryHomeDatabaseTest from '../../../test/MediaLibraryHomeDatabase.test';
import directedAdapterErrorsTest from '../../../test/DirectedAdapterErrors.test';
import abilityTest from './Ability.test';
import webdavTest from './WebDAV.test';
import fileSourceUiTest from './FileSourceUI.test';
import mediaNavigationTest from './MediaNavigation.test';
import playerSettingsTest from './PlayerSettings.test';
import scanFlowTest from './ScanFlow.test';
import incrementalScanContextChangeTest from './IncrementalScanContextChange.test';
import autoScrapeFlowTest from './AutoScrapeFlow.test';
import { getTestParameter } from './TestParameters';
import videoUpsertResultTest from '../../../test/VideoUpsertResult.test';
import directoryPathDiffTest from '../../../test/DirectoryPathDiff.test';
import directedScanStrategyTest from '../../../test/DirectedScanStrategy.test';

export default function testsuite() {
  // 仅运行隔离数据库冒烟，避免混入页面导航、扫描或播放器测试。
  if (getTestParameter('MEDIA_LIBRARY_HOME_SMOKE', 'false') === 'true') {
    mediaLibraryHomeDatabaseTest(TestContext.require());
    return;
  }
  if (getTestParameter('AUTO_SCRAPE_VERIFY', 'false') === 'true') {
    videoUpsertResultTest();
    directoryPathDiffTest();
    directedScanStrategyTest();
    directedAdapterErrorsTest();
    autoScrapeFlowTest();
    return;
  }
  mediaLibraryHomeDatabaseTest(TestContext.require());
  abilityTest();
  webdavTest();
  fileSourceUiTest();
  mediaNavigationTest();
  playerSettingsTest();
  scanFlowTest();
  incrementalScanContextChangeTest();
  autoScrapeFlowTest();
}
