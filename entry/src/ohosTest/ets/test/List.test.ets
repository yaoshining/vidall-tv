import abilityTest from './Ability.test';
import webdavTest from './WebDAV.test';

export default function testsuite() {
  abilityTest();
  webdavTest();
}