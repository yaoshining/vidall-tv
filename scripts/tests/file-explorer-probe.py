#!/usr/bin/env python3
"""临时注入 ArkUI 对照页。先 install、构建运行取证，然后 restore；不改动用户数据。
对照版本固定为优化起点 main 的 FileExplorer，只有 loader 类型和测量钩子适配。
"""
from pathlib import Path
import subprocess, json, sys
root = Path(__file__).resolve().parents[2]
state = Path('/tmp/vidall-file-explorer-probe-backup')
core = Path('entry/src/main/ets/components/core/file')
fixture = root / 'scripts/tests/fixtures'
paths = [core/'FileExplorer.ets', Path('entry/src/main/ets/entryability/EntryAbility.ets'), Path('entry/src/main/resources/base/profile/main_pages.json')]
created = [core/'FileExplorerEager.ets', core/'FileExplorerProbeMetrics.ets', Path('entry/src/main/ets/pages/FileExplorerProbe.ets')]
if sys.argv[1] == 'restore':
    for p in paths:
        (root/p).write_bytes((state/p).read_bytes())
    for p in created:
        (root/p).unlink(missing_ok=True)
    import shutil
    shutil.rmtree(state)
    sys.exit()
if state.exists():
    raise SystemExit('已有备份，请先 restore，避免覆盖')
for p in paths:
    (state/p).parent.mkdir(parents=True, exist_ok=True)
    (state/p).write_bytes((root/p).read_bytes())
def instrument(source):
    source = "import { FileExplorerProbeMetrics as Metrics } from './FileExplorerProbeMetrics';\n" + source
    # 只统计目录 ListItem；onAppear 为实际挂树事件，不按条目数计算。
    needle = '              .borderRadius(8)'
    assert source.count(needle) == 1
    return source.replace(needle, '''              .onAppear(() => { Metrics.appear(); })
              .onDisAppear(() => { Metrics.disappear(); })
              .onVisibleAreaChange([0, 1], (visible: boolean, ratio: number) => { Metrics.visible(visible, ratio); })
''' + needle)
p = root/core/'FileExplorer.ets'
current = instrument(p.read_text())
current = current.replace('this.directory = this.controller.currentPath; }', "this.directory = this.controller.currentPath; Metrics.end = () => this.requestRow(this.controller.sortedResources.length - 1); Metrics.removeFocused = () => { this.controller.resources = this.controller.resources.filter((r: FileExplorerResource) => r.key !== this.anchorKey); }; }")
p.write_text(current)
baseline = subprocess.check_output(['git','show','32f967c9ba2387aac0e4ac129ec508f7b475c743:'+str(core/'FileExplorer.ets')], cwd=root, text=True)
baseline = "import { FileThumbnailLease } from './FileThumbnailLease';\n" + baseline.replace('export struct FileExplorer {', 'export struct FileExplorerEager {').replace("Promise<string> = () => Promise.resolve('')", "Promise<FileThumbnailLease> = () => Promise.resolve(new FileThumbnailLease(''))")
(root/core/'FileExplorerEager.ets').write_text(instrument(baseline))
(root/created[1]).write_bytes((fixture/'FileExplorerProbeMetrics.ets').read_bytes())
(root/created[2]).write_bytes((fixture/'FileExplorerProbe.ets').read_bytes())
p = root/paths[1]; p.write_text(p.read_text().replace("loadContent('pages/Index'", "loadContent('pages/FileExplorerProbe'"))
p = root/paths[2]; data=json.loads(p.read_text()); data['src'].append('pages/FileExplorerProbe'); p.write_text(json.dumps(data,indent=2))
