#!/usr/bin/env bash
# Deterministic behavior tests for the read-only No Mistakes activity projection
# and task-specific Pi worker naming on Herdr.
# Static source assertions below intentionally match literal shell variables.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-nm-visibility)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
WORKTREE="$TMP_ROOT/worktree"
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_LOG="$TMP_ROOT/herdr.log"
NM_LOG="$TMP_ROOT/no-mistakes.log"
AGENT_NAME_FILE="$TMP_ROOT/agent-name"
mkdir -p "$STATE" "$FAKEBIN" "$WORKTREE"
fm_git_identity
fm_git_init_commit "$WORKTREE"
git -C "$WORKTREE" checkout -qb fm/review-task
HEAD_SHA=$(git -C "$WORKTREE" rev-parse HEAD)

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"
case "${1:-} ${2:-}" in
  "axi status") printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  "axi logs") printf '%s\n' "${FM_FAKE_REVIEW_LOG:-}" ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
SH
chmod +x "$FAKEBIN/herdr"
PATH="$FAKEBIN:$PATH"
export PATH FM_FAKE_NM_LOG="$NM_LOG"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-herdr-nm-visibility-lib.sh
. "$ROOT/bin/fm-herdr-nm-visibility-lib.sh"
# shellcheck source=bin/fm-spawn-rollback-lib.sh
. "$ROOT/bin/fm-spawn-rollback-lib.sh"

FM_FAKE_METADATA_CAPABLE=1
FM_FAKE_AGENT_IDENTITY=pi
export FM_FAKE_METADATA_CAPABLE FM_FAKE_AGENT_IDENTITY

# Every fake Herdr call is unit-separated so assertions cannot confuse argument
# boundaries with spaces inside human-facing labels.
fm_backend_herdr_cli() {
  local session=$1 arg name current_name=
  shift
  {
    printf 'session=%s' "$session"
    for arg in "$@"; do printf '\x1f%s' "$arg"; done
    printf '\n'
  } >> "$HERDR_LOG"
  case "${1:-} ${2:-}" in
    "agent get")
      [ ! -f "$AGENT_NAME_FILE" ] || current_name=$(cat "$AGENT_NAME_FILE")
      printf '{"result":{"agent":{"agent":"%s","name":"%s","agent_status":"working"}}}\n' "$FM_FAKE_AGENT_IDENTITY" "$current_name"
      ;;
    "agent rename")
      name=${4:-}
      printf '%s' "$name" > "$AGENT_NAME_FILE"
      printf '{"result":{"agent":{"agent":"pi","name":"%s"}}}\n' "$name"
      ;;
    *) printf '{}\n' ;;
  esac
}

fm_nm_visibility_bounded_herdr() {
  local session=$1
  shift
  fm_backend_herdr_cli "$session" "$@"
}

fm_nm_visibility_herdr_metadata_capable() {
  if [ "$FM_FAKE_METADATA_CAPABLE" = 1 ]; then
    FM_NM_VISIBILITY_CAPABILITY_RESULT=supported
    return 0
  fi
  FM_NM_VISIBILITY_CAPABILITY_RESULT=unsupported
  return 1
}

write_meta() { # [backend] [harness]
  local backend=${1:-herdr} harness=${2:-pi}
  fm_write_meta "$STATE/review-task.meta" \
    'window=fmtest:w1:p2' \
    "worktree=$WORKTREE" \
    'project=/project' \
    "harness=$harness" \
    'kind=ship' \
    'mode=no-mistakes' \
    "backend=$backend" \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2'
}

status_with_review() { # <review-status> <duration-ms> [top-status] [outcome] [error]
  local review=$1 duration=$2 top=${3:-running} outcome=${4:-} error=${5:-}
  cat <<EOF
run:
  id: "01VISIBILITYRUN"
  branch: fm/review-task
  status: $top
  head: $HEAD_SHA
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,$review,0,$duration
    test,pending,0,0
EOF
  [ -z "$outcome" ] || printf 'outcome: %s\n' "$outcome"
  [ -z "$error" ] || printf 'error: "%s"\n' "$error"
}

status_waiting_for_captain() {
  cat <<EOF
run:
  id: "01VISIBILITYRUN"
  branch: fm/review-task
  status: awaiting_approval
  awaiting_agent: parked 25s
  head: $HEAD_SHA
  findings[1]{id,severity,file,line,action,description}:
    r1,error,secret.go,,ask-user,contains TOP_SECRET_PROMPT
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,fix_review,1,25000
    test,pending,0,0
gate: review
EOF
}

reset_case() {
  : > "$HERDR_LOG"
  : > "$NM_LOG"
  rm -f "$AGENT_NAME_FILE"
  rm -f "$STATE/review-task.herdr-nm-activity"
  rm -f "$STATE"/review-task-*.meta "$STATE/ineligible.meta"
  write_meta
  FM_FAKE_METADATA_CAPABLE=1
  FM_FAKE_AGENT_IDENTITY=pi
  FM_FAKE_AXI_STATUS=
  FM_FAKE_REVIEW_LOG=
  FM_NM_VISIBILITY_NOW=1000
  FM_NM_VISIBILITY_ACTIVE_TTL_MS=45000
  FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS=45000
  FM_NM_VISIBILITY_TERMINAL_TTL_MS=30000
  export FM_FAKE_METADATA_CAPABLE FM_FAKE_AGENT_IDENTITY FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG
  export FM_NM_VISIBILITY_NOW FM_NM_VISIBILITY_ACTIVE_TTL_MS FM_NM_VISIBILITY_TERMINAL_TTL_MS
}

assert_observational_only() {
  local calls=$1
  assert_not_contains "$calls" $'\x1f''agent'$'\x1f''send' "visibility attempted to steer an agent"
  assert_not_contains "$calls" $'\x1f''pane'$'\x1f''send-text' "visibility attempted to type into a pane"
  assert_not_contains "$calls" $'\x1f''pane'$'\x1f''send-keys' "visibility attempted to send a key"
  assert_not_contains "$calls" $'\x1f''pane'$'\x1f''close' "visibility attempted to close a pane"
  assert_not_contains "$calls" $'\x1f''agent'$'\x1f''start' "visibility attempted to start an agent"
  assert_not_contains "$calls" $'\x1f''agent'$'\x1f''rename' "review visibility attempted to rename the owner"
}

test_active_reviewer_is_visible_and_bounded() {
  local calls cache
  reset_case
  FM_FAKE_AXI_STATUS=$(status_with_review running 12000)
  FM_FAKE_REVIEW_LOG=$(cat <<'EOF'
step: review
  reviewing changes...
  claude started pid=4242
  "PROMPT_TEXT=do not expose me"
EOF
)
  export FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG

  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  cache=$(cat "$STATE/review-task.herdr-nm-activity")
  assert_contains "$calls" $'\x1f''pane'$'\x1f''report-metadata'$'\x1f''w1:p2' "active reviewer did not use owning-pane metadata"
  assert_contains "$calls" $'\x1f''--display-agent'$'\x1f''Pi · firstmate/review-task [w1:p2] · No Mistakes reviewer working · 12s · child started' "active reviewer display omitted identity, role, state, elapsed time, or activity"
  assert_contains "$calls" $'\x1f''--token'$'\x1f''nm_role=reviewer' "active reviewer role token missing"
  assert_contains "$calls" $'\x1f''--token'$'\x1f''nm_phase=review' "active reviewer phase token missing"
  assert_contains "$calls" $'\x1f''--ttl-ms'$'\x1f''45000' "active reviewer metadata lacks bounded TTL"
  assert_contains "$cache" 'state=working' "active reviewer cache state mismatch"
  assert_not_contains "$calls$cache" '4242' "review visibility exposed a child pid"
  assert_not_contains "$calls$cache" 'PROMPT_TEXT' "review visibility exposed prompt text"
  assert_observational_only "$calls"
  pass "active reviewer exposes safe role/state/phase/elapsed/activity metadata on the owning pane"
}

test_active_fixer_is_distinct() {
  local calls
  reset_case
  FM_FAKE_AXI_STATUS=$(status_with_review fixing 61000 fixing)
  FM_FAKE_REVIEW_LOG=$'user-fix round starting after round 2 (4 findings selected)\nasking agent to fix identified issues...\nclaude started pid=99'
  export FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG

  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''nm_role=fixer' "fixer role token missing"
  assert_contains "$calls" $'\x1f''nm_phase=fix' "fixer phase token missing"
  assert_contains "$calls" 'No Mistakes fixer working · 1m1s · child started' "fixer summary omitted state, elapsed time, or activity"
  pass "active fixer is represented separately from a reviewer"
}

test_waiting_for_captain_is_accurate() {
  local calls
  reset_case
  FM_FAKE_AXI_STATUS=$(status_waiting_for_captain)
  FM_FAKE_REVIEW_LOG='TOP_SECRET_REVIEWER_PROSE'
  export FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG

  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''nm_state=waiting-for-captain' "captain wait state token missing"
  assert_contains "$calls" $'\x1f''nm_phase=decision' "captain wait phase token missing"
  assert_contains "$calls" 'decision requested' "captain wait activity missing"
  assert_not_contains "$calls" 'TOP_SECRET' "captain wait exposed finding or reviewer text"
  pass "waiting-for-captain is represented without exposing the decision prompt"
}

prime_active_cache() {
  FM_FAKE_AXI_STATUS=$(status_with_review running 5000)
  FM_FAKE_REVIEW_LOG='reviewing changes...'
  export FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG
  fm_nm_visibility_refresh_task "$STATE" review-task
  : > "$HERDR_LOG"
}

test_failed_transition_is_one_shot() {
  local calls
  reset_case
  prime_active_cache
  FM_NM_VISIBILITY_NOW=1010
  FM_FAKE_AXI_STATUS=$(status_with_review failed 20000 failed failed 'review agent exited unsuccessfully; API_KEY=secret')
  FM_FAKE_REVIEW_LOG=$'claude exited pid=777 error=claude exited: exit status 1: SECRET_COMMAND --token abc'
  export FM_NM_VISIBILITY_NOW FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG

  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''nm_state=failed' "failed reviewer state token missing"
  assert_contains "$calls" $'\x1f''--ttl-ms'$'\x1f''30000' "failed reviewer did not use terminal TTL"
  assert_not_contains "$calls" 'API_KEY' "failed reviewer exposed raw error text"
  assert_not_contains "$calls" 'SECRET_COMMAND' "failed reviewer exposed a complete command"
  assert_not_contains "$calls" '777' "failed reviewer exposed a pid"
  pass "failed reviewer transition is accurate, bounded, and redacted"
}

test_timed_out_transition_is_distinct() {
  local calls
  reset_case
  prime_active_cache
  FM_NM_VISIBILITY_NOW=1010
  FM_FAKE_AXI_STATUS=$(status_with_review failed 30000 failed failed 'review agent timed out while running SECRET --credential value')
  FM_FAKE_REVIEW_LOG='agent prose containing credentials must not escape'
  export FM_NM_VISIBILITY_NOW FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG

  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''nm_state=timed-out' "timed-out reviewer state token missing"
  assert_contains "$calls" 'review timed out' "timed-out reviewer activity missing"
  assert_not_contains "$calls" 'SECRET' "timed-out reviewer exposed raw timeout context"
  assert_not_contains "$calls" 'credential' "timed-out reviewer exposed a credential marker"
  pass "timed-out reviewer is distinct from generic failure and remains private"
}

test_completed_transition_cleans_up_deterministically() {
  local calls before after cache
  reset_case
  prime_active_cache
  FM_NM_VISIBILITY_NOW=1010
  FM_FAKE_AXI_STATUS=$(status_with_review completed 18000 running)
  FM_FAKE_REVIEW_LOG='reviewer final prose must not escape'
  export FM_NM_VISIBILITY_NOW FM_FAKE_AXI_STATUS FM_FAKE_REVIEW_LOG

  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''nm_state=completed' "completed reviewer state token missing"
  assert_contains "$calls" $'\x1f''--ttl-ms'$'\x1f''30000' "completed reviewer did not use terminal TTL"

  FM_NM_VISIBILITY_NOW=1041
  export FM_NM_VISIBILITY_NOW
  fm_nm_visibility_refresh_task "$STATE" review-task
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''--clear-title'$'\x1f''--clear-display-agent'$'\x1f''--clear-state-labels' "expired completed reviewer was not explicitly cleared"
  assert_contains "$calls" $'\x1f''--clear-token'$'\x1f''nm_summary' "expired completed reviewer summary token was not cleared"
  cache=$(cat "$STATE/review-task.herdr-nm-activity")
  assert_contains "$cache" 'state=retired' "completed reviewer cache was not retired"
  before=$(wc -l < "$HERDR_LOG" | tr -d '[:space:]')
  FM_NM_VISIBILITY_NOW=1100
  export FM_NM_VISIBILITY_NOW
  fm_nm_visibility_refresh_task "$STATE" review-task
  after=$(wc -l < "$HERDR_LOG" | tr -d '[:space:]')
  [ "$before" = "$after" ] || fail "retired completed reviewer was republished"
  pass "completed reviewer is shown once, cleared after its TTL, and never accumulates"
}

test_unsupported_capability_falls_back_without_side_effects() {
  reset_case
  FM_FAKE_METADATA_CAPABLE=0
  FM_FAKE_AXI_STATUS=$(status_with_review running 12000)
  export FM_FAKE_METADATA_CAPABLE FM_FAKE_AXI_STATUS

  fm_nm_visibility_refresh_task "$STATE" review-task
  [ ! -s "$HERDR_LOG" ] || fail "unsupported metadata capability still called Herdr"
  [ ! -s "$NM_LOG" ] || fail "unsupported metadata capability still queried No Mistakes"
  [ ! -e "$STATE/review-task.herdr-nm-activity" ] || fail "unsupported metadata capability created a cache"
  pass "unsupported Herdr metadata capability degrades to a silent no-op"
}

test_non_herdr_backend_is_unchanged() {
  reset_case
  write_meta tmux pi
  FM_FAKE_AXI_STATUS=$(status_with_review running 12000)
  export FM_FAKE_AXI_STATUS

  fm_nm_visibility_refresh_task "$STATE" review-task
  [ ! -s "$HERDR_LOG" ] || fail "non-Herdr task called Herdr visibility"
  [ ! -s "$NM_LOG" ] || fail "non-Herdr task queried No Mistakes visibility"
  pass "non-Herdr backends retain their existing behavior"
}

test_pi_worker_name_is_unique_and_verified() {
  local name calls
  reset_case
  name=$(fm_backend_herdr_pi_worker_name firstmate review-task ship w1:p2) || fail "could not derive Pi worker name"
  [ "$name" = 'Pi · firstmate/review-task [w1:p2]' ] || fail "unexpected Pi worker name: $name"
  # shellcheck disable=SC2034 # Read by the dynamically sourced Herdr backend.
  FM_BACKEND_HERDR_PI_RENAME_POLLS=1
  # shellcheck disable=SC2034 # Read by the dynamically sourced Herdr backend.
  FM_BACKEND_HERDR_PI_RENAME_POLL_SLEEP=0
  fm_backend_herdr_name_pi_worker fmtest:w1:p2 "$name" || fail "Pi worker rename failed"
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''agent'$'\x1f''get'$'\x1f''w1:p2' "Pi worker rename did not verify native identity"
  assert_contains "$calls" $'\x1f''agent'$'\x1f''rename'$'\x1f''w1:p2'$'\x1f''Pi · firstmate/review-task [w1:p2]' "Pi worker rename did not apply the task-specific name"
  [ "$(grep -c $'\x1f''agent'$'\x1f''get'$'\x1f''w1:p2' "$HERDR_LOG")" -eq 2 ] || fail "Pi worker rename did not re-read the registered identity"
  assert_not_contains "$calls" $'\x1f''workspace'$'\x1f''rename' "Pi worker naming changed the shared workspace"
  assert_not_contains "$calls" $'\x1f''tab'$'\x1f''rename' "Pi worker naming changed the task tab"
  pass "Pi worker naming preserves native identity and shared workspace/tab topology"
}

test_pi_worker_name_waits_for_delayed_registration() {
  local name calls_file="$TMP_ROOT/delayed-calls" renamed_file="$TMP_ROOT/delayed-name" calls
  reset_case
  printf '0' > "$calls_file"
  name=$(fm_backend_herdr_pi_worker_name firstmate delayed ship w1:p3)
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced Herdr naming helper.
  fm_backend_herdr_cli() {
    local count
    case "${2:-} ${3:-}" in
      "agent get")
        count=$(cat "$calls_file")
        count=$((count + 1))
        printf '%s' "$count" > "$calls_file"
        if [ "$count" -lt 3 ]; then
          printf '{"result":{"agent":null}}\n'
        else
          printf '{"result":{"agent":{"agent":"pi","name":"%s"}}}\n' "$([ ! -f "$renamed_file" ] || cat "$renamed_file")"
        fi
        ;;
      "agent rename")
        printf '%s' "${5:-}" > "$renamed_file"
        printf '{"result":{"agent":{"agent":"pi","name":"%s"}}}\n' "${5:-}"
        ;;
    esac
  }
  FM_BACKEND_HERDR_PI_RENAME_POLLS=3
  FM_BACKEND_HERDR_PI_RENAME_POLL_SLEEP=0
  fm_backend_herdr_name_pi_worker fmtest:w1:p3 "$name" || fail "delayed Pi registration was not accepted"
  calls=$(cat "$calls_file")
  [ "$calls" -eq 4 ] || fail "delayed registration was not followed by final verification"
  pass "Pi worker naming waits for delayed native registration"
}

test_pi_worker_name_fails_on_collision() {
  local name
  reset_case
  name=$(fm_backend_herdr_pi_worker_name firstmate collision ship w1:p4)
  fm_backend_herdr_cli() {
    case "${2:-} ${3:-}" in
      "agent get") printf '{"result":{"agent":{"agent":"pi","name":""}}}\n' ;;
      "agent rename") return 1 ;;
    esac
  }
  FM_BACKEND_HERDR_PI_RENAME_POLLS=1
  FM_BACKEND_HERDR_PI_RENAME_POLL_SLEEP=0
  if fm_backend_herdr_name_pi_worker fmtest:w1:p4 "$name"; then
    fail "Pi name collision was accepted"
  fi
  pass "Pi worker naming fails closed on a name collision"
}

test_pi_prominence_requires_exact_valid_config() {
  local config="$TMP_ROOT/herdr-config.toml"
  herdr() {
    [ "${1:-} ${2:-}" = "config check" ]
  }
  HERDR_CONFIG_PATH=$config
  export HERDR_CONFIG_PATH
  printf '[ui.sidebar.agents.rows_by_agent]\npi = [["state_icon", "workspace", "tab"], ["agent"]]\n' > "$config"
  if fm_backend_herdr_pi_prominent_configured; then
    fail "generic Herdr Pi row satisfied the prominence invariant"
  fi
  printf '[ui.sidebar.agents.rows_by_agent]\npi = [["state_icon", "agent", "tab"], ["state_text", "$nm_summary"]]\n' > "$config"
  fm_backend_herdr_pi_prominent_configured || fail "documented prominent Pi row was rejected"
  pass "Herdr Pi prominence requires the exact validated sidebar row"
}

test_pi_worker_name_refuses_non_pi_identity() {
  local name calls status
  reset_case
  name=$(fm_backend_herdr_pi_worker_name firstmate review-task ship w1:p2)
  FM_FAKE_AGENT_IDENTITY=claude
  export FM_FAKE_AGENT_IDENTITY
  # shellcheck disable=SC2034 # Read by the dynamically sourced Herdr backend.
  FM_BACKEND_HERDR_PI_RENAME_POLLS=1
  # shellcheck disable=SC2034 # Read by the dynamically sourced Herdr backend.
  FM_BACKEND_HERDR_PI_RENAME_POLL_SLEEP=0
  fm_backend_herdr_name_pi_worker fmtest:w1:p2 "$name" >/dev/null 2>&1
  status=$?
  [ "$status" = 2 ] || fail "non-Pi identity should return 2 without mutation, got $status"
  calls=$(cat "$HERDR_LOG")
  assert_not_contains "$calls" $'\x1f''agent'$'\x1f''rename' "non-Pi identity was renamed"
  pass "Pi worker naming never renames a shell or another harness"
}

test_spawn_applies_pi_name_after_launch_only_on_herdr() {
  local source enter_line condition_line rename_line success_line
  source=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$source" 'if [ "$BACKEND" = herdr ] && [ "$HARNESS" = pi ]; then' "spawn lost the Herdr+Pi-only naming condition"
  assert_contains "$source" 'fm_backend_herdr_pi_prominent_configured' "spawn does not preflight the prominent Pi presentation"
  assert_contains "$source" 'fm_backend_herdr_projection_close_pane_focus_preserving "$HERDR_SES" "$HERDR_PANE_ID"' "failed Pi identity does not clean up only its exact pane"
  assert_contains "$source" 'fm_backend_herdr_pane_agent_state "$HERDR_SES" "$HERDR_PANE_ID"' "failed Pi identity does not verify exact pane closure"
  assert_contains "$source" 'fm_spawn_identity_rollback' "failed Pi identity bypasses complete spawn rollback"
  assert_contains "$source" 'add the following to $HERDR_PI_CONFIG and retry' "missing Pi presentation config lacks remediation"
  enter_line=$(grep -nF 'spawn_send_key "$T" Enter' "$ROOT/bin/fm-spawn.sh" | tail -1 | cut -d: -f1)
  condition_line=$(grep -nF 'if [ "$BACKEND" = herdr ] && [ "$HARNESS" = pi ]; then' "$ROOT/bin/fm-spawn.sh" | tail -1 | cut -d: -f1)
  rename_line=$(grep -nF 'fm_backend_herdr_name_pi_worker "$T" "$HERDR_PI_NAME"' "$ROOT/bin/fm-spawn.sh" | tail -1 | cut -d: -f1)
  success_line=$(grep -nF 'echo "spawned $ID harness=' "$ROOT/bin/fm-spawn.sh" | tail -1 | cut -d: -f1)
  [ "$enter_line" -lt "$condition_line" ] || fail "Pi naming ran before the worker launch was submitted"
  [ "$condition_line" -lt "$rename_line" ] || fail "Pi naming call escaped its Herdr+Pi condition"
  [ "$rename_line" -lt "$success_line" ] || fail "spawn reported success before attempting the Pi name"
  pass "new Herdr-backed Pi workers receive their task name after launch and before spawn success"
}

test_pi_identity_rollback_restores_metadata_on_failure() {
  local root="$TMP_ROOT/rollback-root" home="$TMP_ROOT/rollback-home"
  local state="$home/state" id=rollback-task task_tmp="/tmp/fm-rollback-task"
  mkdir -p "$root/bin" "$state" "$task_tmp"
  printf 'window=fmtest:w1:p9\nworktree=/worktree\nkind=ship\n' > "$state/$id.meta"
  cat > "$root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
rm -f "$FM_HOME/state/rollback-task.meta"
exit 19
SH
  chmod +x "$root/bin/fm-teardown.sh"
  if fm_spawn_identity_rollback "$root" "$home" "$state" "$id" ship "$task_tmp" >/dev/null 2>&1; then
    fail "failed delegated rollback reported success"
  fi
  assert_grep 'worktree=/worktree' "$state/$id.meta" "failed rollback did not restore diagnostic metadata"
  rm -rf "$task_tmp"
  pass "failed Pi identity rollback retains metadata for deterministic recovery"
}

test_secondmate_pi_identity_rollback_preserves_home() {
  local root="$TMP_ROOT/secondmate-rollback-root" home="$TMP_ROOT/secondmate-rollback-home"
  local state="$home/state" id=secondmate-task task_tmp="/tmp/fm-secondmate-task"
  mkdir -p "$root/bin" "$state" "$task_tmp" "$home/preserved"
  printf 'window=fmtest:w1:p10\nworktree=%s\nkind=secondmate\n' "$home" > "$state/$id.meta"
  : > "$state/$id.pi-ext.ts"
  fm_spawn_identity_rollback "$root" "$home" "$state" "$id" secondmate "$task_tmp" \
    || fail "secondmate identity rollback failed"
  [ -d "$home/preserved" ] || fail "secondmate rollback removed the persistent home"
  [ ! -e "$task_tmp" ] || fail "secondmate rollback retained task temp"
  [ ! -e "$state/$id.meta" ] || fail "secondmate rollback retained successful-spawn metadata"
  pass "secondmate Pi identity rollback preserves its persistent home"
}

test_cleanup_removes_only_the_private_visibility_cache() {
  local source
  source=$(cat "$ROOT/bin/fm-teardown.sh")
  assert_contains "$source" '"$STATE/$ID.herdr-nm-activity"' "ordinary cleanup does not remove the No Mistakes visibility cache"
  assert_contains "$source" '"$sub_state/$child_id.herdr-nm-activity"' "secondmate-child cleanup does not remove the visibility cache"
  assert_not_contains "$source" 'pane report-metadata' "cleanup gained Herdr metadata mutation instead of relying on pane close and TTL"
  pass "task cleanup removes the private visibility cache without adding reviewer lifecycle control"
}

test_watcher_owns_the_regular_observation_tick() {
  local source
  source=$(cat "$ROOT/bin/fm-watch.sh")
  assert_contains "$source" '. "$SCRIPT_DIR/fm-herdr-nm-visibility-lib.sh"' "watcher does not load the visibility owner"
  assert_contains "$source" 'fm_nm_visibility_refresh_all "$STATE" || true' "watcher does not refresh review visibility"
  assert_not_contains "$(cat "$ROOT/bin/fm-herdr-nm-visibility-lib.sh")" 'no-mistakes axi respond' "visibility owner can respond to a No Mistakes gate"
  assert_not_contains "$(cat "$ROOT/bin/fm-herdr-nm-visibility-lib.sh")" 'no-mistakes axi abort' "visibility owner can abort a No Mistakes run"
  pass "the existing watcher refreshes observation without acquiring No Mistakes lifecycle control"
}

test_zero_elapsed_does_not_cross_run_cache() {
  reset_case
  FM_NM_VISIBILITY_NOW=100
  FM_FAKE_AXI_STATUS=$(status_with_review running 12000)
  fm_nm_visibility_refresh_task "$STATE" review-task
  FM_NM_VISIBILITY_NOW=110
  FM_FAKE_AXI_STATUS=$(status_with_review running 0 | sed 's/01VISIBILITYRUN/01VISIBILITYRUNB/')
  fm_nm_visibility_refresh_task "$STATE" review-task
  assert_contains "$(cat "$STATE/review-task.herdr-nm-activity")" 'elapsed_ms=0' "new run inherited prior elapsed cache"
  pass "zero elapsed starts fresh when the observed run changes"
}

test_invalid_log_tail_falls_back_and_preserves_hints() {
  local bad
  for bad in invalid -4; do
    reset_case
    FM_NM_VISIBILITY_REVIEW_LOG_TAIL=$bad
    FM_FAKE_AXI_STATUS=$(status_with_review running 5000)
    FM_FAKE_REVIEW_LOG='asking agent to fix identified issues...'
    fm_nm_visibility_refresh_task "$STATE" review-task
    assert_contains "$(cat "$STATE/review-task.herdr-nm-activity")" 'role=fixer' "invalid log tail lost parsed role hint"
    assert_contains "$(cat "$STATE/review-task.herdr-nm-activity")" 'phase=fix' "invalid log tail lost parsed phase hint"
  done
  FM_NM_VISIBILITY_REVIEW_LOG_TAIL=200
  pass "invalid and negative log tails use the safe default without losing hints"
}

test_top_level_failure_without_review_failure_is_visible() {
  local review
  for review in pending skipped absent; do
    reset_case
    FM_FAKE_AXI_STATUS=$(status_with_review running 1000)
    fm_nm_visibility_refresh_task "$STATE" review-task
    if [ "$review" = absent ]; then
      FM_FAKE_AXI_STATUS=$(status_with_review pending 0 failed failed | grep -v 'review,pending')
    else
      FM_FAKE_AXI_STATUS=$(status_with_review "$review" 0 failed failed)
    fi
    fm_nm_visibility_refresh_task "$STATE" review-task
    assert_contains "$(cat "$STATE/review-task.herdr-nm-activity")" 'state=failed' "top-level failure was hidden for review=$review"
  done
  pass "top-level failure remains visible without terminal review detail"
}

test_refresh_cycle_is_bounded_and_fair() {
  local seen
  reset_case
  cp "$STATE/review-task.meta" "$STATE/review-task-b.meta"
  cp "$STATE/review-task.meta" "$STATE/review-task-c.meta"
  cp "$STATE/review-task.meta" "$STATE/ineligible.meta"
  sed -i.bak 's/backend=herdr/backend=tmux/' "$STATE/ineligible.meta"
  rm -f "$STATE/ineligible.meta.bak"
  fm_nm_visibility_refresh_task() { printf '%s\n' "$2" >> "$NM_LOG"; }
  FM_NM_VISIBILITY_MAX_TASKS_PER_CYCLE=1
  FM_NM_VISIBILITY_POLL_SECONDS=15
  FM_NM_VISIBILITY_ACTIVE_TTL_MS=45000
  _FM_NM_VISIBILITY_REFRESH_CURSOR=
  : > "$NM_LOG"
  fm_nm_visibility_refresh_all "$STATE"
  fm_nm_visibility_refresh_all "$STATE"
  fm_nm_visibility_refresh_all "$STATE"
  seen=$(sort -u "$NM_LOG" | wc -l | tr -d ' ')
  [ "$seen" = 3 ] || fail "bounded refresh did not fairly visit all tasks"
  [ "$(wc -l < "$NM_LOG" | tr -d ' ')" = 3 ] || fail "refresh exceeded one task per cycle"
  assert_not_contains "$(cat "$NM_LOG")" "ineligible" "ineligible task consumed the refresh budget"
  [ "$FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS" = 124000 ] || fail "active TTL does not cover the worst-case bounded eligible-task rotation"
  pass "refresh cycle bounds eligible work and renews before expiry"
}

test_metadata_report_and_clear_use_bounded_herdr() {
  local calls helper_source no_mistakes_source
  reset_case
  FM_FAKE_AXI_STATUS=$(status_with_review running 1000)
  fm_nm_visibility_refresh_task "$STATE" review-task
  fm_nm_visibility_clear fmtest:w1:p2
  calls=$(cat "$HERDR_LOG")
  assert_contains "$calls" $'\x1f''--ttl-ms'$'\x1f''45000' "active metadata report bypassed bounded Herdr execution"
  assert_contains "$calls" $'\x1f''--clear-title'$'\x1f''--clear-display-agent' "metadata clear bypassed bounded Herdr execution"
  assert_not_contains "$(sed -n '/^fm_nm_visibility_report()/,/^}/p; /^fm_nm_visibility_clear()/,/^}/p' "$ROOT/bin/fm-herdr-nm-visibility-lib.sh")" 'fm_backend_herdr_cli' "visibility mutation calls the unbounded backend helper"
  helper_source=$(sed -n '/^fm_nm_visibility_bounded_herdr()/,/^}/p' "$ROOT/bin/fm-herdr-nm-visibility-lib.sh")
  no_mistakes_source=$(sed -n '/^fm_nm_visibility_bounded_no_mistakes()/,/^}/p' "$ROOT/bin/fm-herdr-nm-visibility-lib.sh")
  assert_contains "$helper_source" 'timeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" herdr "$@"' "bounded Herdr helper lacks KILL escalation"
  assert_contains "$helper_source" 'gtimeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" herdr "$@"' "bounded Herdr helper lacks gtimeout KILL escalation"
  assert_contains "$no_mistakes_source" 'timeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" no-mistakes "$@"' "bounded No Mistakes helper lacks KILL escalation"
  assert_contains "$no_mistakes_source" 'gtimeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" no-mistakes "$@"' "bounded No Mistakes helper lacks gtimeout KILL escalation"
  assert_contains "$helper_source" 'kill "TERM", -$pid' "bounded Herdr helper lacks process-group fallback termination"
  pass "metadata reports and clears share bounded Herdr execution"
}

test_capability_probe_retries_transient_failure() {
  if (
    unset -f fm_nm_visibility_herdr_metadata_capable
    # shellcheck source=bin/fm-herdr-nm-visibility-lib.sh
    . "$ROOT/bin/fm-herdr-nm-visibility-lib.sh"
    probe_log="$TMP_ROOT/capability-probes.log"
    : > "$probe_log"
    fm_nm_visibility_bounded_herdr() {
      printf 'probe\n' >> "$probe_log"
      [ "$(wc -l < "$probe_log" | tr -d ' ')" -gt 1 ] || return 1
      printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"pane.report_metadata"}}}],"$defs":{"PaneReportMetadataParams":{"required":["pane_id","source"],"properties":{"title":{"type":"string"},"state_labels":{"type":"object"},"tokens":{"type":"object"},"ttl_ms":{"maximum":86400000}}}}}}}'
    }
    fm_nm_visibility_herdr_metadata_capable retry-session && exit 1
    fm_nm_visibility_herdr_metadata_capable retry-session || exit 1
    [ "$(wc -l < "$probe_log" | tr -d ' ')" = 2 ] || exit 1
  ); then
    pass "capability probe retries transient failures and caches parsed support"
  else
    fail "capability probe cached a transient failure"
  fi
}

test_transient_capability_failure_preserves_terminal_continuity() {
  if (
    reset_case
    FM_FAKE_AXI_STATUS=$(status_with_review running 1000)
    fm_nm_visibility_refresh_task "$STATE" review-task
    [ -e "$STATE/review-task.herdr-nm-activity" ] || exit 1
    fm_nm_visibility_herdr_metadata_capable() {
      FM_NM_VISIBILITY_CAPABILITY_RESULT=transient
      return 1
    }
    FM_FAKE_AXI_STATUS=$(status_with_review completed 2000 completed passed)
    fm_nm_visibility_refresh_task "$STATE" review-task
    [ -e "$STATE/review-task.herdr-nm-activity" ] || exit 1
    fm_nm_visibility_herdr_metadata_capable() {
      FM_NM_VISIBILITY_CAPABILITY_RESULT=supported
      return 0
    }
    fm_nm_visibility_refresh_task "$STATE" review-task
    grep -q '^state=completed$' "$STATE/review-task.herdr-nm-activity"
  ); then
    pass "transient capability failure preserves same-run terminal continuity"
  else
    fail "transient capability failure discarded terminal continuity"
  fi
}

test_fleet_growth_prioritizes_actual_expiry() {
  # shellcheck disable=SC2030,SC2100 # Intentional subshell-local test configuration and task ID.
  if (
    reset_case
    rm -f "$STATE"/review-task-*.meta "$STATE/ineligible.meta"
    cp "$STATE/review-task.meta" "$STATE/review-task-b.meta"
    cp "$STATE/review-task.meta" "$STATE/review-task-c.meta"
    cp "$STATE/review-task.meta" "$STATE/review-task-d.meta"
    fm_nm_visibility_cache_write "$STATE/review-task.herdr-nm-activity" \
      01VISIBILITYRUN reviewer working review 1000 1000 0 1045
    fm_nm_visibility_refresh_task() { printf '%s\n' "$2" >> "$NM_LOG"; }
    FM_NM_VISIBILITY_NOW=1030
    FM_NM_VISIBILITY_MAX_TASKS_PER_CYCLE=1
    FM_NM_VISIBILITY_POLL_SECONDS=15
    FM_NM_VISIBILITY_TIMEOUT=3
    _FM_NM_VISIBILITY_REFRESH_CURSOR=review-task-b
    : > "$NM_LOG"
    fm_nm_visibility_refresh_all "$STATE"
    [ "$(cat "$NM_LOG")" = review-task ]
  ); then
    pass "fleet growth renews the projection nearest actual expiry first"
  else
    fail "fleet growth allowed an existing projection to expire"
  fi
}

test_term_ignoring_herdr_is_killed() {
  local started elapsed
  started=$(date +%s)
  if (
    unset -f fm_nm_visibility_bounded_herdr
    # shellcheck source=bin/fm-herdr-nm-visibility-lib.sh
    . "$ROOT/bin/fm-herdr-nm-visibility-lib.sh"
    FM_NM_VISIBILITY_TIMEOUT=1
    fm_nm_visibility_bounded_herdr fmtest status --json
  ); then
    fail "TERM-ignoring Herdr command unexpectedly succeeded"
  fi
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -le 4 ] || fail "TERM-ignoring Herdr command exceeded bounded KILL escalation"
  pass "TERM-ignoring Herdr subprocess is killed within the watcher budget"
}

test_active_reviewer_is_visible_and_bounded
test_active_fixer_is_distinct
test_waiting_for_captain_is_accurate
test_failed_transition_is_one_shot
test_timed_out_transition_is_distinct
test_completed_transition_cleans_up_deterministically
test_unsupported_capability_falls_back_without_side_effects
test_non_herdr_backend_is_unchanged
test_pi_worker_name_is_unique_and_verified
test_pi_worker_name_refuses_non_pi_identity
test_pi_prominence_requires_exact_valid_config
test_spawn_applies_pi_name_after_launch_only_on_herdr
test_pi_identity_rollback_restores_metadata_on_failure
test_secondmate_pi_identity_rollback_preserves_home
test_cleanup_removes_only_the_private_visibility_cache
test_watcher_owns_the_regular_observation_tick
test_zero_elapsed_does_not_cross_run_cache
test_invalid_log_tail_falls_back_and_preserves_hints
test_top_level_failure_without_review_failure_is_visible
test_metadata_report_and_clear_use_bounded_herdr
test_capability_probe_retries_transient_failure
test_transient_capability_failure_preserves_terminal_continuity
test_fleet_growth_prioritizes_actual_expiry
test_term_ignoring_herdr_is_killed
test_refresh_cycle_is_bounded_and_fair
test_pi_worker_name_waits_for_delayed_registration
test_pi_worker_name_fails_on_collision
