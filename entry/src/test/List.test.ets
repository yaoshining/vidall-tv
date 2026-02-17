import localUnitTest from './LocalUnit.test';
import webdavTest from './WebDAV.test';
import fileSourceDatabaseTest from './FileSourceDatabase.test';

export default function testsuite() {
  localUnitTest();
  webdavTest();
  fileSourceDatabaseTest();
}