import localUnitTest from './LocalUnit.test';
import webdavTest from './WebDAV.test';
import fileSourceDatabaseTest from './FileSourceDatabase.test';
import mediaLibraryFilterTest from './MediaLibraryFilter.test';

// WebDAV 测试需要网络，已移至 ohosTest/ets/test/WebDAV.test.ets（仪器化测试）
export default function testsuite() {
  localUnitTest();
  webdavTest();
  fileSourceDatabaseTest();
  mediaLibraryFilterTest();
}