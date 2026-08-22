#!/usr/bin/env bash
# Print the bounded read-only Codex and Claude subscription-plan projection.
#
# Usage: fm-plan-usage-snapshot.sh --json
# Output: fm-plan-usage-snapshot.v2 JSON, at most 64 KiB.
# Codex uses only official app-server account reads and a private 60-second
# single-flight cache. Claude uses official activity-coupled status-line rate
# limits, with the fixed owner-only manual file as an explicit opt-in fallback.
# docs/worker-telemetry.md owns the complete contract and source policy.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MANUAL_ENABLED=0
[ "${FM_PLAN_USAGE_MANUAL:-0}" = 1 ] && MANUAL_ENABLED=1

if [ "$#" -ne 1 ] || [ "$1" != --json ]; then
  printf 'usage: fm-plan-usage-snapshot.sh --json\n' >&2
  exit 2
fi
if [ ! -d "$STATE" ] || [ -L "$STATE" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-plan-usage-snapshot: unavailable\n' >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" plan-snapshot "$STATE" "$MANUAL_ENABLED" "$CONFIG"
