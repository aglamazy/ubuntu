#!/bin/bash
# taskbot-lib.sh — helper functions sourced by taskbot.sh
# Requires: DOCS_DIR, STATE_DIR to be set by the caller.

# ── Task discovery ────────────────────────────────────────────────────

find_tasks() {
  find "$DOCS_DIR" -maxdepth 1 -name '[0-9]*-*.md' -printf '%f\n' | sort -n
}

find_task_by_index() {
  local index="$1"
  find "$DOCS_DIR" -maxdepth 1 -name "${index}-*.md" -printf '%f\n' | head -1
}

task_index() {
  echo "$1" | grep -oP '^\d+'
}

# ── Workflow + state helpers ──────────────────────────────────────────

read_workflow() {
  local task_path="$1"
  local dev_branch
  dev_branch=$(python3 -c "import json; print(json.load(open('$DOCS_DIR/taskbot.json'))['dev_branch'])" 2>/dev/null || echo "dev")
  python3 - "$task_path" "$dev_branch" <<'PYEOF'
import sys, re
task_path, dev_b = sys.argv[1], sys.argv[2]
task = open(task_path).read()
m = re.search(r'## Workflow\n(.*?)(?=\n## |\Z)', task, re.DOTALL)
if not m:
    print(f'standard:code,pr:{dev_b}:{dev_b}')
    sys.exit(0)
section = m.group(1)
def get(key, default):
    r = re.search(r'^' + key + r':\s*(.+)$', section, re.MULTILINE)
    return r.group(1).strip() if r else default
preset = get('preset', 'standard')
ops_map = {'instant': 'code,merge', 'standard': 'code,pr', 'thorough': 'code,review,run,pr'}
operations = get('operations', ops_map.get(preset, 'code,pr'))
branch_from = get('branch_from', dev_b)
merge_into = get('merge_into', dev_b)
print(f'{preset}:{operations}:{branch_from}:{merge_into}')
PYEOF
}

init_state() {
  local slug="$1" preset="$2" operations="$3" branch="$4" branch_from="$5" merge_into="$6"
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_DIR/$slug.json" "$slug" "$preset" "$operations" "$branch" "$branch_from" "$merge_into" <<'PYEOF'
import sys, json
path, slug, preset, operations, branch, branch_from, merge_into = sys.argv[1:8]
data = {
    'slug': slug,
    'preset': preset,
    'branch': branch,
    'branch_from': branch_from,
    'merge_into': merge_into,
    'operations': operations.split(','),
    'completed': ['code'],
    'pr_url': None,
}
json.dump(data, open(path, 'w'), indent=2)
PYEOF
}

mark_done() {
  local slug="$1" op="$2"
  python3 - "$STATE_DIR/$slug.json" "$op" <<'PYEOF'
import sys, json
path, op = sys.argv[1], sys.argv[2]
data = json.load(open(path))
if op not in data['completed']:
    data['completed'].append(op)
json.dump(data, open(path, 'w'), indent=2)
PYEOF
}

next_op() {
  local slug="$1"
  local state_file="$STATE_DIR/$slug.json"
  if [ ! -f "$state_file" ]; then
    echo "no_state"
    return
  fi
  python3 - "$state_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
ops = data.get('operations', [])
done = data.get('completed', [])
for op in ops:
    if op not in done:
        print(op)
        exit()
print('done')
PYEOF
}

load_state_field() {
  local slug="$1" field="$2"
  local state_file="$STATE_DIR/$slug.json"
  [ -f "$state_file" ] || { echo ""; return; }
  python3 - "$state_file" "$field" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
val = data.get(sys.argv[2], '')
print(val if val is not None else '')
PYEOF
}

set_pr_url() {
  local slug="$1" url="$2"
  python3 - "$STATE_DIR/$slug.json" "$url" <<'PYEOF'
import sys, json
path, url = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data['pr_url'] = url
json.dump(data, open(path, 'w'), indent=2)
PYEOF
}
