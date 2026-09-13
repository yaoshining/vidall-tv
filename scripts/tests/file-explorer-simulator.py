#!/usr/bin/env python3
"""对已安装的 FileExplorerProbe 执行真实模拟器输入和断言；先用 probe.py install 构建。
仅操作显式指定的模拟器，不连接、重启或清理物理设备。
"""
import argparse, json, re, subprocess, time
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--device', required=True)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--phase', choices=['performance', 'focus', 'images', 'controls', 'all'], default='all')
p.add_argument('--hdc', default='/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc')
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)

def run(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, timeout=60).stdout

def ui(*args):
    return run('devecocli', 'ui', *args, '--device', a.device)

def walk(x):
    if isinstance(x, list):
        for n in x:
            yield from walk(n)
    elif isinstance(x, dict):
        yield x
        yield from walk(x.get('children', []))

def click(mode, delay=1.5):
    ui('click', '--id', mode)
    time.sleep(delay)

def key(code, duration=0):
    args = ['uinput', '-K', '-r', str(code), str(duration)] if duration else ['uitest', 'uiInput', 'keyEvent', str(code)]
    run(a.hdc, '-t', a.device, 'shell', *args)
    time.sleep(.3)

def snapshot(name):
    raw = ui('layout', '--format', 'json')
    (a.output / (name + '.json')).write_text(raw)
    nodes = list(walk(json.loads(raw)))
    status = next(n['text'] for n in nodes if n.get('id') == 'probe-status')
    footer = next((n['text'] for n in nodes if re.fullmatch(r'\d+ / \d+', n.get('text', ''))), '')
    wm = run(a.hdc, '-t', a.device, 'shell', 'hidumper', '-s', 'WindowManagerService', '-a', '-a')
    wid = re.search(r'Focus window: (\d+)', wm).group(1)
    tree = run(a.hdc, '-t', a.device, 'shell', 'hidumper', '-s', 'WindowManagerService', '-a', f'-w {wid} -focus')
    (a.output / (name + '-focus.txt')).write_text(tree)
    focused = re.search(r'Text\(Node\*\).*idstr:(\S+)', tree)
    focus = focused.group(1) if focused else ''
    result = {'name': name, 'status': status, 'footer': footer, 'focus': focus}
    with (a.output / 'results.jsonl').open('a') as f:
        f.write(json.dumps(result, ensure_ascii=False) + '\n')
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result

def position(result):
    return tuple(map(int, result['footer'].split(' / ')))

def images(result):
    match = re.search(r'images=(\d+)/(\d+) pending=(\d+) peak=(\d+) failed=(\d+) files=(\d+)', result['status'])
    return tuple(map(int, match.groups()))

if a.phase in ['performance', 'all']:
    for count in [100, 1000, 10000]:
        for mode in ['before', 'after']:
            click(mode + str(count), 3)
            result = snapshot(mode + str(count))
            assert result['status'].startswith(f'{mode}-{count} ')
            created = int(re.search(r'created=(\d+)', result['status']).group(1))
            first = int(re.search(r'firstVisibleMs=(-?\d+)', result['status']).group(1))
            assert first >= 0
            assert created == count if mode == 'before' else 0 < created <= 12

if a.phase in ['focus', 'all']:
    click('after1000')
    key(2049); key(2013, 3000)
    initial = snapshot('hold1000'); assert position(initial)[0] > 10
    key(2090); sorted_result = snapshot('sort'); assert sorted_result['focus'] == initial['focus']
    key(2091); hidden = snapshot('hidden'); assert hidden['focus'] == initial['focus']
    key(2092); deleted = snapshot('delete-focused')
    assert deleted['focus'] and deleted['focus'] != hidden['focus']
    assert position(deleted)[1] == position(hidden)[1] - 1
    key(2095); refreshed = snapshot('refresh'); assert refreshed['focus'] == deleted['focus']
    key(2093); end = snapshot('end'); assert position(end)[0] == position(end)[1]
    key(2013, 3000); held = snapshot('end-hold'); assert held['focus'] == end['focus']
    key(2012, 3000); reverse = snapshot('reverse-hold'); assert position(reverse)[0] < position(end)[0] - 10
    click('after100')
    nodes = walk(json.loads(ui('layout', '--format', 'json')))
    row = next(n['id'] for n in nodes if n.get('id', '').startswith('explorer-row:') and n['id'].endswith(':/item-0'))
    click(row, .5); entered = snapshot('enter-folder'); assert entered['focus'].endswith(':/item-0/item-0')
    key(2094); returned = snapshot('return-folder'); assert returned['focus'].endswith(':/item-0')
    key(2016); confirmed = snapshot('confirm-folder'); assert confirmed['focus'].endswith(':/item-0/item-0')

if a.phase in ['images', 'all']:
    click('images100', 3.5)
    first = snapshot('images-first'); assert images(first)[5] > 0
    key(2049); key(2013, 3000)
    scrolled = snapshot('images-scroll'); assert images(scrolled)[3] <= 4
    click('after100', 3.5)
    clean = images(snapshot('images-released')); assert clean[0] == clean[1] and clean[2] == clean[5] == 0
    click('images100', 3.5)
    assert images(snapshot('images-reenter'))[5] > 0
    ui('screenshot', '--path', str(a.output / 'images.png'))
    click('after100', 3.5)
    clean = images(snapshot('images-final-clean')); assert clean[0] == clean[1] and clean[2] == clean[5] == 0
if a.phase in ['controls', 'all']:
    def button_id(name):
        tree = (a.output / (name + '-focus.txt')).read_text()
        found = re.search(r'Button\(Node\*\).*idstr:(\S+)', tree)
        return found.group(1) if found else ''

    click('after100')
    key(2049)
    for step in range(8):
        key(2013)
        initial = snapshot('controls-start-' + str(step))
        if initial['focus']:
            break
    assert initial['focus'].endswith(':/item-0')
    key(2012); snapshot('controls-sort-focus')
    key(2016); sorted_result = snapshot('controls-sort-ok')
    assert not sorted_result['focus']
    nodes = walk(json.loads((a.output / 'controls-sort-ok.json').read_text()))
    assert any(n.get('text') == '名称 ↓' for n in nodes)
    key(2054); enter_sorted = snapshot('controls-sort-enter')
    nodes = walk(json.loads((a.output / 'controls-sort-enter.json').read_text()))
    assert any(n.get('text') == '名称 ↑' for n in nodes)
    key(2054); snapshot('controls-sort-enter-again')
    key(2013); sorted_row = snapshot('controls-sort-reenter')
    assert sorted_row['focus'].endswith(':/item-95')
    key(2012); snapshot('controls-sort-again')
    key(2012); snapshot('controls-back-focus')
    assert button_id('controls-back-focus').endswith(':back')
    key(2015); snapshot('controls-hidden-focus')
    assert button_id('controls-hidden-focus').endswith(':hidden')
    key(2016); hidden = snapshot('controls-hidden-ok')
    assert button_id('controls-hidden-ok').endswith(':hidden')
    nodes = walk(json.loads((a.output / 'controls-hidden-ok.json').read_text()))
    assert any(n.get('text') == '95 个项目' for n in nodes)
    key(2054); snapshot('controls-hidden-enter')
    nodes = walk(json.loads((a.output / 'controls-hidden-enter.json').read_text()))
    assert any(n.get('text') == '100 个项目' for n in nodes)
    key(2054); snapshot('controls-hidden-enter-again')
    nodes = walk(json.loads((a.output / 'controls-hidden-enter-again.json').read_text()))
    assert any(n.get('text') == '95 个项目' for n in nodes)
    for step in range(4):
        key(2013)
        hidden_row = snapshot('controls-hidden-reenter-' + str(step))
        if hidden_row['focus']:
            break
    assert hidden_row['focus'].endswith(':/item-95')
    key(2016); entered = snapshot('controls-folder-enter')
    assert entered['focus'].endswith(':/item-95/item-95')
    time.sleep(1.1); counted_enter = snapshot('controls-folder-enter-count')
    assert 'folderCalls=1 exitCalls=0' in counted_enter['status']
    key(2012); snapshot('controls-child-sort')
    for step in range(4):
        key(2012); snapshot('controls-child-back-' + str(step))
        if button_id('controls-child-back-' + str(step)).endswith(':back'):
            break
    assert button_id('controls-child-back-' + str(step)).endswith(':back')
    key(2016); returned = snapshot('controls-back-ok')
    assert returned['focus'].endswith(':/item-95')
    time.sleep(1.1); counted_back = snapshot('controls-back-count')
    assert 'folderCalls=2 exitCalls=0' in counted_back['status']
    key(2054); entered_again = snapshot('controls-folder-enter-2054')
    assert entered_again['focus'].endswith(':/item-95/item-95')
    key(2012); snapshot('controls-child-sort-2054')
    for step in range(4):
        key(2012); snapshot('controls-child-back-2054-' + str(step))
        if button_id('controls-child-back-2054-' + str(step)).endswith(':back'):
            break
    assert button_id('controls-child-back-2054-' + str(step)).endswith(':back')
    key(2054); returned_again = snapshot('controls-back-ok-2054')
    assert returned_again['focus'].endswith(':/item-95')
    time.sleep(1.1); counted_again = snapshot('controls-back-count-2054')
    assert 'folderCalls=4 exitCalls=0' in counted_again['status']
    key(2013, 3000); continued = snapshot('controls-continued-hold')
    assert position(continued)[0] > 10 and position(continued)[1] == 95

print('所有所选模拟器断言通过', flush=True)
