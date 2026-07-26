#!/usr/bin/env bash
# Real-Herdr 0.7.4 evidence for owning-pane No Mistakes metadata, deterministic
# TTL cleanup, distinct task-specific Pi names, and shared-workspace retention.
# Every real Herdr operation is routed through the guarded named-session helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
# shellcheck source=bin/fm-herdr-version.sh
. "$ROOT/bin/fm-herdr-version.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-nm-visibility-e2e.XXXXXX")
SESSION=$($HERDR_LAB_HELPER name herdr-no-mistakes-review-visibility)
cleanup() {
  "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

STATUS=$("$HERDR_LAB_HELPER" run "$SESSION" status --json) || fail "could not read isolated Herdr status"
HERDR_VERSION=$(printf '%s' "$STATUS" | jq -r '.client.version // empty')
HERDR_PROTOCOL=$(printf '%s' "$STATUS" | jq -r '.client.protocol // empty')
[ "$HERDR_VERSION" = "$FM_HERDR_CI_VERSION" ] || fail "expected Herdr $FM_HERDR_CI_VERSION, got ${HERDR_VERSION:-empty}"
[ "$HERDR_PROTOCOL" -ge 16 ] 2>/dev/null || fail "expected Herdr protocol 16 or newer, got ${HERDR_PROTOCOL:-empty}"

CREATE=$("$HERDR_LAB_HELPER" run "$SESSION" workspace create --cwd "$TMP_ROOT" --label firstmate --no-focus) \
  || fail "could not create shared firstmate workspace"
WORKSPACE=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id // empty')
TAB_A=$("$HERDR_LAB_HELPER" run "$SESSION" tab create --workspace "$WORKSPACE" --cwd "$TMP_ROOT" --label fm-review-a --no-focus) \
  || fail "could not create first task tab"
TAB_B=$("$HERDR_LAB_HELPER" run "$SESSION" tab create --workspace "$WORKSPACE" --cwd "$TMP_ROOT" --label fm-review-b --no-focus) \
  || fail "could not create second task tab"
PANE_A=$(printf '%s' "$TAB_A" | jq -r '.result.root_pane.pane_id // empty')
PANE_B=$(printf '%s' "$TAB_B" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_A" ] && [ -n "$PANE_B" ] || fail "task tabs did not return pane ids"

"$HERDR_LAB_HELPER" run "$SESSION" pane report-agent "$PANE_A" --source firstmate.e2e --agent pi --state working --seq 1 >/dev/null \
  || fail "could not register first simulated owner"
"$HERDR_LAB_HELPER" run "$SESSION" pane report-agent "$PANE_B" --source firstmate.e2e --agent pi --state idle --seq 1 >/dev/null \
  || fail "could not register second simulated owner"

# Route production adapter calls through the same lab helper.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  local ignored_session=$1
  shift
  [ "$ignored_session" = "$SESSION" ] || return 1
  "$HERDR_LAB_HELPER" run "$SESSION" "$@"
}
# shellcheck source=bin/fm-herdr-nm-visibility-lib.sh
. "$ROOT/bin/fm-herdr-nm-visibility-lib.sh"

NAME_A=$(fm_backend_herdr_pi_worker_name firstmate review-a ship "$PANE_A") || fail "could not derive first Pi name"
NAME_B=$(fm_backend_herdr_pi_worker_name firstmate review-b ship "$PANE_B") || fail "could not derive second Pi name"
[ "$NAME_A" != "$NAME_B" ] || fail "distinct task panes derived the same Pi name"
FM_BACKEND_HERDR_PI_RENAME_POLLS=1
FM_BACKEND_HERDR_PI_RENAME_POLL_SLEEP=0
fm_backend_herdr_name_pi_worker "$SESSION:$PANE_A" "$NAME_A" || fail "could not rename first native Pi owner"
fm_backend_herdr_name_pi_worker "$SESSION:$PANE_B" "$NAME_B" || fail "could not rename second native Pi owner"

AGENTS=$("$HERDR_LAB_HELPER" run "$SESSION" agent list) || fail "could not list renamed agents"
printf '%s' "$AGENTS" | jq -e --arg ws "$WORKSPACE" --arg a "$NAME_A" --arg b "$NAME_B" '
  [.result.agents[]? | select(.workspace_id == $ws and (.name == $a or .name == $b))]
  | length == 2
    and (map(.agent) | all(. == "pi"))
    and (map(.pane_id) | unique | length == 2)
' >/dev/null || fail "Pi names were not distinct inside the one shared workspace"
pass "real Herdr lab: task-specific Pi names are distinct while both owners remain native Pi agents in one shared workspace"

# Herdr's stock first row is workspace+tab.
# The supported visual override moves the renamed `agent` field into the
# prominent first position for Pi and adds the source-scoped No Mistakes summary
# on row two.
SIDEBAR_CONFIG="$TMP_ROOT/herdr-sidebar.toml"
cat > "$SIDEBAR_CONFIG" <<'EOF'
[ui.sidebar.agents.rows_by_agent]
pi = [["state_icon", "agent", "tab"], ["state_text", "$nm_summary"]]
EOF
HERDR_CONFIG_PATH="$SIDEBAR_CONFIG" "$HERDR_LAB_HELPER" run "$SESSION" config check >/dev/null \
  || fail "Herdr rejected the documented Firstmate Pi sidebar rows"
pass "real Herdr lab: Herdr accepts the Pi sidebar layout that makes the task-specific agent name prominent"

WORKTREE="$TMP_ROOT/worktree"
STATE_DIR="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$WORKTREE" "$STATE_DIR" "$FAKEBIN"
git -C "$WORKTREE" init -q
git -C "$WORKTREE" -c user.name=Firstmate -c user.email=firstmate@example.invalid commit -q --allow-empty -m initial
git -C "$WORKTREE" checkout -qb fm/review-a
HEAD_SHA=$(git -C "$WORKTREE" rev-parse HEAD)
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "axi status") printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  "axi logs") printf '%s\n' "${FM_FAKE_REVIEW_LOG:-}" ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"
PATH="$FAKEBIN:$PATH"
export PATH
cat > "$STATE_DIR/review-a.meta" <<EOF
window=$SESSION:$PANE_A
worktree=$WORKTREE
project=/project
harness=pi
kind=ship
mode=no-mistakes
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$(printf '%s' "$TAB_A" | jq -r '.result.tab.tab_id')
herdr_pane_id=$PANE_A
EOF

FM_FAKE_AXI_STATUS=$(cat <<EOF
run:
  id: "01REALHERDRVISIBILITY"
  branch: fm/review-a
  status: running
  head: $HEAD_SHA
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,running,0,12000
EOF
)
FM_FAKE_REVIEW_LOG=$(cat <<'EOF'
reviewing changes...
pi started pid=12345
"SECRET_PROMPT must never render"
EOF
)
FM_NM_VISIBILITY_NOW=1000
FM_NM_VISIBILITY_ACTIVE_TTL_MS=45000
FM_NM_VISIBILITY_TERMINAL_TTL_MS=30000
export FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG FM_NM_VISIBILITY_NOW
export FM_NM_VISIBILITY_ACTIVE_TTL_MS FM_NM_VISIBILITY_TERMINAL_TTL_MS
fm_nm_visibility_refresh_task "$STATE_DIR" review-a || fail "active reviewer refresh failed"

ACTIVE=$("$HERDR_LAB_HELPER" run "$SESSION" agent get "$PANE_A") || fail "could not read active reviewer metadata"
printf '%s' "$ACTIVE" | jq -e --arg name "$NAME_A" '
  .result.agent.agent == "pi"
  and .result.agent.name == $name
  and (.result.agent.display_agent | startswith($name + " · No Mistakes reviewer working · 12s"))
  and .result.agent.tokens.nm_role == "reviewer"
  and .result.agent.tokens.nm_state == "working"
  and .result.agent.tokens.nm_phase == "review"
  and .result.agent.tokens.nm_elapsed == "12s"
  and .result.agent.tokens.nm_activity == "child-started"
  and (.result.agent.tokens.nm_summary | contains("reviewer working"))
  and ([.result.agent | tostring] | all(contains("SECRET_PROMPT") | not))
' >/dev/null || fail "active reviewer metadata was incomplete, displaced the owner name, or leaked private text"
pass "real Herdr lab: owning Pi row exposes bounded reviewer role/state/phase/elapsed/activity without a child agent"

# Transition the same observed review to completed, then advance the deterministic
# clock past its terminal TTL and require explicit source cleanup.
FM_FAKE_AXI_STATUS=$(cat <<EOF
run:
  id: "01REALHERDRVISIBILITY"
  branch: fm/review-a
  status: running
  head: $HEAD_SHA
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,completed,0,18000
    test,running,0,1000
EOF
)
FM_NM_VISIBILITY_NOW=1010
export FM_FAKE_AXI_STATUS FM_NM_VISIBILITY_NOW
fm_nm_visibility_refresh_task "$STATE_DIR" review-a || fail "completed reviewer refresh failed"
COMPLETED=$("$HERDR_LAB_HELPER" run "$SESSION" agent get "$PANE_A") || fail "could not read completed reviewer metadata"
printf '%s' "$COMPLETED" | jq -e '
  .result.agent.tokens.nm_state == "completed"
  and .result.agent.tokens.nm_activity == "review-completed"
' >/dev/null || fail "completed reviewer transition was not represented"

FM_NM_VISIBILITY_NOW=1041
export FM_NM_VISIBILITY_NOW
fm_nm_visibility_refresh_task "$STATE_DIR" review-a || fail "reviewer cleanup refresh failed"
CLEAN=$("$HERDR_LAB_HELPER" run "$SESSION" agent get "$PANE_A") || fail "could not read cleaned owner"
printf '%s' "$CLEAN" | jq -e --arg name "$NAME_A" '
  .result.agent as $agent
  | $agent.agent == "pi"
  and $agent.name == $name
  and ($agent.display_agent == null)
  and ($agent.title == null)
  and (($agent.state_labels // {}) | length == 0)
  and (["nm_role", "nm_state", "nm_phase", "nm_elapsed", "nm_activity", "nm_summary"]
       | all(. as $key | ($agent.tokens[$key] == null)))
' >/dev/null || fail "terminal reviewer metadata did not cleanly retire while preserving the owner name"
pass "real Herdr lab: completed activity cleans up deterministically and leaves the named owner intact"

# Native TTL is the crash/abandonment cleanup backstop.
FM_NM_VISIBILITY_ACTIVE_TTL_MS=150
export FM_NM_VISIBILITY_ACTIVE_TTL_MS
fm_nm_visibility_report "$SESSION:$PANE_A" "$NAME_A" reviewer working review 2000 reviewing active \
  || fail "short-TTL metadata report failed"
sleep 0.4
EXPIRED=$("$HERDR_LAB_HELPER" run "$SESSION" agent get "$PANE_A") || fail "could not read TTL-expired owner"
printf '%s' "$EXPIRED" | jq -e --arg name "$NAME_A" '
  .result.agent.name == $name
  and (.result.agent.display_agent == null)
  and (.result.agent.tokens.nm_summary == null)
' >/dev/null || fail "Herdr TTL did not remove abandoned review metadata"
pass "real Herdr lab: source TTL removes abandoned activity without removing the task-specific owner name"

printf 'ok - real Herdr lab validation completed on Herdr %s protocol %s\n' "$HERDR_VERSION" "$HERDR_PROTOCOL"
