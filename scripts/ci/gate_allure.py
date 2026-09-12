#!/usr/bin/env python3
"""由权威门禁生成 Allure；基础设施失败单独标记，不计入真实用例统计。"""
import html
import json
from pathlib import Path
import shutil
import sys
import uuid


def generate(status_path, output):
    data = json.loads(Path(status_path).read_text(encoding='utf-8'))
    directory = Path(output)
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    cases = list(data['cases'])
    if not data['gate_passed']:
        cases.append({'name': '必需测试门禁诊断（非测试用例）', 'status': 'broken', 'message': data['reason']})
    for case in cases:
        key = str(uuid.uuid4())
        result = {'uuid': key, 'historyId': case.get('suite', data['suite']) + '#' + case['name'], 'name': case['name'], 'status': case['status'],
                  'stage': 'finished', 'labels': [{'name': 'suite', 'value': case.get('suite', data['suite'])}],
                  'statusDetails': {'message': case.get('message', '')}}
        (directory / f'{key}-result.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
    summary = '<meta charset="utf-8"><h1>必需测试门禁：' + ('通过' if data['gate_passed'] else '失败') + '</h1><pre>' + html.escape(json.dumps({k: v for k, v in data.items() if k != 'cases'}, ensure_ascii=False, indent=2)) + '</pre>'
    Path(status_path).with_name('gate-summary.html').write_text(summary, encoding='utf-8')
    # 保留权威摘要（含真实计数），诊断条目不能反向参与门禁或 portal 计数。
    (directory / 'gate-status.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def publish_latest(status_path, output):
    """外部 Allure 发布失败时，直接 latest 入口也必须指向本次结论。"""
    data = json.loads(Path(status_path).read_text(encoding='utf-8'))
    directory = Path(output)
    directory.mkdir(parents=True, exist_ok=True)
    href = 'runs/run-' + str(data['run_number']) + '/index.html'
    summary = '<meta charset="utf-8"><h1>本次必需测试门禁：' + ('通过' if data['gate_passed'] else '失败') + '</h1><pre>' + html.escape(json.dumps({k: v for k, v in data.items() if k != 'cases'}, ensure_ascii=False, indent=2)) + '</pre>'
    (directory / 'index.html').write_text(summary + '<a href="' + html.escape(href, quote=True) + '">本次报告与诊断</a>', encoding='utf-8')
    (directory / 'gate-status.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    if sys.argv[1:2] == ['--latest']:
        publish_latest(*sys.argv[2:])
    else:
        generate(*sys.argv[1:])
