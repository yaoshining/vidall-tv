#!/usr/bin/env python3
"""必需测试的唯一判定器；报告只读取本次判定，不从展示产物反推成功。"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from datetime import datetime, timezone


def identity():
    return f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"


def save(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def stop_owned_process(process):
    # 只终止本次启动的进程及非 hdc 后代；共享 hdc 服务及其子树不属于测试独占资源。
    def children(pid):
        try:
            rows = subprocess.run(['ps', '-axo', 'pid=,ppid=,comm='], capture_output=True, text=True).stdout
        except OSError:
            return
        for row in rows.splitlines():
            parts = row.strip().split(None, 2)
            if len(parts) == 3 and parts[1] == str(pid) and not Path(parts[2]).name.startswith('hdc'):
                yield from children(int(parts[0]))
                yield int(parts[0])
    owned = list(children(process.pid)) + [process.pid]
    for pid in owned:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        for pid in owned:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        process.wait()


def ensure_device(hdc, device, log, timeout=15, connect=False):
    """只连接明确指定的 TCP 设备，不重启服务、不改动其他连接。"""
    def query(arguments):
        log.write('hdc ' + ' '.join(arguments) + '\n')
        log.flush()
        result = subprocess.run([hdc, *arguments], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, text=True)
        log.write(result.stdout)
        log.flush()
        return result

    try:
        targets = query(['list', 'targets'])
    except subprocess.TimeoutExpired:
        return 'device_probe_timeout'
    if targets.returncode:
        return 'device_unavailable'
    if device in targets.stdout.splitlines():
        return None
    if not connect or not re.fullmatch(r'[^\s:]+:[0-9]+', device or ''):
        return 'device_unavailable'
    try:
        connected = query(['tconn', device])
    except subprocess.TimeoutExpired:
        return 'device_connect_timeout'
    if connected.returncode:
        return 'device_connect_failed'
    try:
        targets = query(['list', 'targets'])
    except subprocess.TimeoutExpired:
        return 'device_probe_timeout'
    if targets.returncode or device not in targets.stdout.splitlines():
        return 'device_unavailable'
    return None


def execute(args):
    data = {'run_id': identity(), 'started': False, 'exit_code': None, 'reason': 'not_started', 'phase': args.phase}
    save(args.execution, data)
    Path(args.log).parent.mkdir(parents=True, exist_ok=True)
    with open(args.log, 'w', encoding='utf-8') as log:
        try:
            if args.hdc:
                failure = ensure_device(args.hdc, args.device, log, args.device_timeout, args.connect)
                if failure:
                    data['reason'] = failure
                    return 1
            data.update(started=True, reason='running', started_at=time.time())
            save(args.execution, data)
            command = args.command[1:] if args.command[:1] == ['--'] else args.command
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=args.timeout)
                data.update(exit_code=code, reason='completed')
            except subprocess.TimeoutExpired:
                stop_owned_process(process)
                data.update(exit_code=124, reason='timeout')
        except subprocess.TimeoutExpired:
            data['reason'] = 'device_probe_timeout'
        except OSError as exc:
            log.write(f'无法启动测试或设备探测：{exc}\n')
            data['reason'] = 'launch_error'
        finally:
            save(args.execution, data)
    return 0 if data['exit_code'] == 0 else 1


def unit_cases(text):
    lines = [line for line in text.splitlines() if 'Tests run:' in line]
    if len(lines) != 1:
        raise ValueError('汇总行缺失或重复')
    counts = {}
    for key in ('Tests run', 'Pass', 'Failure', 'Error'):
        values = re.findall(rf'(?:^|,\s*){key}:\s*(\d+)(?=\s*(?:,|$))', lines[0])
        if len(values) != 1:
            raise ValueError(f'汇总字段 {key} 缺失或损坏')
        counts[key] = int(values[0])
    ignored = re.findall(r'(?:^|,\s*)Ignore:\s*(\d+)(?=\s*(?:,|$))', lines[0])
    if ('Ignore:' in lines[0] and len(ignored) != 1) or any(int(v) for v in ignored):
        raise ValueError('包含未执行或损坏的 Ignore 用例')
    if counts['Tests run'] != counts['Pass'] + counts['Failure'] + counts['Error']:
        raise ValueError('汇总计数不一致')
    cases, name, suite = [], None, "unit"
    for line in text.splitlines():
        if line.startswith('class='):
            suite = line[6:].strip()
        elif line.startswith('test='):
            next_name = line[5:].strip()
            if name is not None:
                # hvigor 真实输出可能在重复的 test 行尾插入 hilog 时间/PID/TID。
                # 只接受相同名称的重复，不忽略不同用例或任何结果状态。
                transport_tail = r'\d{1,2} \d{2}:\d{2}:\d{2}\.\d{3}\s+\d+\s+\d+\s*'
                if name != next_name and not re.fullmatch(re.escape(next_name) + transport_tail, name):
                    raise ValueError('用例缺少结果')
            name = next_name
        elif line.startswith('result='):
            status = {'Success': 'passed', 'Failure': 'failed', 'Error': 'broken'}.get(line[7:].strip())
            if not name or not status:
                raise ValueError('用例结果损坏')
            cases.append({'name': name, 'status': status, 'suite': suite})
            name = None
    if name is not None:
        raise ValueError('最后一个用例未完成')
    # 部分 hvigor 版本仅输出汇总；若存在逐例数据则必须和汇总完全一致。
    if cases and (len(cases) != counts['Tests run'] or
                  sum(c['status'] == 'passed' for c in cases) != counts['Pass'] or
                  sum(c['status'] == 'failed' for c in cases) != counts['Failure'] or
                  sum(c['status'] == 'broken' for c in cases) != counts['Error']):
        raise ValueError('逐例结果与汇总不一致')
    return counts['Pass'], counts['Failure'], counts['Error'], cases


def integration_cases(text):
    final = re.findall(r'^TestFinished-ResultCode:[ \t]*(-?\d+)[ \t]*$', text, re.MULTILINE)
    if final != ['0'] or text.count('TestFinished-ResultCode:') != 1:
        raise ValueError('最终 ResultCode 缺失、重复或非零')
    cases = []
    name = None
    for line in text.splitlines():
        match = re.search(r'OHOS_REPORT_STATUS:\s+test=(.+)', line)
        if match:
            next_name = match[1].strip()
            if name is not None and name != next_name:
                raise ValueError('前一个用例未完成就开始下一用例')
            name = next_name
        code = re.fullmatch(r'OHOS_REPORT_STATUS_CODE:[ \t]*(-?\d+)[ \t]*', line)
        if 'OHOS_REPORT_STATUS_CODE:' in line and not code:
            raise ValueError('逐例状态码损坏')
        if code and int(code[1]) != 1:
            if not name:
                raise ValueError('逐例状态缺少用例名')
            value = int(code[1])
            status = {0: 'passed', -2: 'failed', -1: 'broken'}.get(value)
            if status is None:
                raise ValueError('包含跳过或未知用例状态')
            cases.append({'name': name, 'status': status})
            name = None
    if name:
        raise ValueError('用例未完成')
    text_cases = re.findall(r'\[(pass|fail|error)\]\s+(\S+)', text)
    if cases and any(status != 'pass' for status, _ in text_cases) and all(c['status'] == 'passed' for c in cases):
        raise ValueError('混合协议包含失败或错误')
    if not cases:
        for status, name in re.findall(r'\[(pass|fail|error)\]\s+(\S+)', text):
            cases.append({'name': name, 'status': {'pass': 'passed', 'fail': 'failed', 'error': 'broken'}[status]})
    for field in ('numtests',):
        declared = [line for line in text.splitlines() if f'{field}=' in line and 'OHOS_REPORT_STATUS:' in line]
        values = [re.fullmatch(rf'OHOS_REPORT_STATUS:[ \t]+{field}=(\d+)[ \t]*', line) for line in declared]
        if any(value is None for value in values):
            raise ValueError('声明用例数损坏')
        expected = {int(value[1]) for value in values}
        if expected and expected != {len(cases)}:
            raise ValueError('声明用例数与实际完成数不一致')
    return (*(sum(c['status'] == status for c in cases) for status in ('passed', 'failed', 'broken')), cases)


def evaluate(args):
    result = {'suite': args.suite, 'run_id': identity(), 'status': 'not_run', 'gate_passed': False,
              'build_status': args.build, 'reason': '测试未执行（前置步骤未完成）',
              'passed': 0, 'failed': 0, 'errors': 0, 'total': 0, 'cases': [],
              'run_number': os.environ.get('GITHUB_RUN_NUMBER', 'local'),
              'commit_sha': os.environ.get('TESTED_SHA', os.environ.get('GITHUB_SHA', '')),
              'timestamp': datetime.now(timezone.utc).isoformat(),
              'run_url': f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"}
    try:
        execution = json.loads(Path(args.execution).read_text(encoding='utf-8'))
        if execution['run_id'] != identity():
            raise ValueError('执行记录属于旧运行')
        if type(execution['started']) is not bool or not isinstance(execution['reason'], str):
            raise ValueError('执行记录字段类型错误')
        reason = execution['reason']
        if execution.get('phase') == 'device_probe':
            reason = 'device_probe_timeout' if reason == 'timeout' else 'device_probe_failed'
            execution['started'] = False
        if reason == 'completed' and (execution['started'] is not True or type(execution['exit_code']) is not int or type(execution.get('started_at')) not in (int, float)):
            raise ValueError('执行完成记录缺失或损坏')
        if reason != 'completed':
            result['status'] = 'failed' if execution['started'] else 'not_run'
            result['reason'] = {'device_unavailable': '设备不可用，测试未执行', 'device_probe_timeout': '设备探测超时，测试未执行',
                                'device_probe_failed': f"设备探测失败（退出码 {execution.get('exit_code')}），测试未执行",
                                'device_connect_timeout': '指定设备连接超时，测试未执行', 'device_connect_failed': '指定设备连接失败，测试未执行',
                                'timeout': '测试执行超时', 'running': '测试中断，未完成', 'launch_error': '测试进程启动失败'}.get(reason, '测试未执行')
        else:
            result['status'] = 'failed'
            if Path(args.result).stat().st_mtime + 1 < execution['started_at']:
                raise ValueError('结果文件早于本次测试启动，拒绝旧报告')
            text = Path(args.result).read_text(encoding='utf-8')
            passed, failed, errors, cases = (unit_cases if args.suite == 'unit' else integration_cases)(text)
            result.update(passed=passed, failed=failed, errors=errors, total=passed + failed + errors, cases=cases)
            result['reason'] = '测试全部通过'
            if not result['total']:
                result.update(status='not_run', reason='实际执行用例数为 0')
            elif failed or errors:
                result['reason'] = f'存在 {failed} 个失败、{errors} 个错误'
            elif execution['exit_code'] != 0:
                result['reason'] = f"测试进程退出码非零：{execution['exit_code']}"
            elif args.build != 'success':
                result['reason'] = '编译未成功，不能判定测试通过'
            else:
                result.update(status='passed', gate_passed=True)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        result.update(status='failed' if Path(args.execution).exists() else 'not_run', reason=f'结果或执行记录缺失、损坏：{exc}')
    # 同一次隔离目录中的编译日志也参与错误诊断，前置编译失败时仍能明确 OhmUrl。
    for log in Path(args.log).parent.glob('*.log'):
        try:
            if re.search(r'Failed to resolve OhmUrl|10311002', log.read_text(encoding='utf-8', errors='replace')):
                result.update(status='failed', gate_passed=False, reason='OhmUrl 解析错误，测试未正常完成')
                break
        except OSError:
            pass
    save(args.output, result)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as summary:
            summary.write(f"\n## {args.suite} 必需测试门禁\n\n编译：{args.build}；测试：{result['status']}；门禁：{'通过' if result['gate_passed'] else '失败'}\n\n{result['reason']}\n\n实际执行 {result['total']}，通过 {result['passed']}，失败 {result['failed']}，错误 {result['errors']}。\n")
    return 0 if result['gate_passed'] else 1


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='mode', required=True)
    run = commands.add_parser('run')
    for key in ('execution', 'log'):
        run.add_argument('--' + key, required=True)
    run.add_argument('--timeout', type=float, default=90)
    run.add_argument('--phase', choices=['test', 'device_probe'], default='test')
    run.add_argument('--hdc')
    run.add_argument('--device')
    run.add_argument('--connect', action='store_true')
    run.add_argument('--device-timeout', type=float, default=15)
    run.add_argument('command', nargs=argparse.REMAINDER)
    check = commands.add_parser('evaluate')
    for key in ('suite', 'build', 'execution', 'log', 'result', 'output'):
        check.add_argument('--' + key, required=True)
    args = parser.parse_args()
    return execute(args) if args.mode == 'run' else evaluate(args)


if __name__ == '__main__':
    sys.exit(main())
