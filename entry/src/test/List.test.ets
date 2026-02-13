import localUnitTest from './LocalUnit.test';
import webdavTest from './WebDAV.test';

export default function testsuite() {
  localUnitTest();
  webdavTest();
}