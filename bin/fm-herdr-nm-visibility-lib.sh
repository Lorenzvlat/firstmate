#!/usr/bin/env bash
# Read-only No Mistakes child-activity projection for Herdr-backed Firstmate workers.
#
# This file is the authoritative owner of the observation format, privacy filter,
# Herdr metadata shape, terminal-retention window, and cleanup state machine.
# The watcher calls fm_nm_visibility_refresh_all once per supervision cycle.
# Only ship tasks with mode=no-mistakes and backend=herdr are eligible.
#
# No Mistakes remains the sole lifecycle and structured-output owner.
# This observer invokes only `no-mistakes axi status` and the bounded tail form
# of `no-mistakes axi logs --step review`; it never responds, aborts, starts,
# resumes, or otherwise controls a run.
#
# Herdr 0.7.4 has no nested-agent or child-agent relationship in protocol 16.
# The supported observational fallback is pane.report_metadata on the owning
# worker's existing pane.
# It changes only a source-scoped title, a display-agent label, state labels, and
# six allowlisted tokens: nm_role, nm_state, nm_phase, nm_elapsed, nm_activity,
# and nm_summary.
# It never creates a pane, reports an agent, changes agent authority, or exposes
# an independently addressable target.
#
# Privacy is allowlist-only.
# Run ids, roles, states, phases, numeric elapsed time, and fixed activity enums
# may reach Herdr.
# Prompt text, agent prose, paths, credentials, commands, pids, raw errors, and
# raw log lines never do.
#
# Active and waiting metadata carries a short renewable TTL.
# Failed, timed-out, and completed transitions carry a shorter one-shot TTL.
# A private state/<id>.herdr-nm-activity cache prevents terminal states from
# being republished forever and is not task metadata, lifecycle authority, a
# dispatch record, or a fleet member.
# Expiry is enforced twice: Herdr's TTL removes abandoned metadata by itself,
# and the next watcher cycle clears this source explicitly and retires the cache.

FM_NM_VISIBILITY_SOURCE=firstmate.no-mistakes
FM_NM_VISIBILITY_CACHE_SUFFIX=.herdr-nm-activity
FM_NM_VISIBILITY_ACTIVE_TTL_MS=${FM_NM_VISIBILITY_ACTIVE_TTL_MS:-45000}
FM_NM_VISIBILITY_TERMINAL_TTL_MS=${FM_NM_VISIBILITY_TERMINAL_TTL_MS:-30000}
FM_NM_VISIBILITY_TIMEOUT=${FM_NM_VISIBILITY_TIMEOUT:-3}
FM_NM_VISIBILITY_REVIEW_LOG_TAIL=${FM_NM_VISIBILITY_REVIEW_LOG_TAIL:-200}
FM_NM_VISIBILITY_MAX_TASKS_PER_CYCLE=${FM_NM_VISIBILITY_MAX_TASKS_PER_CYCLE:-1}
FM_NM_VISIBILITY_POLL_SECONDS=${FM_NM_VISIBILITY_POLL_SECONDS:-${FM_POLL:-15}}
FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS=$FM_NM_VISIBILITY_ACTIVE_TTL_MS

_FM_NM_VISIBILITY_CAP_YES="|"
_FM_NM_VISIBILITY_CAP_NO="|"
_FM_NM_VISIBILITY_REFRESH_CURSOR=

FM_NM_VISIBILITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-nm-status-lib.sh
. "$FM_NM_VISIBILITY_ROOT/bin/fm-nm-status-lib.sh"

fm_nm_visibility_now() {
  if [ -n "${FM_NM_VISIBILITY_NOW:-}" ]; then
    printf '%s' "$FM_NM_VISIBILITY_NOW"
  else
    date +%s
  fi
}

fm_nm_visibility_positive_integer() { # <value>
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  return 0
}

fm_nm_visibility_ttl() { # <active|terminal>
  local value
  case "$1" in
    active) value=$FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS ;;
    terminal) value=$FM_NM_VISIBILITY_TERMINAL_TTL_MS ;;
    *) return 1 ;;
  esac
  fm_nm_visibility_positive_integer "$value" || return 1
  [ "$value" -le 86400000 ] || return 1
  printf '%s' "$value"
}

fm_nm_visibility_review_log_tail() {
  local value=$FM_NM_VISIBILITY_REVIEW_LOG_TAIL
  if fm_nm_visibility_positive_integer "$value" && [ "$value" -le 10000 ]; then
    printf '%s' "$value"
  else
    printf '%s' 200
  fi
}

fm_nm_visibility_trim() {
  local value=${1:-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

fm_nm_visibility_strip_quotes() {
  local value
  value=$(fm_nm_visibility_trim "${1:-}")
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  fm_nm_visibility_trim "$value"
}

fm_nm_visibility_bounded_no_mistakes() { # <worktree> <args...>
  local worktree=$1 timeout_kind=none
  shift
  fm_nm_visibility_positive_integer "$FM_NM_VISIBILITY_TIMEOUT" || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout_kind=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_kind=gtimeout
  elif command -v perl >/dev/null 2>&1; then
    timeout_kind=perl
  fi
  case "$timeout_kind" in
    timeout) ( cd "$worktree" && timeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ;;
    gtimeout) ( cd "$worktree" && gtimeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ;;
    perl)
      ( cd "$worktree" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$FM_NM_VISIBILITY_TIMEOUT" no-mistakes "$@" ) 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_nm_visibility_bounded_herdr() { # <session> <args...>
  local session=$1 timeout_kind=none
  shift
  fm_nm_visibility_positive_integer "$FM_NM_VISIBILITY_TIMEOUT" || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout_kind=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_kind=gtimeout
  elif command -v perl >/dev/null 2>&1; then
    timeout_kind=perl
  fi
  case "$timeout_kind" in
    timeout) HERDR_SESSION="$session" timeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" herdr "$@" --session "$session" 2>/dev/null ;;
    gtimeout) HERDR_SESSION="$session" gtimeout --kill-after=1 "$FM_NM_VISIBILITY_TIMEOUT" herdr "$@" --session "$session" 2>/dev/null ;;
    perl)
      HERDR_SESSION="$session" perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$FM_NM_VISIBILITY_TIMEOUT" herdr "$@" --session "$session" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

FM_NM_VISIBILITY_STATUS_OUT=
fm_nm_visibility_status_field() { # <key>
  FM_NM_STATUS_OUT=$FM_NM_VISIBILITY_STATUS_OUT
  fm_nm_status_field "$1"
}

FM_NM_VISIBILITY_REVIEW_STATUS=
FM_NM_VISIBILITY_REVIEW_ELAPSED_MS=0
fm_nm_visibility_parse_review_row() {
  FM_NM_VISIBILITY_REVIEW_STATUS=
  FM_NM_VISIBILITY_REVIEW_ELAPSED_MS=0
  FM_NM_STATUS_OUT=$FM_NM_VISIBILITY_STATUS_OUT
  fm_nm_status_parse_step review
  FM_NM_VISIBILITY_REVIEW_STATUS=$FM_NM_STATUS_STEP_STATUS
  FM_NM_VISIBILITY_REVIEW_ELAPSED_MS=$FM_NM_STATUS_STEP_DURATION_MS
}

fm_nm_visibility_digits() { # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

fm_nm_visibility_ident() { # <value>  matches ^[A-Za-z0-9._-]+$
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

fm_nm_visibility_is_fix_round() { # <trimmed>
  local rest round count
  case "$1" in
    'user-fix round starting after round '*' finding selected)') ;;
    'user-fix round starting after round '*' findings selected)') ;;
    *) return 1 ;;
  esac
  rest=${1#user-fix round starting after round }
  round=${rest%% *}
  fm_nm_visibility_digits "$round" || return 1
  rest=${rest#* }
  case "$rest" in '('*) ;; *) return 1 ;; esac
  count=${rest#(}
  count=${count%% *}
  fm_nm_visibility_digits "$count"
}

fm_nm_visibility_is_child_started() { # <trimmed>
  local name pid
  case "$1" in *' started pid='*) ;; *) return 1 ;; esac
  name=${1%% started pid=*}
  pid=${1##* started pid=}
  fm_nm_visibility_ident "$name" || return 1
  fm_nm_visibility_digits "$pid" || return 1
  [ "$1" = "$name started pid=$pid" ]
}

fm_nm_visibility_is_child_finished() { # <trimmed>
  local name rest pid
  case "$1" in *' exited pid='*' status=success') ;; *) return 1 ;; esac
  name=${1%% exited pid=*}
  rest=${1##* exited pid=}
  pid=${rest%% *}
  fm_nm_visibility_ident "$name" || return 1
  fm_nm_visibility_digits "$pid" || return 1
  [ "$1" = "$name exited pid=$pid status=success" ]
}

fm_nm_visibility_is_child_failed() { # <trimmed>
  local name rest pid
  case "$1" in *' exited pid='*' error='*) ;; *) return 1 ;; esac
  name=${1%% exited pid=*}
  rest=${1##* exited pid=}
  pid=${rest%% *}
  fm_nm_visibility_ident "$name" || return 1
  fm_nm_visibility_digits "$pid" || return 1
  case "$rest" in "$pid error="*) ;; *) return 1 ;; esac
  return 0
}

FM_NM_VISIBILITY_LOG_ROLE=
FM_NM_VISIBILITY_LOG_PHASE=
FM_NM_VISIBILITY_LOG_ACTIVITY=
fm_nm_visibility_review_log_hints() { # <worktree> <run-id> <initial-role> <initial-phase>
  local worktree=$1 run_id=$2 line trimmed tail_lines
  tail_lines=$(fm_nm_visibility_review_log_tail)
  FM_NM_VISIBILITY_LOG_ROLE=$3
  FM_NM_VISIBILITY_LOG_PHASE=$4
  FM_NM_VISIBILITY_LOG_ACTIVITY=
  while IFS= read -r line; do
    trimmed=$line
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$trimmed" in
      'asking agent to fix identified issues...')
        FM_NM_VISIBILITY_LOG_ROLE=fixer
        FM_NM_VISIBILITY_LOG_PHASE=fix
        FM_NM_VISIBILITY_LOG_ACTIVITY=applying-selected-fixes
        ;;
      'reviewing changes...')
        FM_NM_VISIBILITY_LOG_ROLE=reviewer
        FM_NM_VISIBILITY_LOG_PHASE=review
        FM_NM_VISIBILITY_LOG_ACTIVITY=reviewing-changes
        ;;
      'committed agent fixes:'*)
        FM_NM_VISIBILITY_LOG_ROLE=fixer
        FM_NM_VISIBILITY_LOG_PHASE=fix
        FM_NM_VISIBILITY_LOG_ACTIVITY=fixes-committed
        ;;
      *)
        if fm_nm_visibility_is_fix_round "$trimmed"; then
          FM_NM_VISIBILITY_LOG_ROLE=fixer
          FM_NM_VISIBILITY_LOG_PHASE=fix
          FM_NM_VISIBILITY_LOG_ACTIVITY=fix-round-started
        elif fm_nm_visibility_is_child_started "$trimmed"; then
          FM_NM_VISIBILITY_LOG_ACTIVITY=child-started
        elif fm_nm_visibility_is_child_finished "$trimmed"; then
          FM_NM_VISIBILITY_LOG_ACTIVITY=child-finished
        elif fm_nm_visibility_is_child_failed "$trimmed"; then
          FM_NM_VISIBILITY_LOG_ACTIVITY=child-failed
        fi
        ;;
    esac
  done < <(fm_nm_visibility_bounded_no_mistakes "$worktree" axi logs --step review --run "$run_id" 2>/dev/null | tail -n "$tail_lines" || true)
}

fm_nm_visibility_observation_reset() {
  FM_NM_VISIBILITY_OBS_PRESENT=0
  FM_NM_VISIBILITY_OBS_RUN_ID=
  FM_NM_VISIBILITY_OBS_ROLE=
  FM_NM_VISIBILITY_OBS_STATE=
  FM_NM_VISIBILITY_OBS_PHASE=
  FM_NM_VISIBILITY_OBS_ELAPSED_MS=0
  FM_NM_VISIBILITY_OBS_ACTIVITY=
}

fm_nm_visibility_observe() { # <worktree>
  local worktree=$1 branch run_branch run_head run_id status outcome gate role state phase activity
  fm_nm_visibility_observation_reset
  command -v no-mistakes >/dev/null 2>&1 || return 1
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  FM_NM_VISIBILITY_STATUS_OUT=$(fm_nm_visibility_bounded_no_mistakes "$worktree" axi status) || return 1
  [ -n "$FM_NM_VISIBILITY_STATUS_OUT" ] || return 1

  run_branch=$(fm_nm_visibility_strip_quotes "$(fm_nm_visibility_status_field branch)")
  run_head=$(fm_nm_visibility_strip_quotes "$(fm_nm_visibility_status_field head)")
  run_id=$(fm_nm_visibility_strip_quotes "$(fm_nm_visibility_status_field id)")
  [ "$run_branch" = "$branch" ] || return 0
  fm_nm_run_head_matches "$worktree" "$run_head" || return 0
  case "$run_id" in
    ''|*[!A-Za-z0-9_-]*|????????????????????????????????????????????????????????????????*) return 0 ;;
  esac

  status=$(fm_nm_visibility_strip_quotes "$(fm_nm_visibility_status_field status)")
  outcome=$(fm_nm_visibility_strip_quotes "$(fm_nm_visibility_status_field outcome)")
  gate=$(fm_nm_visibility_strip_quotes "$(fm_nm_visibility_status_field gate)")
  fm_nm_visibility_parse_review_row

  role=reviewer
  state=
  phase=review
  activity=reviewing
  case "$FM_NM_VISIBILITY_REVIEW_STATUS" in
    running)
      state=working
      ;;
    fixing)
      role=fixer
      state=working
      phase=fix
      activity=applying-fixes
      ;;
    awaiting_approval|fix_review)
      state=waiting-for-captain
      phase=decision
      activity=decision-requested
      ;;
    failed|cancelled)
      state=failed
      phase=terminal
      activity=review-failed
      ;;
    timed-out|timed_out|timeout)
      state=timed-out
      phase=terminal
      activity=review-timed-out
      ;;
    completed)
      state=completed
      phase=terminal
      activity=review-completed
      ;;
  esac

  if [ -z "$state" ] && [ "$status" = fixing ]; then
    role=fixer
    state=working
    phase=fix
    activity=applying-fixes
  fi
  if [ -z "$state" ] && { [ "$status" = awaiting_approval ] || [ "$status" = fix_review ]; }; then
    if [ "$gate" = review ] || printf '%s\n' "$FM_NM_VISIBILITY_STATUS_OUT" | grep -Eq '^[[:space:]]*step:[[:space:]]*review[[:space:]]*$'; then
      state=waiting-for-captain
      phase=decision
      activity=decision-requested
    fi
  fi
  if [ "$state" = failed ]; then
    if printf '%s\n' "$FM_NM_VISIBILITY_STATUS_OUT" | grep -Eiq '^[[:space:]]*error:.*(timed out|timeout)'; then
      state=timed-out
      activity=review-timed-out
    fi
  fi
  if [ -z "$state" ] && [ "$outcome" = failed ]; then
    state=failed
    phase=terminal
    activity=review-failed
  fi
  [ -n "$state" ] || return 0

  case "$state" in
    working|failed|timed-out)
      fm_nm_visibility_review_log_hints "$worktree" "$run_id" "$role" "$phase"
      role=$FM_NM_VISIBILITY_LOG_ROLE
      phase=$FM_NM_VISIBILITY_LOG_PHASE
      [ -z "$FM_NM_VISIBILITY_LOG_ACTIVITY" ] || activity=$FM_NM_VISIBILITY_LOG_ACTIVITY
      ;;
  esac
  if [ "$state" = timed-out ]; then
    activity=review-timed-out
    phase=terminal
  elif [ "$state" = failed ]; then
    activity=review-failed
    phase=terminal
  fi

  FM_NM_VISIBILITY_OBS_PRESENT=1
  FM_NM_VISIBILITY_OBS_RUN_ID=$run_id
  FM_NM_VISIBILITY_OBS_ROLE=$role
  FM_NM_VISIBILITY_OBS_STATE=$state
  FM_NM_VISIBILITY_OBS_PHASE=$phase
  FM_NM_VISIBILITY_OBS_ELAPSED_MS=$FM_NM_VISIBILITY_REVIEW_ELAPSED_MS
  FM_NM_VISIBILITY_OBS_ACTIVITY=$activity
  return 0
}

fm_nm_visibility_cache_path() { # <state-dir> <task-id>
  printf '%s/%s%s' "$1" "$2" "$FM_NM_VISIBILITY_CACHE_SUFFIX"
}

fm_nm_visibility_cache_reset() {
  FM_NM_VISIBILITY_CACHE_VALID=0
  FM_NM_VISIBILITY_CACHE_RUN_ID=
  FM_NM_VISIBILITY_CACHE_ROLE=
  FM_NM_VISIBILITY_CACHE_STATE=
  FM_NM_VISIBILITY_CACHE_PHASE=
  FM_NM_VISIBILITY_CACHE_ELAPSED_MS=0
  FM_NM_VISIBILITY_CACHE_OBSERVED_EPOCH=0
  FM_NM_VISIBILITY_CACHE_TERMINAL_UNTIL=0
}

fm_nm_visibility_cache_load() { # <path>
  local path=$1 version lines key value seen="|"
  fm_nm_visibility_cache_reset
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  lines=$(wc -l < "$path" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" = 8 ] || return 1
  while IFS='=' read -r key value || [ -n "$key$value" ]; do
    case "$seen" in *"|$key|"*) return 1 ;; esac
    seen="$seen$key|"
    case "$key" in
      version) version=$value ;;
      run_id) FM_NM_VISIBILITY_CACHE_RUN_ID=$value ;;
      role) FM_NM_VISIBILITY_CACHE_ROLE=$value ;;
      state) FM_NM_VISIBILITY_CACHE_STATE=$value ;;
      phase) FM_NM_VISIBILITY_CACHE_PHASE=$value ;;
      elapsed_ms) FM_NM_VISIBILITY_CACHE_ELAPSED_MS=$value ;;
      observed_epoch) FM_NM_VISIBILITY_CACHE_OBSERVED_EPOCH=$value ;;
      terminal_until) FM_NM_VISIBILITY_CACHE_TERMINAL_UNTIL=$value ;;
      *) return 1 ;;
    esac
  done < "$path"
  [ "${version:-}" = 1 ] || return 1
  case "$FM_NM_VISIBILITY_CACHE_RUN_ID" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$FM_NM_VISIBILITY_CACHE_ROLE" in reviewer|fixer) ;; *) return 1 ;; esac
  case "$FM_NM_VISIBILITY_CACHE_STATE" in working|waiting-for-captain|failed|timed-out|completed|retired) ;; *) return 1 ;; esac
  case "$FM_NM_VISIBILITY_CACHE_PHASE" in review|fix|decision|terminal) ;; *) return 1 ;; esac
  case "$FM_NM_VISIBILITY_CACHE_ELAPSED_MS" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_NM_VISIBILITY_CACHE_OBSERVED_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_NM_VISIBILITY_CACHE_TERMINAL_UNTIL" in ''|*[!0-9]*) return 1 ;; esac
  FM_NM_VISIBILITY_CACHE_VALID=1
  return 0
}

fm_nm_visibility_cache_write() { # <path> <run> <role> <state> <phase> <elapsed-ms> <observed-epoch> <terminal-until>
  local path=$1 run_id=$2 role=$3 state=$4 phase=$5 elapsed=$6 observed=$7 until=$8 tmp
  case "$run_id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$role" in reviewer|fixer) ;; *) return 1 ;; esac
  case "$state" in working|waiting-for-captain|failed|timed-out|completed|retired) ;; *) return 1 ;; esac
  case "$phase" in review|fix|decision|terminal) ;; *) return 1 ;; esac
  case "$elapsed:$observed:$until" in *[!0-9:]*|::*|:*:|*::*) return 1 ;; esac
  mkdir -p "$(dirname "$path")" || return 1
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'version=1\n'
    printf 'run_id=%s\n' "$run_id"
    printf 'role=%s\n' "$role"
    printf 'state=%s\n' "$state"
    printf 'phase=%s\n' "$phase"
    printf 'elapsed_ms=%s\n' "$elapsed"
    printf 'observed_epoch=%s\n' "$observed"
    printf 'terminal_until=%s\n' "$until"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

fm_nm_visibility_format_elapsed() { # <milliseconds>
  local milliseconds=$1 seconds hours minutes
  case "$milliseconds" in ''|*[!0-9]*) milliseconds=0 ;; esac
  seconds=$((milliseconds / 1000))
  if [ "$seconds" -lt 1 ]; then
    printf '<1s'
  elif [ "$seconds" -lt 60 ]; then
    printf '%ss' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then
    minutes=$((seconds / 60))
    seconds=$((seconds % 60))
    if [ "$seconds" -eq 0 ]; then printf '%sm' "$minutes"; else printf '%sm%ss' "$minutes" "$seconds"; fi
  else
    hours=$((seconds / 3600))
    minutes=$(((seconds % 3600) / 60))
    if [ "$minutes" -eq 0 ]; then printf '%sh' "$hours"; else printf '%sh%sm' "$hours" "$minutes"; fi
  fi
}

fm_nm_visibility_activity_label() { # <activity-enum>
  case "$1" in
    reviewing) printf 'reviewing' ;;
    reviewing-changes) printf 'reviewing changes' ;;
    applying-fixes) printf 'applying fixes' ;;
    applying-selected-fixes) printf 'applying selected fixes' ;;
    fix-round-started) printf 'fix round started' ;;
    fixes-committed) printf 'fixes committed' ;;
    child-started) printf 'child started' ;;
    child-finished) printf 'child finished' ;;
    child-failed) printf 'child failed' ;;
    decision-requested) printf 'decision requested' ;;
    review-failed) printf 'review failed' ;;
    review-timed-out) printf 'review timed out' ;;
    review-completed) printf 'review completed' ;;
    *) printf 'activity updated' ;;
  esac
}

fm_nm_visibility_herdr_metadata_capable() { # <session>
  local session=$1 key schema
  key="|$session|"
  case "$_FM_NM_VISIBILITY_CAP_YES" in *"$key"*) return 0 ;; esac
  case "$_FM_NM_VISIBILITY_CAP_NO" in *"$key"*) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  schema=$(fm_nm_visibility_bounded_herdr "$session" api schema --json) || return 1
  printf '%s' "$schema" | jq -e . >/dev/null 2>&1 || return 1
  if printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "pane.report_metadata")
    and (.schemas.request["$defs"].PaneReportMetadataParams.required | index("pane_id") != null)
    and (.schemas.request["$defs"].PaneReportMetadataParams.required | index("source") != null)
    and (.schemas.request["$defs"].PaneReportMetadataParams.properties.title.type != null)
    and (.schemas.request["$defs"].PaneReportMetadataParams.properties.state_labels.type == "object")
    and (.schemas.request["$defs"].PaneReportMetadataParams.properties.tokens.type == "object")
    and (.schemas.request["$defs"].PaneReportMetadataParams.properties.ttl_ms.maximum >= 86400000)
  ' >/dev/null 2>&1; then
    _FM_NM_VISIBILITY_CAP_YES="$_FM_NM_VISIBILITY_CAP_YES$session|"
    return 0
  fi
  _FM_NM_VISIBILITY_CAP_NO="$_FM_NM_VISIBILITY_CAP_NO$session|"
  return 1
}

fm_nm_visibility_task_eligible() { # <state-dir> <task-id>
  local meta backend mode kind
  meta="$1/$2.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" = herdr ] || return 1
  mode=$(fm_meta_get "$meta" mode)
  kind=$(fm_meta_get "$meta" kind)
  [ "$mode" = no-mistakes ] && { [ -z "$kind" ] || [ "$kind" = ship ]; }
}

fm_nm_visibility_report() { # <target> <identity> <role> <state> <phase> <elapsed-ms> <activity> <active|terminal>
  local target=$1 identity=$2 role=$3 state=$4 phase=$5 elapsed_ms=$6 activity=$7 ttl_kind=$8
  local session pane ttl elapsed activity_label title child_summary display_agent idle_label working_label blocked_label unknown_label
  if printf '%s\n' "$identity" | grep -Eq '^task [A-Za-z0-9._-]{1,64}$'; then
    :
  elif printf '%s\n' "$identity" | grep -Eq '^Pi · (firstmate|2ndmate-[A-Za-z0-9._-]+)(/[A-Za-z0-9._-]+)? \[[A-Za-z0-9:_-]+\]$'; then
    :
  else
    return 1
  fi
  [ "${#identity}" -le 192 ] || return 1
  case "$role" in reviewer|fixer) ;; *) return 1 ;; esac
  case "$state" in working|waiting-for-captain|failed|timed-out|completed) ;; *) return 1 ;; esac
  case "$phase" in review|fix|decision|terminal) ;; *) return 1 ;; esac
  case "$activity" in reviewing|reviewing-changes|applying-fixes|applying-selected-fixes|fix-round-started|fixes-committed|child-started|child-finished|child-failed|decision-requested|review-failed|review-timed-out|review-completed) ;; *) return 1 ;; esac
  case "$elapsed_ms" in ''|*[!0-9]*) return 1 ;; esac
  ttl=$(fm_nm_visibility_ttl "$ttl_kind") || return 1
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  elapsed=$(fm_nm_visibility_format_elapsed "$elapsed_ms")
  activity_label=$(fm_nm_visibility_activity_label "$activity")
  title="$identity · No Mistakes $role · $state · $elapsed · $activity_label"
  child_summary="No Mistakes $role $state · $elapsed"
  display_agent="$identity · $child_summary · $activity_label"
  idle_label="worker idle · $child_summary"
  working_label="worker working · $child_summary"
  blocked_label="worker waiting · $child_summary"
  unknown_label=$child_summary
  fm_nm_visibility_bounded_herdr "$session" pane report-metadata "$pane" \
    --source "$FM_NM_VISIBILITY_SOURCE" \
    --title "$title" \
    --display-agent "$display_agent" \
    --state-label "idle=$idle_label" \
    --state-label "working=$working_label" \
    --state-label "blocked=$blocked_label" \
    --state-label "unknown=$unknown_label" \
    --token "nm_role=$role" \
    --token "nm_state=$state" \
    --token "nm_phase=$phase" \
    --token "nm_elapsed=$elapsed" \
    --token "nm_activity=$activity" \
    --token "nm_summary=$role $state · $elapsed · $activity_label" \
    --ttl-ms "$ttl" >/dev/null 2>&1
}

fm_nm_visibility_clear() { # <target>
  local target=$1 session pane
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  fm_nm_visibility_bounded_herdr "$session" pane report-metadata "$pane" \
    --source "$FM_NM_VISIBILITY_SOURCE" \
    --clear-title \
    --clear-display-agent \
    --clear-state-labels \
    --clear-token nm_role \
    --clear-token nm_state \
    --clear-token nm_phase \
    --clear-token nm_elapsed \
    --clear-token nm_activity \
    --clear-token nm_summary >/dev/null 2>&1
}

fm_nm_visibility_effective_elapsed() { # <now> <observed-ms> <cache-usable-for-this-run>
  local now=$1 observed_ms=$2 cache_usable=$3 delta
  case "$observed_ms" in ''|*[!0-9]*) observed_ms=0 ;; esac
  if [ "$observed_ms" -gt 0 ] || [ "$cache_usable" != 1 ]; then
    printf '%s' "$observed_ms"
    return 0
  fi
  delta=$((now - FM_NM_VISIBILITY_CACHE_OBSERVED_EPOCH))
  [ "$delta" -lt 0 ] && delta=0
  printf '%s' $((FM_NM_VISIBILITY_CACHE_ELAPSED_MS + delta * 1000))
}

fm_nm_visibility_retire_if_due() { # <target> <cache-path> <now>
  local target=$1 cache=$2 now=$3 active_ttl active_deadline
  [ "$FM_NM_VISIBILITY_CACHE_VALID" = 1 ] || return 0
  case "$FM_NM_VISIBILITY_CACHE_STATE" in
    failed|timed-out|completed)
      if [ "$now" -ge "$FM_NM_VISIBILITY_CACHE_TERMINAL_UNTIL" ]; then
        fm_nm_visibility_clear "$target" || return 1
        fm_nm_visibility_cache_write "$cache" "$FM_NM_VISIBILITY_CACHE_RUN_ID" \
          "$FM_NM_VISIBILITY_CACHE_ROLE" retired terminal \
          "$FM_NM_VISIBILITY_CACHE_ELAPSED_MS" "$now" 0
      fi
      ;;
    working|waiting-for-captain)
      active_ttl=$(fm_nm_visibility_ttl active) || return 1
      active_deadline=$((FM_NM_VISIBILITY_CACHE_OBSERVED_EPOCH + (active_ttl + 999) / 1000))
      if [ "$now" -ge "$active_deadline" ]; then
        fm_nm_visibility_clear "$target" || true
        rm -f "$cache"
      fi
      ;;
  esac
}

fm_nm_visibility_refresh_task() { # <state-dir> <task-id>
  local state_dir=$1 task_id=$2 meta backend mode kind harness worktree target session pane owner identity cache now cache_valid=0
  local role state phase elapsed activity ttl until prior_role cache_same_run=0
  case "$task_id" in ''|.*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  meta="$state_dir/$task_id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" = herdr ] || return 0
  mode=$(fm_meta_get "$meta" mode)
  kind=$(fm_meta_get "$meta" kind)
  [ "$mode" = no-mistakes ] && { [ -z "$kind" ] || [ "$kind" = ship ]; } || return 0
  harness=$(fm_meta_get "$meta" harness)
  worktree=$(fm_meta_get "$meta" worktree)
  target=$(fm_backend_target_of_meta "$meta")
  [ -d "$worktree" ] && [ -n "$target" ] || return 0
  fm_backend_source herdr >/dev/null 2>&1 || return 0
  fm_backend_herdr_parse_target "$target" || return 0
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  identity="task $task_id"
  if [ "$harness" = pi ]; then
    owner=$(fm_backend_herdr_workspace_label)
    identity=$(fm_backend_herdr_pi_worker_name "$owner" "$task_id" "$kind" "$pane") || identity="task $task_id"
  fi
  cache=$(fm_nm_visibility_cache_path "$state_dir" "$task_id")
  if fm_nm_visibility_cache_load "$cache"; then cache_valid=1; else rm -f "$cache"; fi
  if ! fm_nm_visibility_herdr_metadata_capable "$session"; then
    rm -f "$cache"
    return 0
  fi
  now=$(fm_nm_visibility_now)
  case "$now" in ''|*[!0-9]*) return 0 ;; esac

  if ! fm_nm_visibility_observe "$worktree"; then
    fm_nm_visibility_retire_if_due "$target" "$cache" "$now" || true
    return 0
  fi
  if [ "$FM_NM_VISIBILITY_OBS_PRESENT" != 1 ]; then
    fm_nm_visibility_retire_if_due "$target" "$cache" "$now" || true
    return 0
  fi

  role=$FM_NM_VISIBILITY_OBS_ROLE
  state=$FM_NM_VISIBILITY_OBS_STATE
  phase=$FM_NM_VISIBILITY_OBS_PHASE
  activity=$FM_NM_VISIBILITY_OBS_ACTIVITY
  if [ "$cache_valid" = 1 ] && [ "$FM_NM_VISIBILITY_CACHE_RUN_ID" = "$FM_NM_VISIBILITY_OBS_RUN_ID" ]; then
    cache_same_run=1
  fi
  elapsed=$(fm_nm_visibility_effective_elapsed "$now" "$FM_NM_VISIBILITY_OBS_ELAPSED_MS" "$cache_same_run")
  case "$state" in
    working|waiting-for-captain)
      fm_nm_visibility_report "$target" "$identity" "$role" "$state" "$phase" "$elapsed" "$activity" active || return 0
      fm_nm_visibility_cache_write "$cache" "$FM_NM_VISIBILITY_OBS_RUN_ID" "$role" "$state" "$phase" "$elapsed" "$now" 0 || true
      ;;
    failed|timed-out|completed)
      [ "$cache_same_run" = 1 ] || return 0
      case "$FM_NM_VISIBILITY_CACHE_STATE" in
        retired) return 0 ;;
        failed|timed-out|completed)
          fm_nm_visibility_retire_if_due "$target" "$cache" "$now" || true
          return 0
          ;;
        working|waiting-for-captain) ;;
        *) return 0 ;;
      esac
      prior_role=$FM_NM_VISIBILITY_CACHE_ROLE
      [ "$state" = completed ] && role=$prior_role
      ttl=$(fm_nm_visibility_ttl terminal) || return 0
      until=$((now + (ttl + 999) / 1000))
      fm_nm_visibility_report "$target" "$identity" "$role" "$state" terminal "$elapsed" "$activity" terminal || return 0
      fm_nm_visibility_cache_write "$cache" "$FM_NM_VISIBILITY_OBS_RUN_ID" "$role" "$state" terminal "$elapsed" "$now" "$until" || true
      ;;
  esac
}

fm_nm_visibility_refresh_all() { # <state-dir>
  local state_dir=$1 meta task cache base count=0 max_tasks start_after cursor_seen
  local eligible_count=0 rounds poll_seconds required_ttl
  local -a eligible_tasks=()
  [ -d "$state_dir" ] || return 0
  max_tasks=$FM_NM_VISIBILITY_MAX_TASKS_PER_CYCLE
  fm_nm_visibility_positive_integer "$max_tasks" || max_tasks=1
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta" .meta)
    fm_nm_visibility_task_eligible "$state_dir" "$task" || continue
    eligible_tasks+=("$task")
    eligible_count=$((eligible_count + 1))
  done
  FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS=$FM_NM_VISIBILITY_ACTIVE_TTL_MS
  poll_seconds=$FM_NM_VISIBILITY_POLL_SECONDS
  fm_nm_visibility_positive_integer "$poll_seconds" || poll_seconds=15
  if [ "$eligible_count" -gt 0 ]; then
    rounds=$(((eligible_count + max_tasks - 1) / max_tasks))
    required_ttl=$(((rounds + 1) * poll_seconds * 1000))
    if [ "$required_ttl" -gt "$FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS" ]; then
      FM_NM_VISIBILITY_ACTIVE_TTL_EFFECTIVE_MS=$required_ttl
    fi
  fi
  start_after=$_FM_NM_VISIBILITY_REFRESH_CURSOR
  [ -z "$start_after" ] && cursor_seen=1 || cursor_seen=0
  for task in "${eligible_tasks[@]}"; do
    if [ "$cursor_seen" = 0 ]; then
      [ "$task" = "$start_after" ] && cursor_seen=1
      continue
    fi
    fm_nm_visibility_refresh_task "$state_dir" "$task" || true
    _FM_NM_VISIBILITY_REFRESH_CURSOR=$task
    count=$((count + 1))
    [ "$count" -ge "$max_tasks" ] && break
  done
  if [ "$count" -lt "$max_tasks" ] && [ -n "$start_after" ]; then
    for task in "${eligible_tasks[@]}"; do
      [ "$task" = "$start_after" ] && break
      fm_nm_visibility_refresh_task "$state_dir" "$task" || true
      _FM_NM_VISIBILITY_REFRESH_CURSOR=$task
      count=$((count + 1))
      [ "$count" -ge "$max_tasks" ] && break
    done
  fi
  for cache in "$state_dir"/*"$FM_NM_VISIBILITY_CACHE_SUFFIX"; do
    [ -e "$cache" ] || continue
    base=$(basename "$cache")
    task=${base%"$FM_NM_VISIBILITY_CACHE_SUFFIX"}
    [ -f "$state_dir/$task.meta" ] || rm -f "$cache"
  done
  return 0
}
