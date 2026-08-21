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
  assert_contains "$out" 'fm-plan-usage-manual.sh set' "help omitted creation action"
  assert_not_contains "$out" 'clear' "help retained automated clear"
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

test_hostile_malformed_range_and_expiry_leave_absent() {
  local root file hostile marker malformed malformed_reset range duration expired case_input
  root="$TMP_ROOT/refusals"
  mkdir -p "$root/config"
  file="$root/config/plan-usage-manual.json"

  marker="$root/must-not-execute"
  hostile="\$(touch $marker)"
  case_input="$hostile
"
  run_set "$root/config" "$case_input" >/dev/null 2>&1 \
    && fail "hostile plan input was accepted"
  [ ! -e "$marker" ] || fail "hostile input executed"

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
  [ ! -e "$file" ] || fail "a refused input created a snapshot"
  pass "hostile, malformed-time, range, and expiry failures leave the target absent"
}

test_permissions_symlink_containment_and_atomic_failure() {
  local root file external before staging_alias
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
  [ -L "$file" ] || fail "creation refusal removed the snapshot symlink"

  rm -f "$file"
  mkdir -p "$root/real-config"
  rm -rf "$root/config"
  ln -s "$root/real-config" "$root/config"
  run_set "$root/config" >/dev/null 2>&1 && fail "symlinked config containment was accepted"
  [ ! -e "$root/real-config/plan-usage-manual.json" ] || fail "containment refusal wrote outside the lexical config root"

  rm -f "$root/config"
  mkdir -p "$root/config"
  staging_alias="$root/config/.plan-usage-manual.json.tmp"
  ln "$external" "$staging_alias"
  run_set "$root/config" >/dev/null 2>&1 || fail "private exclusive staging was blocked by hostile legacy names"
  [ "$(cat "$external")" = external ] || fail "private staging changed a hard-linked external file"
  [ "$(cat "$staging_alias")" = external ] || fail "private staging changed the hostile legacy hard link"
  pass "permissions, symlink, containment, and atomic-write failures fail closed"
}

test_import_preserves_replacement_races() {
  local root external
  root="$TMP_ROOT/import-race"
  mkdir -p "$root/config"
  external="$root/external"
  printf 'external\n' > "$external"
  python3 - "$ROOT/bin/telemetry/fm-telemetry.py" "$root/config" "$external" <<'PY' \
    || fail "import target race did not fail closed"
import importlib.util
import io
import os
from pathlib import Path
from unittest import mock
import sys

spec = importlib.util.spec_from_file_location("fm_telemetry", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
os.environ["FM_TELEMETRY_TEST_MODE"] = "1"
os.environ["FM_TELEMETRY_TEST_NOW"] = "1785542400"
config = Path(sys.argv[2])
target = config / "plan-usage-manual.json"
external = Path(sys.argv[3])
real_publish = module.rename_noreplace

def replace_before_publish(source, destination):
    target.symlink_to(external)
    return real_publish(source, destination)

values = "\n".join([
    "pro", "2026-08-01T00:00:00.000Z", "2026-08-01T01:00:00.000Z", "1",
    "primary", "40", "300", "2026-08-01T00:30:00.000Z", "",
])
with mock.patch.object(module, "rename_noreplace", replace_before_publish), \
     mock.patch.object(module.sys, "stdin", io.StringIO(values)):
    try:
        module.manual_plan_import(config)
    except OSError:
        pass
    else:
        raise AssertionError("replacement target was overwritten")
assert target.is_symlink()
assert external.read_text() == "external\n"
assert not list(config.glob(".plan-usage-manual.*.tmp"))
PY
  [ "$(cat "$external")" = external ] || fail "import target race changed the concurrent replacement"
  pass "import publication preserves a target replaced during prompting"
}

test_bounded_non_echoing_retries() {
  local root file before out retry_input exhausted conflict_input conflict_exhausted
  root="$TMP_ROOT/retries"
  mkdir -p "$root/config"
  retry_input='PRIVATE_BAD_PLAN_ONE
PRIVATE_BAD_PLAN_TWO
PRIVATE_BAD_PLAN_THREE
pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
1
primary
40
300
2026-08-01T00:30:00.000Z
'
  out=$(run_set "$root/config" "$retry_input" 2>&1) \
    || fail "three bounded plan retries did not recover: $out"
  assert_not_contains "$out" PRIVATE_BAD_PLAN "retry diagnostics reflected a rejected value"

  file="$root/config/plan-usage-manual.json"
  rm -f "$file"
  exhausted='bad-one
bad-two
bad-three
bad-four
pro
'
  run_set "$root/config" "$exhausted" >/dev/null 2>&1 \
    && fail "a fourth invalid plan value did not exhaust retries"
  [ ! -e "$file" ] || fail "exhausted retries created a snapshot"

  conflict_input='pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
2
primary
40
300
2026-08-01T00:30:00.000Z
primary
50
300
2026-08-01T00:40:00.000Z
secondary
50
10080
2026-08-08T00:00:00.000Z
'
  out=$(run_set "$root/config" "$conflict_input" 2>&1) \
    || fail "conflicting identity retry did not recover: $out"
  assert_contains "$out" 'Window identity conflicts' "identity conflict did not produce a generic retry"

  rm -f "$file"
  conflict_exhausted='pro
2026-08-01T00:00:00.000Z
2026-08-01T01:00:00.000Z
2
primary
40
300
2026-08-01T00:30:00.000Z
primary
50
300
2026-08-01T00:40:00.000Z
primary
50
300
2026-08-01T00:40:00.000Z
primary
50
300
2026-08-01T00:40:00.000Z
primary
50
300
2026-08-01T00:40:00.000Z
'
  run_set "$root/config" "$conflict_exhausted" >/dev/null 2>&1 \
    && fail "a fourth conflicting identity did not exhaust retries"
  [ ! -e "$file" ] || fail "exhausted identity retries created a snapshot"
  pass "invalid fields and conflicting identities receive at most three non-echoing retries"
}

test_missing_python_has_distinct_diagnostic() {
  local root fakebin out
  root="$TMP_ROOT/missing-python"
  fakebin="$root/fakebin"
  mkdir -p "$root/config" "$fakebin"
  out=$(PATH="$fakebin" /bin/bash "$IMPORTER" set 2>&1) \
    && fail "manual importer succeeded without python3"
  assert_contains "$out" 'python3 is required' "missing python3 did not get a distinct diagnostic"
  pass "missing python3 is reported distinctly before set"
}

test_help_owns_guided_boundary
test_success_permissions_and_manual_projection
test_hostile_malformed_range_and_expiry_leave_absent
test_permissions_symlink_containment_and_atomic_failure
test_import_preserves_replacement_races
test_bounded_non_echoing_retries
test_missing_python_has_distinct_diagnostic
