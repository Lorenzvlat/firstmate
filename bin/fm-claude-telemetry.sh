#!/usr/bin/env bash
# Own the privacy-pinned Claude Code status-line/OTLP telemetry lifecycle.
# This helper is internal to fm-spawn/fm-teardown and is always best-effort at
# those call sites so telemetry can never control worker execution.
#
# Usage:
#   fm-claude-telemetry.sh start <task-id> <owner-only-env-file>
#   fm-claude-telemetry.sh status <task-id>       # official status JSON on stdin
#   fm-claude-telemetry.sh stop <task-id>
#   fm-claude-telemetry.sh self-test
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ACTION=${1:-}

case "$ACTION:$#" in
  start:3)
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
    umask 077
    exec python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" claude-start "$STATE" "$2" "$3"
    ;;
  status:2)
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
    python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" claude-status "$STATE" "$2" >/dev/null 2>&1 || true
    exit 0
    ;;
  stop:2)
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
    python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" claude-stop "$STATE" "$2" >/dev/null 2>&1 || true
    exit 0
    ;;
  self-test:1)
    exec python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" claude-self-test
    ;;
  *)
    printf 'usage: fm-claude-telemetry.sh <start|status|stop|self-test> ...\n' >&2
    exit 2
    ;;
esac
