#!/usr/bin/env bash
# Initialize one private owner-only fm-worker-telemetry.v1 record.
# Internal spawn helper; stdout is the private writer generation nonce.
#
# Usage: fm-worker-telemetry-init.sh <task-id> <harness>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ "$#" -eq 2 ] || { printf 'usage: fm-worker-telemetry-init.sh <task-id> <harness>\n' >&2; exit 2; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
umask 077
exec python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" worker-init "$STATE" "$1" "$2"
