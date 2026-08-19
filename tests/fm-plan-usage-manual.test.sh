#!/usr/bin/env bash
# Guided manual Claude plan importer security and projection tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-plan-usage-manual)
IMPORTER="$ROOT/bin/fm-plan-usage-manual.sh"
SNAPSHOT="$ROOT/bin/fm-plan-usage-snapshot.sh"
BASE_PATH=$PATH

file_mode() { # <path>
  if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

valid_input() {
  cat <<'EOF'
pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
2
primary
40
300
2026-08-01T00:30:00.000Z
secondary
70
10080
2026-08-08T00:00:00.000Z
EOF
}

run_set() { # <config> [input]
  local config=$1
  if [ "$#" -eq 2 ]; then
    printf '%s' "$2" | FM_CONFIG_OVERRIDE="$config" FM_TELEMETRY_TEST_MODE=1 \
      FM_TELEMETRY_TEST_NOW=1785542400 "$IMPORTER" set
  else
    valid_input | FM_CONFIG_OVERRIDE="$config" FM_TELEMETRY_TEST_MODE=1 \
      FM_TELEMETRY_TEST_NOW=1785542400 "$IMPORTER" set
  fi
}

make_fake_codex() { # <root>
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/codex" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/fakebin/codex"
}

test_help_owns_guided_boundary() {
  local out
  out=$($IMPORTER --help) || fail "manual importer help failed"
  assert_contains "$out" 'fm-plan-usage-manual.sh set|clear' "help omitted actions"
  assert_contains "$out" 'Do not paste the screen' "help omitted pasted-output refusal"
  assert_contains "$out" 'FM_PLAN_USAGE_MANUAL=1' "help omitted disabled-by-default opt-in"
  assert_contains "$out" 'without restarting Herdr or any shared daemon' "help omitted immediate refresh behavior"
  pass "manual importer help owns its bounded input and service opt-in mechanics"
}

test_success_permissions_and_manual_projection() {
  local root file out projected
  root="$TMP_ROOT/success"
  mkdir -p "$root/config" "$root/state"
  make_fake_codex "$root"
  out=$(run_set "$root/config" 2>&1) || fail "valid guided import failed: $out"
  assert_contains "$out" 'Manual Claude plan snapshot' "success did not identify Manual provenance"
  file="$root/config/plan-usage-manual.json"
  [ -f "$file" ] || fail "guided import did not create the fixed snapshot"
  [ ! -L "$file" ] || fail "guided import created a symlink"
  [ "$(file_mode "$file")" = 600 ] || fail "guided import snapshot is not owner-only"
  projected=$(PATH="$root/fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$root/config" \
    FM_STATE_OVERRIDE="$root/state" FM_PLAN_USAGE_MANUAL=1 FM_TELEMETRY_TEST_MODE=1 \
    FM_TELEMETRY_TEST_NOW=1785542400 "$SNAPSHOT" --json) \
    || fail "manual projection failed"
  JSON_INPUT=$projected python3 - <<'PY' || fail "successful import did not project exact Manual provenance"
import json, os
claude = json.loads(os.environ["JSON_INPUT"])["providers"][1]
assert claude["status"] == "manual"
assert claude["reason"] == "manual_snapshot"
assert claude["plan"] == "pro"
assert [(item["usedPercent"], item["remainingPercent"], item["windowSeconds"])
        for item in claude["windows"]] == [(40, 60, 18000), (70, 30, 604800)]
PY
  pass "guided import writes mode 600 and projects explicit manual/manual_snapshot provenance"
}

test_hostile_malformed_range_and_expiry_keep_prior() {
  local root file before hostile malformed malformed_reset range duration expired case_input
  root="$TMP_ROOT/refusals"
  mkdir -p "$root/config"
  run_set "$root/config" >/dev/null 2>&1 || fail "prior snapshot fixture failed"
  file="$root/config/plan-usage-manual.json"
  before=$(shasum -a 256 "$file")

  # shellcheck disable=SC2016 # Literal command substitution is hostile input.
  hostile='$(touch /tmp/fm-plan-usage-importer-must-not-execute)'
  rm -f /tmp/fm-plan-usage-importer-must-not-execute
  case_input="$hostile
"
  run_set "$root/config" "$case_input" >/dev/null 2>&1 \
    && fail "hostile plan input was accepted"
  [ ! -e /tmp/fm-plan-usage-importer-must-not-execute ] || fail "hostile input executed"

  malformed='pro
2026-08-01 00:00:00Z
'
  run_set "$root/config" "$malformed" >/dev/null 2>&1 \
    && fail "malformed observation time was accepted"

  malformed_reset='pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
1
primary
40
300
2026-08-01T00:30:00.123Z
'
  run_set "$root/config" "$malformed_reset" >/dev/null 2>&1 \
    && fail "sub-second reset time was accepted"

  range='pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
1
primary
101
'
  run_set "$root/config" "$range" >/dev/null 2>&1 \
    && fail "out-of-range percentage was accepted"

  duration='pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
1
primary
40
0
'
  run_set "$root/config" "$duration" >/dev/null 2>&1 \
    && fail "out-of-range duration was accepted"

  expired='pro
2026-08-01T00:00:00.000Z
2026-08-01T00:00:00.000Z
1
primary
40
300
2026-08-01T00:30:00.000Z
'
  run_set "$root/config" "$expired" >/dev/null 2>&1 \
    && fail "non-increasing expiry was accepted"
  [ "$(shasum -a 256 "$file")" = "$before" ] \
    || fail "a refused input changed the prior valid snapshot"
  pass "hostile, malformed-time, range, and expiry failures preserve the prior snapshot"
}

test_permissions_symlink_containment_and_atomic_failure() {
  local root file external before
  root="$TMP_ROOT/security"
  mkdir -p "$root/config"
  run_set "$root/config" >/dev/null 2>&1 || fail "security prior fixture failed"
  file="$root/config/plan-usage-manual.json"
  before=$(shasum -a 256 "$file")

  chmod 644 "$file"
  run_set "$root/config" >/dev/null 2>&1 && fail "unsafe existing permissions were accepted"
  [ "$(file_mode "$file")" = 644 ] || fail "permission refusal changed the target"
  chmod 600 "$file"

  external="$root/external"
  printf 'external\n' > "$external"
  rm -f "$file"
  ln -s "$external" "$file"
  run_set "$root/config" >/dev/null 2>&1 && fail "snapshot symlink was accepted"
  [ "$(cat "$external")" = external ] || fail "snapshot symlink target was changed"
  FM_CONFIG_OVERRIDE="$root/config" "$IMPORTER" clear >/dev/null 2>&1 \
    && fail "clear accepted a snapshot symlink"
  [ -L "$file" ] || fail "unsafe clear removed the snapshot symlink"

  rm -f "$file"
  mkdir -p "$root/real-config"
  rm -rf "$root/config"
  ln -s "$root/real-config" "$root/config"
  run_set "$root/config" >/dev/null 2>&1 && fail "symlinked config containment was accepted"
  [ ! -e "$root/real-config/plan-usage-manual.json" ] || fail "containment refusal wrote outside the lexical config root"

  rm -f "$root/config"
  mkdir -p "$root/config"
  run_set "$root/config" >/dev/null 2>&1 || fail "atomic prior fixture failed"
  file="$root/config/plan-usage-manual.json"
  before=$(shasum -a 256 "$file")
  ln -s "$external" "$root/config/.plan-usage-manual.json.tmp"
  run_set "$root/config" >/dev/null 2>&1 && fail "unsafe staging target was accepted"
  [ "$(shasum -a 256 "$file")" = "$before" ] || fail "failed atomic staging changed the prior snapshot"
  [ "$(cat "$external")" = external ] || fail "failed atomic staging followed its symlink"
  pass "permissions, symlink, containment, and atomic-write failures fail closed"
}

test_clear_only_fixed_snapshot() {
  local root sibling
  root="$TMP_ROOT/clear"
  mkdir -p "$root/config"
  run_set "$root/config" >/dev/null 2>&1 || fail "clear fixture failed"
  sibling="$root/config/keep-me"
  printf 'keep\n' > "$sibling"
  FM_CONFIG_OVERRIDE="$root/config" "$IMPORTER" clear >/dev/null \
    || fail "safe clear failed"
  [ ! -e "$root/config/plan-usage-manual.json" ] || fail "clear kept the manual snapshot"
  [ "$(cat "$sibling")" = keep ] || fail "clear affected a sibling file"
  FM_CONFIG_OVERRIDE="$root/config" "$IMPORTER" clear >/dev/null \
    || fail "absent clear was not idempotent"
  pass "clear removes only the fixed manual snapshot and is idempotent"
}

test_help_owns_guided_boundary
test_success_permissions_and_manual_projection
test_hostile_malformed_range_and_expiry_keep_prior
test_permissions_symlink_containment_and_atomic_failure
test_clear_only_fixed_snapshot
