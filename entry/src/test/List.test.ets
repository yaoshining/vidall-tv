import localUnitTest from './LocalUnit.test';
import webdavTest from './WebDAV.test';
import fileSourceDatabaseTest from './FileSourceDatabase.test';
import analyticsManagerTest from './AnalyticsManager.test';
import analyticsReporterTest from './AnalyticsReporter.test';

export default function testsuite() {
  localUnitTest();
  webdavTest();
  fileSourceDatabaseTest();
  analyticsManagerTest();
  analyticsReporterTest();
}