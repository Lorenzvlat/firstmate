#!/usr/bin/env bash
# Guided owner-only writer for Claude's disabled-by-default manual plan snapshot.
#
# Usage:
#   fm-plan-usage-manual.sh set
#   fm-plan-usage-manual.sh --help
#
# `set` reads only the fixed Claude plan enum, canonical UTC observation and
# expiry times, a 1-12 window count, and each window's fixed slot, integer used
# percentage, integer duration in minutes, and canonical UTC reset time.
# It never accepts JSON, prose, logs, pasted UI output, account identity, paths,
# commands, credentials, or vendor data, and it never launches or reads Claude.
# The reset time must be on an exact second even though canonical input includes
# `.000Z`, because fm-plan-usage-manual.v1 stores documented Unix reset seconds.
# All input is validated through the projection's existing schema boundary
# before an owner-only exclusive creation of the fixed effective-home
# config/plan-usage-manual.json. Every existing target and unsafe config root
# is refused. Each invalid field or conflicting window identity
# receives at most three generic retries without reflecting the rejected value.
# A failed input, validation, or write leaves every existing target intact.
# FM_HOME selects the effective home; FM_CONFIG_OVERRIDE is test-only.
# Manual projection remains disabled unless the dashboard service was started
# with FM_PLAN_USAGE_MANUAL=1. An already opted-in dashboard reads a successful
# creation or operator removal on its next refresh; shared daemons need no restart.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  cat <<'EOF'
usage: fm-plan-usage-manual.sh set

set    Prompt for bounded scalar values and atomically save the fixed Claude
       fm-plan-usage-manual.v1 snapshot under the effective home's config/.

Transcribe the numeric values and UTC times shown by Claude's interactive
/usage screen. Do not paste the screen, terminal output, prose, logs, account
details, credentials, or JSON. Reset times must use canonical UTC form
YYYY-MM-DDTHH:MM:SS.000Z because the schema stores whole Unix seconds.
An invalid field or conflicting window identity receives at most three retries;
the rejected value is never printed by this command.

The manual source is disabled by default. Start the dashboard service with
FM_PLAN_USAGE_MANUAL=1 to opt in. Once opted in, creation and explicit operator
removal take effect on the next refresh without restarting Herdr or any shared daemon.
To replace or remove a snapshot, inspect and remove only the fixed
config/plan-usage-manual.json file before running set again.
EOF
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case $1 in
  set)
    command -v python3 >/dev/null 2>&1 || {
      printf 'fm-plan-usage-manual: python3 is required\n' >&2
      exit 1
    }
    ;;
esac
case $1 in
  --help|-h)
    usage
    ;;
  set)
    if ! python3 "$SCRIPT_DIR/telemetry/fm-telemetry.py" plan-manual-import "$CONFIG"; then
      printf 'fm-plan-usage-manual: refused invalid input or unsafe target; prior snapshot unchanged\n' >&2
      exit 1
    fi
    printf 'Saved Manual Claude plan snapshot. An opted-in dashboard will display it on its next refresh; no Herdr or shared-daemon restart is needed. If it is not opted in, set FM_PLAN_USAGE_MANUAL=1 before the dashboard service next starts.\n'
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
