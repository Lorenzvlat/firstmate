#!/usr/bin/env bash

FM_NM_STATUS_OUT=${FM_NM_STATUS_OUT:-}
FM_NM_STATUS_STEP_STATUS=
FM_NM_STATUS_STEP_DURATION_MS=0

fm_nm_status_trim() {
  local value=${1:-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

fm_nm_status_strip_quotes() {
  local value
  value=$(fm_nm_status_trim "${1:-}")
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  fm_nm_status_trim "$value"
}

fm_nm_status_field() { # <key>
  printf '%s\n' "$FM_NM_STATUS_OUT" \
    | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" \
    | head -1
}

fm_nm_status_parse_step() { # <step>
  local step=$1 row rest status duration
  FM_NM_STATUS_STEP_STATUS=
  FM_NM_STATUS_STEP_DURATION_MS=0
  row=$(printf '%s\n' "$FM_NM_STATUS_OUT" \
    | grep -E "^[[:space:]]*$step,[[:space:]]*" \
    | head -1)
  [ -n "$row" ] || return 0
  row=$(fm_nm_status_trim "$row")
  rest=${row#*,}
  status=$(fm_nm_status_strip_quotes "${rest%%,*}")
  duration=${row##*,}
  duration=$(fm_nm_status_strip_quotes "$duration")
  case "$status" in
    running|fixing|awaiting_approval|fix_review|completed|failed|cancelled|timed-out|timed_out|timeout|pending|skipped)
      # shellcheck disable=SC2034 # Parsed output consumed by sourcing callers.
      FM_NM_STATUS_STEP_STATUS=$status
      ;;
    *) return 0 ;;
  esac
  case "$duration" in
    ''|*[!0-9]*) duration=0 ;;
  esac
  # shellcheck disable=SC2034 # Parsed output consumed by sourcing callers.
  FM_NM_STATUS_STEP_DURATION_MS=$duration
}

fm_nm_run_head_matches() { # <worktree> <run-head>
  local worktree=$1 run_head=$2 local_full run_full
  case "$run_head" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  local_full=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$worktree" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$worktree" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}
