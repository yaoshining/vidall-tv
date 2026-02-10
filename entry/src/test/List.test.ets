import fileOperationsTest from './File.test';
import localUnitTest from './LocalUnit.test';

export default function testsuite() {
  localUnitTest();
  fileOperationsTest();
}