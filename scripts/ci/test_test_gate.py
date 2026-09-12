"""可控回归：不连接 SDK、真机或共享 hdc。"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('gate', ROOT / 'test_gate.py')
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class GateTests(unittest.TestCase):
    def setUp(self):
        summary = os.environ.pop('GITHUB_STEP_SUMMARY', None)
        if summary is not None:
            self.addCleanup(os.environ.__setitem__, 'GITHUB_STEP_SUMMARY', summary)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.execution = self.root / 'execution.json'
        self.result = self.root / 'result.txt'
        self.log = self.root / 'test.log'
        self.status = self.root / 'status.json'
        self.started = time.time() - 0.1
        self.metadata()
        self.log.write_text('')

    def metadata(self, **changes):
        data = dict(run_id=gate.identity(), started=True, reason='completed', exit_code=0, started_at=self.started)
        data.update(changes)
        self.execution.write_text(json.dumps(data))

    def check(self, text='Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0', *, suite='unit', build='success', passed=False, reason=None):
        if text is not None:
            self.result.write_text(text)
        command = [sys.executable, str(ROOT / 'test_gate.py'), 'evaluate', '--suite', suite, '--build', build,
                   '--execution', str(self.execution), '--log', str(self.log), '--result', str(self.result), '--output', str(self.status)]
        proc = subprocess.run(command, capture_output=True, text=True)
        data = json.loads(self.status.read_text())
        self.assertEqual(proc.returncode, 0 if passed else 1, proc.stderr + proc.stdout)
        self.assertEqual(data['gate_passed'], passed)
        self.assertEqual(data['status'] == 'passed', passed)
        if reason:
            self.assertIn(reason, data['reason'])
        return data

    def test_historical_unit_output_compatibility(self):
        # 实际历史工具输出，脱敏名称；不将旧文件喂给正式门禁充当本次证据。
        text = (ROOT / 'fixtures/unit-success-612.txt').read_text()
        passed, failed, errors, cases = gate.unit_cases(text)
        self.assertEqual((passed, failed, errors, len(cases)), (612, 0, 0, 612))

    def test_latest_report_replaces_old_green_on_report_failure(self):
        self.metadata(reason='device_unavailable', started=False)
        data = self.check()
        output = self.root / 'integration'
        output.mkdir()
        (output / 'index.html').write_text('STALE ALL PASSED')
        subprocess.run([sys.executable, str(ROOT / 'gate_allure.py'), '--latest', str(self.status), str(output)], check=True)
        page = (output / 'index.html').read_text()
        self.assertNotIn('STALE ALL PASSED', page)
        self.assertIn('本次必需测试门禁：失败', page)
        self.assertIn('设备不可用', page)
        self.assertEqual(json.loads((output / 'gate-status.json').read_text()), data)

    def test_normal_summary_and_details(self):
        self.check(passed=True)
        self.check('test=one\nresult=Success\nTests run: 1, Failure: 0, Error: 0, Pass: 1', passed=True)

    def test_unit_fail_closed_matrix(self):
        cases = [('', '汇总'), ('Tests run: 0, Failure: 0, Error: 0, Pass: 0', '0'),
                 ('Tests run: 1, Failure: 1, Error: 0, Pass: 0', '失败'),
                 ('Tests run: 1, Failure: 0, Error: 1, Pass: 0', '错误'),
                 ('Tests run: 1, Error: 0, Pass: 1', 'Failure'),
                 ('Tests run: 1, Failure: 0.5, Error: 0, Pass: 1', '损坏'),
                 ('Tests run: 1, Failure: 0, Error: 0, Pass: 0', '不一致'),
                 ('Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 1', 'Ignore'),
                 ('test=x\nresult=Failure\nTests run: 1, Failure: 0, Error: 0, Pass: 1', '不一致')]
        for text, reason in cases:
            with self.subTest(text=text):
                self.check(text, reason=reason)

    def test_missing_corrupt_and_stale(self):
        self.check(None, reason='缺失')
        self.execution.write_text('{')
        self.check(reason='损坏')
        self.metadata(started=False)
        self.check(reason='损坏')
        self.metadata(exit_code='0')
        self.check(reason='损坏')
        self.metadata(run_id='previous')
        self.check(reason='旧运行')
        self.metadata()
        self.result.write_text('Tests run: 1, Failure: 0, Error: 0, Pass: 1')
        os.utime(self.result, (1, 1))
        self.check(None, reason='旧报告')

    def test_prerequisites_and_process(self):
        for reason in ('device_unavailable', 'device_probe_timeout', 'timeout', 'running', 'launch_error'):
            with self.subTest(reason=reason):
                self.metadata(reason=reason, started=reason in ('timeout', 'running'))
                self.check()
        self.metadata(exit_code=7)
        self.check(reason='退出码')
        self.metadata()
        self.check(build='failure', reason='编译')
        self.execution.unlink()
        self.check(build='skipped', reason='缺失')

    def test_ohmurl_overrides_even_missing_result(self):
        self.log.write_text('Failed to resolve OhmUrl 10311002')
        self.check(None, reason='OhmUrl')
        self.check(reason='OhmUrl')

    def test_integration_matrix(self):
        self.check('[pass] one\nTestFinished-ResultCode: 0', suite='integration', passed=True)
        self.check('OHOS_REPORT_STATUS: test=one\nOHOS_REPORT_STATUS_CODE: 0\nTestFinished-ResultCode: 0', suite='integration', passed=True)
        for text in ('[pass] one\nTestFinished-ResultCode: 0\nTestFinished-ResultCode: broken',
                     'OHOS_REPORT_STATUS: test=lost\nOHOS_REPORT_STATUS: test=one\nOHOS_REPORT_STATUS_CODE: 0\nTestFinished-ResultCode: 0',
                     'OHOS_REPORT_STATUS: numtests=1oops\n[pass] one\nTestFinished-ResultCode: 0',
                     'TestFinished-ResultCode: 0', '[fail] one\nTestFinished-ResultCode: 0',
                     '[error] one\nTestFinished-ResultCode: 0', '[pass] one',
                     '[pass] one\nTestFinished-ResultCode: -1',
                     '[pass] one\nTestFinished-ResultCode: 0.5',
                     'OHOS_REPORT_STATUS: test=x\nOHOS_REPORT_STATUS_CODE: 0oops\nTestFinished-ResultCode: 0',
                     'OHOS_REPORT_STATUS: test=x\nOHOS_REPORT_STATUS_CODE: 1\nTestFinished-ResultCode: 0',
                     'OHOS_REPORT_STATUS: test=x\nOHOS_REPORT_STATUS_CODE: 0\n[fail] x\nTestFinished-ResultCode: 0'):
            with self.subTest(text=text):
                self.check(text, suite='integration')

    def test_actual_runner_timeout_exit_and_device(self):
        command = [sys.executable, str(ROOT / 'test_gate.py'), 'run', '--execution', str(self.execution), '--log', str(self.log), '--timeout', '.05']
        for code, expected in [('import time; time.sleep(5)', 'timeout'), ('raise SystemExit(8)', 'completed'), ('pass', 'completed')]:
            proc = subprocess.run(command + ['--', sys.executable, '-c', code], capture_output=True)
            data = json.loads(self.execution.read_text())
            self.assertEqual(data['reason'], expected)
            self.assertEqual(proc.returncode == 0, code == 'pass')
        fake = self.root / 'hdc'
        fake.write_text('#!/bin/sh\necho "[Empty]"\n')
        fake.chmod(0o755)
        subprocess.run(command + ['--hdc', str(fake), '--device', 'missing', '--', sys.executable, '-c', 'pass'], check=False)
        self.assertEqual(json.loads(self.execution.read_text())['reason'], 'device_unavailable')

    def test_report_failure_preserves_gate_result(self):
        self.check(passed=True)
        original = self.status.read_bytes()
        blocked = self.root / 'blocked'
        blocked.write_text('not a directory')
        proc = subprocess.run([sys.executable, str(ROOT / 'gate_allure.py'), str(self.status), str(blocked / 'output')], capture_output=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.status.read_bytes(), original)
        self.check('Tests run: 1, Failure: 1, Error: 0, Pass: 0')
        original = self.status.read_bytes()
        subprocess.run([sys.executable, str(ROOT / 'gate_allure.py'), str(self.status), str(blocked / 'output')], capture_output=True)
        self.assertEqual(self.status.read_bytes(), original)

    def test_allure_cleans_old_and_does_not_invent_pass(self):
        self.metadata(reason='device_unavailable', started=False)
        self.check()
        output = self.root / 'allure'
        output.mkdir()
        (output / 'stale-result.json').write_text('{"status":"passed"}')
        subprocess.run([sys.executable, str(ROOT / 'gate_allure.py'), str(self.status), str(output)], check=True)
        results = [json.loads(p.read_text()) for p in output.glob('*-result.json')]
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['status'], 'broken')
        self.assertEqual(json.loads(self.status.read_text())['total'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
