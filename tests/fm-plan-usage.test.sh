#!/usr/bin/env bash
# Deterministic fake-protocol and cache/security tests for
# fm-plan-usage-snapshot.v1. No test starts a thread or model turn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-plan-usage)
SNAPSHOT="$ROOT/bin/fm-plan-usage-snapshot.sh"
BASE_PATH=$PATH

json_assert() { # <json> <python expression over value>
  if ! JSON_INPUT=$1 ASSERTION=$2 python3 - <<'PY'
import json, os
value = json.loads(os.environ["JSON_INPUT"])
assert eval(os.environ["ASSERTION"], {"value": value})
PY
  then
    fail "assertion failed: $2"$'\n'"--- json ---"$'\n'"$1"
  fi
}

make_fake_codex() { # <root>
  local root=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/codex" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time
from pathlib import Path

home = Path(os.environ["HOME"])
log = home / "calls.log"
mode = (home / "mode").read_text().strip() if (home / "mode").exists() else "ok"
version = (home / "version").read_text().strip() if (home / "version").exists() else "codex-cli 0.144.1"
if sys.argv[1:] == ["--version"]:
    print(version)
    raise SystemExit(0)
if sys.argv[1:] != ["-s", "read-only", "-a", "untrusted", "app-server", "--stdio"]:
    raise SystemExit(9)
if os.environ.get("OPENAI_API_KEY"):
    log.write_text(log.read_text() + "FORWARDED_OPENAI_API_KEY\n")
log.write_text(log.read_text() + "spawn\n")
if mode == "timeout":
    time.sleep(10)
    raise SystemExit(1)
requests = []
for _ in range(3):
    line = sys.stdin.readline()
    if not line:
        raise SystemExit(8)
    requests.append(json.loads(line))
log.write_text(log.read_text() + json.dumps(requests, separators=(",", ":")) + "\n")
methods = [item.get("method") for item in requests]
if methods != ["initialize", "account/read", "account/rateLimits/read"]:
    raise SystemExit(7)
if any("thread" in json.dumps(item).lower() or "turn" in json.dumps(item).lower() for item in requests):
    raise SystemExit(6)
print(json.dumps({"id": 1, "result": {"serverInfo": {"name": "codex", "version": "PRIVATE_VERSION"}}}))
if mode == "api-key":
    print(json.dumps({"id": 2, "result": {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True}}))
elif mode == "schema":
    print(json.dumps({"id": 2, "result": {"account": {"type": "chatgpt", "email": "PRIVATE_EMAIL", "planType": "plus"}, "requiresOpenaiAuth": True}}))
    print(json.dumps({"id": 3, "result": {"rateLimits": {"primary": {"usedPercent": 101, "windowDurationMins": 300, "resetsAt": 1800000000}}}}))
    raise SystemExit(0)
else:
    print(json.dumps({"id": 2, "result": {"account": {"type": "chatgpt", "email": "PRIVATE_EMAIL", "planType": "plus"}, "requiresOpenaiAuth": True}}))
if mode == "api-key":
    print(json.dumps({"id": 3, "result": {"rateLimits": {}}}))
else:
    general = {
        "limitId": "PRIVATE_GENERAL_LIMIT_ID",
        "planType": "plus",
        "primary": {"usedPercent": 43, "windowDurationMins": 10080, "resetsAt": 1800000000},
        "secondary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1790000000},
    }
    scoped = {
        "limitId": "PRIVATE_SCOPED_LIMIT_ID",
        "limitName": "gpt-5.6",
        "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1790000000},
    }
    print(json.dumps({"id": 3, "result": {
        "rateLimits": general,
        "rateLimitsByLimitId": {"PRIVATE_INTERNAL_MAP_KEY": scoped},
        "rateLimitResetCredits": {"availableCount": 1, "credits": [{"id": "PRIVATE_CREDIT_ID"}]},
    }}))
PY
  chmod +x "$fakebin/codex"
  mkdir -p "$root/home"
  : > "$root/home/calls.log"
}

run_snapshot() { # <root> <now> [mode] [version]
  local root=$1 now=$2 mode=${3:-ok} version=${4:-codex-cli 0.144.1}
  printf '%s\n' "$mode" > "$root/home/mode"
  printf '%s\n' "$version" > "$root/home/version"
  PATH="$root/fakebin:$BASE_PATH" \
  HOME="$root/home" LANG=C OPENAI_API_KEY=PRIVATE_API_KEY_MUST_NOT_FORWARD \
  FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW="$now" \
  FM_STATE_OVERRIDE="$root/state" "$SNAPSHOT" --json
}

spawn_count() { # <log>
  grep -c '^spawn$' "$1" 2>/dev/null || true
}

test_official_protocol_projection_and_cache() {
  local root out out2 out3 lock_pid
  root="$TMP_ROOT/official"
  mkdir -p "$root/state" "$root/home"
  make_fake_codex "$root"
  out=$(run_snapshot "$root" 1785542400) || fail "plan snapshot fake protocol failed"
  [ "${#out}" -le $((64 * 1024)) ] || fail "plan snapshot exceeded 64 KiB"
  json_assert "$out" 'value["schema"] == "fm-plan-usage-snapshot.v1" and len(value["providers"]) == 2'
  json_assert "$out" 'value["providers"][0]["plan"] == "plus" and value["providers"][0]["status"] == "fresh"'
  json_assert "$out" '[(w["label"],w["usedPercent"],w["remainingPercent"],w["windowSeconds"]) for w in value["providers"][0]["windows"][:2]] == [("7-day",43,57,604800),("5-hour",25,75,18000)]'
  json_assert "$out" 'value["providers"][0]["windows"][2]["scope"] == "model" and value["providers"][0]["windows"][2]["label"] == "gpt-5.6"'
  json_assert "$out" 'value["providers"][1] == {"provider":"claude","product":"claude_subscription","plan":None,"status":"unavailable","observedAt":None,"expiresAt":None,"reason":"unsupported_machine_readable_source","windows":[]}'
  for marker in PRIVATE_EMAIL PRIVATE_GENERAL PRIVATE_SCOPED PRIVATE_INTERNAL PRIVATE_CREDIT PRIVATE_API_KEY; do
    assert_not_contains "$out" "$marker" "plan projection exposed $marker"
  done
  assert_no_grep FORWARDED_OPENAI_API_KEY "$root/home/calls.log" "OPENAI_API_KEY reached app-server"
  assert_grep '"method":"account/read"' "$root/home/calls.log" "account/read was not called"
  assert_grep '"method":"account/rateLimits/read"' "$root/home/calls.log" "rateLimits/read was not called"
  assert_no_grep 'thread/' "$root/home/calls.log" "plan reader started or read a thread"
  assert_no_grep 'turn/' "$root/home/calls.log" "plan reader started a turn"
  [ "$(spawn_count "$root/home/calls.log")" = 1 ] || fail "first plan call did not spawn exactly once"

  out2=$(run_snapshot "$root" 1785542459 timeout) || fail "cached plan snapshot failed"
  [ "$(spawn_count "$root/home/calls.log")" = 1 ] || fail "60-second cache refreshed early"
  json_assert "$out2" 'value["providers"][0]["status"] == "fresh"'

  out3=$(run_snapshot "$root" 1785542461) || fail "plan cache refresh failed"
  [ "$(spawn_count "$root/home/calls.log")" = 2 ] || fail "cache did not refresh after 60 seconds"
  json_assert "$out3" 'value["providers"][0]["status"] == "fresh"'
  [ "$(stat -f '%Lp' "$root/state/.plan-usage-cache.json" 2>/dev/null || stat -c '%a' "$root/state/.plan-usage-cache.json")" = 600 ] \
    || fail "plan cache is not owner-only"

  python3 - "$root/state/.plan-usage.lock" "$root/lock-ready" <<'PY' &
import fcntl, pathlib, sys, time
lock, ready = map(pathlib.Path, sys.argv[1:])
with lock.open("a+") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    ready.write_text("ready\n")
    time.sleep(2)
PY
  lock_pid=$!
  for _ in $(seq 1 50); do [ -f "$root/lock-ready" ] && break; sleep 0.02; done
  [ -f "$root/lock-ready" ] || fail "single-flight fixture did not acquire the lock"
  out3=$(run_snapshot "$root" 1785542522 timeout) || fail "single-flight cached snapshot failed"
  [ "$(spawn_count "$root/home/calls.log")" = 2 ] || fail "single-flight contention spawned a second app-server"
  json_assert "$out3" 'value["providers"][0]["status"] == "stale" and value["providers"][0]["reason"] == "source_error"'
  wait "$lock_pid" || fail "single-flight lock fixture failed"
  pass "Codex official account protocol projects exact durations and honors 60-second single-flight caching"
}

test_schema_auth_timeout_stale_and_reset_controls() {
  local root out
  root="$TMP_ROOT/failures"
  mkdir -p "$root/state" "$root/home"
  make_fake_codex "$root"

  out=$(run_snapshot "$root" 1785542400 api-key) || fail "API-key snapshot failed"
  json_assert "$out" 'value["providers"][0]["status"] == "unavailable" and value["providers"][0]["reason"] == "api_key_not_subscription"'

  rm -f "$root/state/.plan-usage-cache.json"
  out=$(run_snapshot "$root" 1785542400 schema) || fail "schema-refusal snapshot failed"
  json_assert "$out" 'value["providers"][0]["status"] == "unavailable" and value["providers"][0]["reason"] == "unsupported_schema"'

  rm -f "$root/state/.plan-usage-cache.json"
  out=$(run_snapshot "$root" 1785542400 ok 'codex-cli 0.145.0') || fail "version-gate snapshot failed"
  json_assert "$out" 'value["providers"][0]["reason"] == "unsupported_schema"'

  rm -f "$root/state/.plan-usage-cache.json"
  out=$(run_snapshot "$root" 1785542400 ok) || fail "fresh snapshot for stale test failed"
  out=$(run_snapshot "$root" 1785542461 timeout) || fail "timeout stale fallback failed"
  json_assert "$out" 'value["providers"][0]["status"] == "stale" and value["providers"][0]["reason"] == "timeout"'

  # Once every shown reset is reached, cached percentages are suppressed.
  out=$(run_snapshot "$root" 1800000001 timeout) || fail "expired cache snapshot failed"
  json_assert "$out" 'value["providers"][0]["status"] == "unavailable" and value["providers"][0]["windows"] == []'
  rm -f "$root/state/.plan-usage-cache.json"
  out=$(run_snapshot "$root" 1800000001 ok) || fail "expired fresh-source snapshot failed"
  json_assert "$out" 'value["providers"][0]["status"] == "unavailable" and value["providers"][0]["reason"] == "expired" and value["providers"][0]["windows"] == []'
  pass "plan reader gates auth/version/schema, bounds timeout, and suppresses expired cached windows"
}

test_manual_claude_boundary_is_disabled_bounded_and_expiring() {
  local root manual external out
  root="$TMP_ROOT/manual"
  mkdir -p "$root/state" "$root/home" "$root/config"
  make_fake_codex "$root"
  manual="$root/config/plan-usage-manual.json"
  cat > "$manual" <<'JSON'
{"schema":"fm-plan-usage-manual.v1","provider":"claude","plan":"pro","observedAt":"2026-08-01T00:00:00.000Z","expiresAt":"2026-08-01T01:00:00.000Z","windows":[{"slot":"primary","usedPercent":40,"windowDurationMins":300,"resetsAt":1785546000},{"slot":"secondary","usedPercent":70,"windowDurationMins":10080,"resetsAt":1786147200}]}
JSON
  chmod 600 "$manual"

  out=$(FM_CONFIG_OVERRIDE="$root/config" run_snapshot "$root" 1785542400) \
    || fail "disabled manual snapshot failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "unsupported_machine_readable_source"'

  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$root/config" run_snapshot "$root" 1785542400) \
    || fail "enabled manual snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "manual" and value["providers"][1]["reason"] == "manual_snapshot"'
  json_assert "$out" 'value["providers"][1]["expiresAt"] == "2026-08-01T01:00:00.000Z" and value["providers"][1]["plan"] == "pro"'
  json_assert "$out" '[(w["label"],w["remainingPercent"]) for w in value["providers"][1]["windows"]] == [("5-hour",60),("7-day",30)]'

  chmod 644 "$manual"
  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$root/config" run_snapshot "$root" 1785542400) \
    || fail "manual owner-mode refusal failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  chmod 600 "$manual"

  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$root/config" run_snapshot "$root" 1785546001) \
    || fail "expired manual snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "unavailable" and value["providers"][1]["reason"] == "expired" and value["providers"][1]["windows"] == []'

  external="$root/PRIVATE_MANUAL_PROMPT"
  printf '%s\n' '{"prompt":"PRIVATE_MANUAL_PROMPT"}' > "$external"
  rm -f "$manual"
  ln -s "$external" "$manual"
  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$root/config" run_snapshot "$root" 1785542400) \
    || fail "manual symlink refusal failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  assert_not_contains "$out" PRIVATE_MANUAL_PROMPT "manual Claude boundary followed or reflected a symlink"

  rm -f "$manual"
  python3 - "$manual" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"x" * (16 * 1024 + 1))
Path(sys.argv[1]).chmod(0o600)
PY
  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$root/config" run_snapshot "$root" 1785542400) \
    || fail "oversized manual refusal failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  assert_grep 'config/plan-usage-manual.json' "$ROOT/.gitignore" \
    "the documented local manual plan snapshot is not gitignored"
  pass "manual Claude plan input is disabled by default, owner-only, bounded, explicit, and expiring"
}

test_cache_symlink_refused_and_source_policy_static() {
  local root external out
  root="$TMP_ROOT/symlink"
  mkdir -p "$root/state" "$root/home"
  make_fake_codex "$root"
  external="$root/private-cache"
  printf '%s\n' '{"PRIVATE_CACHE":"secret"}' > "$external"
  ln -s "$external" "$root/state/.plan-usage-cache.json"
  out=$(run_snapshot "$root" 1785542400) || fail "snapshot did not recover from cache symlink"
  assert_not_contains "$out" PRIVATE_CACHE "plan reader followed cache symlink"
  assert_no_grep 'quota-axi' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation calls quota-axi"
  assert_no_grep 'api.openai.com' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation has direct vendor HTTP"
  assert_no_grep '/usage' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation automates Claude /usage"
  pass "plan cache refuses symlinks and implementation excludes forbidden sources"
}

test_official_protocol_projection_and_cache
test_schema_auth_timeout_stale_and_reset_controls
test_manual_claude_boundary_is_disabled_bounded_and_expiring
test_cache_symlink_refused_and_source_policy_static
