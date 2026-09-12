#!/usr/bin/env bash
# 在外部报告和 Portal 之前发布状态；失败不更改本地权威结果。
set -euo pipefail
STATUS_JSON="$1"
STATE_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
test -s "$STATUS_JSON"
# 不将网络失败当作分支不存在，不覆盖历史。
git clone --quiet --depth 1 --branch gh-pages "$REPO_URL" "$STATE_DIR"
python3 - "$STATUS_JSON" "$STATE_DIR" "$SCRIPT_DIR" <<'PYSTATE'
import json, shutil, sys
from pathlib import Path
sys.path.insert(0, sys.argv[3])
from gate_allure import publish_latest, summary_html
source, site = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(source.read_text())
shutil.copyfile(source, site / 'integration-status.json')
publish_latest(source, site / 'integration')
run = site / 'integration' / 'runs' / ('run-' + str(data['run_number']))
run.mkdir(parents=True, exist_ok=True)
(run / 'index.html').write_text(summary_html(data), encoding='utf-8')
shutil.copyfile(source, run / 'gate-status.json')
PYSTATE
git -C "$STATE_DIR" config user.name 'github-actions[bot]'
git -C "$STATE_DIR" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$STATE_DIR" add integration-status.json integration/index.html integration/gate-status.json integration/runs/
if ! git -C "$STATE_DIR" diff --cached --quiet; then
  git -C "$STATE_DIR" commit -m '更新：在报告发布前保存集成测试门禁状态'
  git -C "$STATE_DIR" push origin HEAD:gh-pages
fi
