#!/usr/bin/env bash

fm_spawn_identity_rollback() { # <root> <home> <state> <task-id> <kind> <task-tmp>
  local root=$1 home=$2 state=$3 id=$4 kind=$5 task_tmp=$6 meta snapshot status tmp
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: identity rollback cannot preserve missing or unsafe metadata at $meta" >&2
    return 1
  }
  snapshot=$(cat "$meta") || return 1
  if [ "$kind" = secondmate ]; then
    case "$task_tmp" in
      "/tmp/fm-$id") rm -rf "$task_tmp" ;;
      *)
        echo "error: identity rollback refused unsafe task temp path ${task_tmp:-<empty>}" >&2
        return 1
        ;;
    esac
    rm -f "$state/$id.status" "$state/$id.turn-ended" \
      "$state/$id.pi-ext.ts" "$state/$id.herdr-nm-activity" "$meta"
    return 0
  fi
  if FM_HOME="$home" "$root/bin/fm-teardown.sh" "$id" --force; then
    return 0
  else
    status=$?
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    tmp=$(mktemp "$state/.identity-rollback-meta.XXXXXXXX") || return "$status"
    printf '%s\n' "$snapshot" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$meta"
  fi
  echo "error: complete identity rollback failed for $id; retained metadata at $meta" >&2
  return "$status"
}
