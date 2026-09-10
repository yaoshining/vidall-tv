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
  if (getTestParameter('AUTO_SCRAPE_VERIFY', 'false') === 'true') {
    videoUpsertResultTest();
    directoryPathDiffTest();
    directedScanStrategyTest();
    directedAdapterErrorsTest();
    autoScrapeFlowTest();
    return;
  }
  abilityTest();
  webdavTest();
  fileSourceUiTest();
  mediaNavigationTest();
  playerSettingsTest();
  scanFlowTest();
  incrementalScanContextChangeTest();
  autoScrapeFlowTest();
}
