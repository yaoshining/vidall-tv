import abilityTest from './Ability.test';
import webdavTest from './WebDAV.test';
import fileSourceUiTest from './FileSourceUI.test';
import mediaNavigationTest from './MediaNavigation.test';
import playerSettingsTest from './PlayerSettings.test';
import scanFlowTest from './ScanFlow.test';

export default function testsuite() {
  abilityTest();
  webdavTest();
  fileSourceUiTest();
  mediaNavigationTest();
  playerSettingsTest();
  scanFlowTest();
}