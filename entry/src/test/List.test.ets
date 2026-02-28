import localUnitTest from './LocalUnit.test';
import webdavTest from './WebDAV.test';
import fileSourceDatabaseTest from './FileSourceDatabase.test';
import mediaLibraryFilterTest from './MediaLibraryFilter.test';

export default function testsuite() {
  localUnitTest();
  webdavTest();
  fileSourceDatabaseTest();
  mediaLibraryFilterTest();
}