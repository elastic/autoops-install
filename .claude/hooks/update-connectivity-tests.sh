#!/bin/bash
# PostToolUse hook: when tools/check_connectivity.sh is edited, remind Claude to
# update tools/test_check_connectivity.sh to reflect the changes.
set -euo pipefail

input=$(cat)
file_path=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" <<< "$input" 2>/dev/null || echo "")

# Only trigger for the main script, not the test file or other files
if [[ "$file_path" != *"tools/check_connectivity.sh" ]] || [[ "$file_path" == *"test_"* ]]; then
  exit 0
fi

cwd=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('cwd', ''))
" <<< "$input" 2>/dev/null || echo "")

agents_md="${cwd}/AGENTS.md"
if [[ -f "$agents_md" ]]; then
  echo "tools/check_connectivity.sh was just modified. Follow the instructions in AGENTS.md:"
  echo ""
  cat "$agents_md"
else
  echo "tools/check_connectivity.sh was just modified. Please update tools/test_check_connectivity.sh to cover the changes — update affected tests and add new ones for any new behavior, then run the tests to verify they all pass."
fi
