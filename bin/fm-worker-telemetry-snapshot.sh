#!/usr/bin/env bash
# Print the bounded read-only worker model/token projection.
#
# Usage: fm-worker-telemetry-snapshot.sh --json
# Output: fm-worker-telemetry-snapshot.v1 JSON, at most 512 KiB and 100 workers.
# docs/worker-telemetry.md owns the complete contract and source policy.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "$#" -ne 1 ] || [ "$1" != --json ]; then
  printf 'usage: fm-worker-telemetry-snapshot.sh --json\n' >&2
  exit 2
fi
if [ ! -d "$STATE" ] || [ -L "$STATE" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-worker-telemetry-snapshot: unavailable\n' >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" worker-snapshot "$STATE"
