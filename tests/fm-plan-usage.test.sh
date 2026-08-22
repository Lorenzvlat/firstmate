#!/usr/bin/env bash
# Deterministic fake-protocol and cache/security tests for
# fm-plan-usage-snapshot.v2. No test starts a thread or model turn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-plan-usage)
SNAPSHOT="$ROOT/bin/fm-plan-usage-snapshot.sh"
INIT="$ROOT/bin/fm-worker-telemetry-init.sh"
CLAUDE="$ROOT/bin/fm-claude-telemetry.sh"
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

# Portable mode read. Platform-detected, never the `stat -f || stat -c` fallback:
# GNU `stat -f` means --file-system, so on Linux it prints filesystem details for
# the file (and fails on the format operand) before the fallback ever runs.
file_mode() { # <path>
  if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
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

send_claude_status() { # <state> <task> <generation> <now> <payload>
  printf '%s' "$5" \
    | FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW="$4" \
      FM_STATE_OVERRIDE="$1" "$CLAUDE" status "$2" "$3"
}

test_official_protocol_projection_and_cache() {
  local root out out2 out3 lock_pid
  root="$TMP_ROOT/official"
  mkdir -p "$root/state" "$root/home"
  make_fake_codex "$root"
  out=$(run_snapshot "$root" 1785542400) || fail "plan snapshot fake protocol failed"
  [ "${#out}" -le $((64 * 1024)) ] || fail "plan snapshot exceeded 64 KiB"
  json_assert "$out" 'value["schema"] == "fm-plan-usage-snapshot.v2" and len(value["providers"]) == 2'
  json_assert "$out" 'value["providers"][0]["plan"] == "plus" and value["providers"][0]["status"] == "fresh"'
  json_assert "$out" '[(w["label"],w["usedPercent"],w["remainingPercent"],w["windowSeconds"]) for w in value["providers"][0]["windows"][:2]] == [("7-day",43,57,604800),("5-hour",25,75,18000)]'
  json_assert "$out" 'value["providers"][0]["windows"][2]["scope"] == "model" and value["providers"][0]["windows"][2]["label"] == "gpt-5.6"'
  json_assert "$out" 'value["providers"][1] == {"provider":"claude","product":"claude_subscription","plan":None,"status":"unavailable","observedAt":None,"expiresAt":None,"reason":"not_observed","windows":[]}'
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
  [ "$(file_mode "$root/state/.plan-usage-cache.json")" = 600 ] \
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

test_claude_statusline_projection_versions_and_privacy() {
  local root state generation payload cache out marker
  root="$TMP_ROOT/claude-official"
  state="$root/state"
  mkdir -p "$state" "$root/home"
  make_fake_codex "$root"
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" claude-plan-x1 claude) \
    || fail "Claude plan receiver fixture init failed"
  payload='{"version":"2.1.221","model":{"id":"claude-opus-4-1"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785559400,"PRIVATE_WINDOW":"PRIVATE_WINDOW_MARKER"},"seven_day":{"used_percentage":41.2,"resets_at":1786142400}},"session_id":"PRIVATE_SESSION","prompt_id":"PRIVATE_PROMPT","transcript_path":"PRIVATE_TRANSCRIPT","cwd":"PRIVATE_CWD","repository":"PRIVATE_REPOSITORY","command":"PRIVATE_COMMAND","credential":"PRIVATE_CREDENTIAL","unknown":{"account":"PRIVATE_ACCOUNT"}}'
  send_claude_status "$state" claude-plan-x1 "$generation" 1785542400 "$payload"
  [ -f "$state/.claude-plan-usage-cache.json" ] || fail "valid status-line plan was not cached"
  [ ! -L "$state/.claude-plan-usage-cache.json" ] || fail "Claude plan cache is a symlink"
  [ "$(file_mode "$state/.claude-plan-usage-cache.json")" = 600 ] \
    || fail "Claude plan cache is not owner-only"
  [ "$(file_mode "$state/.claude-plan-usage.lock")" = 600 ] \
    || fail "Claude plan lock is not owner-only"
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'set(value) == {"schema","source","sourceVersion","observedAt","windows"}'
  json_assert "$cache" 'value["schema"] == "fm-claude-plan-statusline-cache.v1" and value["source"] == "claude_code_statusline" and value["sourceVersion"] == "2.1.221"'
  json_assert "$cache" '[(w["window"],w["usedPercent"],w["resetsAt"]) for w in value["windows"]] == [("five_hour",23.5,1785559400),("seven_day",41.2,1786142400)]'
  out=$(run_snapshot "$root" 1785542400) || fail "official Claude plan snapshot failed"
  json_assert "$out" 'value["schema"] == "fm-plan-usage-snapshot.v2"'
  json_assert "$out" 'value["providers"][1]["status"] == "fresh" and value["providers"][1]["reason"] is None and value["providers"][1]["plan"] is None'
  json_assert "$out" '[(w["key"],w["label"],w["usedPercent"],w["remainingPercent"],w["windowSeconds"]) for w in value["providers"][1]["windows"]] == [("general:five_hour:300","5-hour",23.5,76.5,18000),("general:seven_day:10080","7-day",41.2,58.8,604800)]'
  for marker in PRIVATE_WINDOW PRIVATE_SESSION PRIVATE_PROMPT PRIVATE_TRANSCRIPT PRIVATE_CWD PRIVATE_REPOSITORY PRIVATE_COMMAND PRIVATE_CREDENTIAL PRIVATE_ACCOUNT; do
    assert_not_contains "$cache" "$marker" "Claude cache retained private status-line field $marker"
    assert_not_contains "$out" "$marker" "Claude snapshot retained private status-line field $marker"
  done

  rm -f "$state/.claude-plan-usage-cache.json"
  send_claude_status "$state" claude-plan-x1 "$generation" 1785542400 \
    '{"version":"2.1.79","rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1785559400}}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "Claude Code 2.1.79 was admitted"
  send_claude_status "$state" claude-plan-x1 "$generation" 1785542400 \
    '{"version":"2.1.80","rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1785559400}}}'
  [ -f "$state/.claude-plan-usage-cache.json" ] || fail "Claude Code 2.1.80 was refused"
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["sourceVersion"] == "2.1.80" and value["windows"][0]["usedPercent"] == 0'
  rm -f "$state/.claude-plan-usage-cache.json"
  send_claude_status "$state" claude-plan-x1 "$generation" 1785542400 \
    '{"version":"2.1.221","rate_limits":{"seven_day":{"used_percentage":100,"resets_at":1786142400}}}'
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["sourceVersion"] == "2.1.221" and value["windows"] == [{"resetsAt":1786142400,"usedPercent":100,"window":"seven_day"}]'
  rm -f "$state/.claude-plan-usage-cache.json"
  send_claude_status "$state" claude-plan-x1 "$generation" 1785542400 \
    '{"version":"3.0.0","rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1785559400}}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "unrecognized Claude Code major was admitted"
  out=$(run_snapshot "$root" 1785542400) || fail "not-observed Claude snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "unavailable" and value["providers"][1]["reason"] == "not_observed"'
  marker="$state/PRIVATE_MARKER"
  [ ! -e "$marker" ] || fail "unexpected private marker fixture exists"
  pass "Claude status-line plan projection gates versions, preserves decimals, and retains only allowlisted fields"
}

test_claude_statusline_shape_ranges_and_window_independence() {
  local root state generation payload percentage reset
  root="$TMP_ROOT/claude-shapes"
  state="$root/state"
  mkdir -p "$state"
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" claude-shape-x1 claude) \
    || fail "Claude shape fixture init failed"

  send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 \
    '{"version":"2.1.221","rate_limits":{}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "empty rate limits created a cache"
  send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 \
    '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20,"resets_at":1786142400}}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] \
    || fail "one malformed present window allowed the other window"

  for percentage in true '"40"' NaN Infinity -0.1 100.1 0.30000000000000004; do
    payload=$(printf '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":1785559400}}}' "$percentage")
    send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 "$payload"
    [ ! -e "$state/.claude-plan-usage-cache.json" ] \
      || fail "invalid percentage $percentage created a cache"
  done
  for reset in true '"1785559400"' 1785559400.5 253402300800; do
    payload=$(printf '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":20,"resets_at":%s}}}' "$reset")
    send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 "$payload"
    [ ! -e "$state/.claude-plan-usage-cache.json" ] \
      || fail "invalid reset $reset created a cache"
  done
  send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 \
    '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1785560701}}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "unsafe future reset created a cache"
  send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 \
    '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1785542399},"seven_day":{"used_percentage":20,"resets_at":1786142400}}}'
  payload=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$payload" 'value["windows"] == [{"resetsAt":1786142400,"usedPercent":20,"window":"seven_day"}]'
  rm -f "$state/.claude-plan-usage-cache.json"
  payload=$(python3 - <<'PY'
import json
print(json.dumps({"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1785559400}},"unknown":"x" * (16 * 1024)}))
PY
)
  send_claude_status "$state" claude-shape-x1 "$generation" 1785542400 "$payload"
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "oversized status-line JSON created a cache"
  send_claude_status "$state" claude-shape-x1 00000000000000000000000000000000 1785542400 \
    '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1785559400}}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "foreign generation created a cache"
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" nonclaude-shape-x2 pi) \
    || fail "non-Claude shape fixture init failed"
  send_claude_status "$state" nonclaude-shape-x2 "$generation" 1785542400 \
    '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1785559400}}}'
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "non-Claude harness created a cache"
  pass "Claude plan admission rejects malformed, non-finite, out-of-range, unprojectable, unsafe, oversized, and foreign observations"
}

test_claude_cache_security_races_and_passive_failure() {
  local root state generation payload external cache pids pid i record owner_probe out lock_pid
  root="$TMP_ROOT/claude-cache-security"
  state="$root/state"
  mkdir -p "$state" "$root/home"
  make_fake_codex "$root"
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" claude-safe-x1 claude) \
    || fail "Claude cache safety fixture init failed"
  payload='{"version":"2.1.221","model":{"id":"claude-opus-4-1"},"rate_limits":{"five_hour":{"used_percentage":25.5,"resets_at":1785559400}}}'
  external="$root/PRIVATE_EXTERNAL"
  printf '%s\n' PRIVATE_EXTERNAL_UNCHANGED > "$external"
  ln -s "$external" "$state/.claude-plan-usage-cache.json"
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542400 "$payload"
  [ -L "$state/.claude-plan-usage-cache.json" ] || fail "unsafe cache symlink was replaced"
  assert_grep PRIVATE_EXTERNAL_UNCHANGED "$external" "cache symlink target was modified"
  record=$(<"$state/claude-safe-x1.telemetry.json")
  json_assert "$record" 'value["model"]["id"] == "claude-opus-4-1"'
  [ -f "$state/.claude-safe-x1.claude-live" ] \
    || fail "cache write failure prevented worker liveness"

  rm -f "$state/.claude-plan-usage-cache.json"
  printf '%s\n' PRIVATE_WRONG_MODE > "$state/.claude-plan-usage-cache.json"
  chmod 644 "$state/.claude-plan-usage-cache.json"
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542400 "$payload"
  assert_grep PRIVATE_WRONG_MODE "$state/.claude-plan-usage-cache.json" \
    "wrong-mode cache was replaced"
  out=$(run_snapshot "$root" 1785542400) || fail "wrong-mode Claude cache snapshot failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  assert_not_contains "$out" PRIVATE_WRONG_MODE "wrong-mode Claude cache content was reflected"
  chmod 600 "$state/.claude-plan-usage-cache.json"
  out=$(run_snapshot "$root" 1785542400) || fail "malformed Claude cache snapshot failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542400 "$payload"
  cache=$(<"$state/.claude-plan-usage-cache.json")
  assert_not_contains "$cache" PRIVATE_WRONG_MODE "malformed owner-only cache was not replaced"
  json_assert "$cache" 'value["observedAt"] == "2026-08-01T00:00:00.000Z" and value["windows"] == [{"resetsAt":1785559400,"usedPercent":25.5,"window":"five_hour"}]'

  send_claude_status "$state" claude-safe-x1 "$generation" 1785542430 "$payload"
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["observedAt"] == "2026-08-01T00:00:00.000Z"'
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542470 "$payload"
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["observedAt"] == "2026-08-01T00:01:10.000Z"'
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542475 \
    '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":26.5,"resets_at":1785559400}}}'
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["observedAt"] == "2026-08-01T00:01:15.000Z" and value["windows"][0]["usedPercent"] == 26.5'
  out=$(run_snapshot "$root" 1785542475) || fail "refreshed Claude cache snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "fresh" and value["providers"][1]["windows"][0]["usedPercent"] == 26.5'

  python3 - "$state/.claude-plan-usage-cache.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
record = json.loads(path.read_text())
record["observedAt"] = "2126-08-01T00:00:00.000Z"
path.write_text(json.dumps(record))
path.chmod(0o600)
PY
  out=$(run_snapshot "$root" 1785542475) || fail "future-observation Claude cache snapshot failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542480 "$payload"
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["observedAt"] == "2026-08-01T00:01:20.000Z" and value["windows"][0]["usedPercent"] == 25.5'

  python3 - "$state/.claude-plan-usage-cache.json" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"x" * (4 * 1024 + 1))
Path(sys.argv[1]).chmod(0o600)
PY
  out=$(run_snapshot "$root" 1785542400) || fail "oversized Claude cache snapshot failed"
  json_assert "$out" 'value["providers"][1]["reason"] == "source_error" and value["providers"][1]["windows"] == []'
  rm -f "$state/.claude-plan-usage-cache.json"

  rm -f "$state/.claude-plan-usage.lock"
  ln -s "$external" "$state/.claude-plan-usage.lock"
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542400 "$payload"
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "symlinked lock allowed a cache write"
  rm -f "$state/.claude-plan-usage.lock"
  ln -s "$external" "$state/.claude-plan-usage-cache.json.tmp"
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542400 "$payload"
  [ ! -e "$state/.claude-plan-usage-cache.json" ] || fail "symlinked staging file allowed a cache write"
  assert_grep PRIVATE_EXTERNAL_UNCHANGED "$external" "staging symlink target was modified"
  rm -f "$state/.claude-plan-usage-cache.json.tmp"

  python3 - "$state/.claude-plan-usage.lock" "$root/lock-ready" <<'PY' &
import fcntl, os, pathlib, sys, time
lock, ready = map(pathlib.Path, sys.argv[1:])
with lock.open("a+") as stream:
    os.fchmod(stream.fileno(), 0o600)
    fcntl.flock(stream, fcntl.LOCK_EX)
    ready.write_text("ready\n")
    time.sleep(2)
PY
  lock_pid=$!
  for _ in $(seq 1 50); do [ -f "$root/lock-ready" ] && break; sleep 0.02; done
  [ -f "$root/lock-ready" ] || fail "Claude cache contention fixture did not acquire the lock"
  payload='{"version":"2.1.221","model":{"id":"claude-haiku-4-5"},"rate_limits":{"five_hour":{"used_percentage":25.5,"resets_at":1785559400}}}'
  send_claude_status "$state" claude-safe-x1 "$generation" 1785542400 "$payload"
  [ ! -e "$state/.claude-plan-usage-cache.json" ] \
    || fail "contended Claude cache writer bypassed the shared lock"
  record=$(<"$state/claude-safe-x1.telemetry.json")
  json_assert "$record" 'value["model"]["id"] == "claude-haiku-4-5"'
  wait "$lock_pid" || fail "Claude cache contention fixture failed"

  pids=
  for i in 1 2 3 4 5 6; do
    generation=$(FM_STATE_OVERRIDE="$state" "$INIT" "claude-race-x$i" claude) \
      || fail "Claude cache race fixture $i init failed"
    payload=$(printf '{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":%s.5,"resets_at":1785559400}}}' "$i")
    send_claude_status "$state" "claude-race-x$i" "$generation" 1785542400 "$payload" &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent Claude cache writer failed"
  done
  cache=$(<"$state/.claude-plan-usage-cache.json")
  json_assert "$cache" 'value["schema"] == "fm-claude-plan-statusline-cache.v1" and value["windows"][0]["usedPercent"] in {1.5,2.5,3.5,4.5,5.5,6.5}'
  [ ! -e "$state/.claude-plan-usage-cache.json.tmp" ] \
    || fail "concurrent Claude cache writers left staging state"
  owner_probe=$(FM_TELEMETRY_STATE="$state" FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" python3 - <<'PY'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("fm_telemetry", os.environ["FM_TELEMETRY_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = module.state_root(os.environ["FM_TELEMETRY_STATE"])
real_euid = module.os.geteuid
module.os.geteuid = lambda: real_euid() + 1
print(json.dumps(module.cached_claude_plan(root)[1]))
PY
) || fail "wrong-owner cache probe failed"
  [ "$owner_probe" = '"source_error"' ] || fail "wrong-owner cache was not refused"
  pass "Claude plan cache is owner-only, no-follow, atomic under races, self-healing, and passive on write failure"
}

test_claude_freshness_independent_expiry_and_manual_fallback() {
  local root state config generation payload manual out
  root="$TMP_ROOT/claude-precedence"
  state="$root/state"
  config="$root/config"
  mkdir -p "$state" "$config" "$root/home"
  make_fake_codex "$root"
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" claude-precedence-x1 claude) \
    || fail "Claude precedence fixture init failed"
  payload='{"version":"2.1.221","rate_limits":{"five_hour":{"used_percentage":33.3,"resets_at":1785542460},"seven_day":{"used_percentage":66.7,"resets_at":1785546000}}}'
  send_claude_status "$state" claude-precedence-x1 "$generation" 1785542400 "$payload"
  manual="$config/plan-usage-manual.json"
  printf '%s\n' '{"schema":"fm-plan-usage-manual.v1","provider":"claude","plan":"pro","observedAt":"2026-08-01T00:00:00.000Z","expiresAt":"2026-08-01T02:00:00.000Z","windows":[{"slot":"primary","usedPercent":40,"windowDurationMins":300,"resetsAt":1785549600}]}' > "$manual"
  chmod 600 "$manual"

  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$config" run_snapshot "$root" 1785542400) \
    || fail "official-over-manual snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "fresh" and value["providers"][1]["reason"] is None and value["providers"][1]["plan"] is None'
  json_assert "$out" '[w["usedPercent"] for w in value["providers"][1]["windows"]] == [33.3,66.7]'

  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$config" run_snapshot "$root" 1785542521) \
    || fail "independent-window stale snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "stale" and value["providers"][1]["reason"] is None'
  json_assert "$out" '[(w["label"],w["usedPercent"],w["remainingPercent"]) for w in value["providers"][1]["windows"]] == [("7-day",66.7,33.3)]'

  out=$(FM_PLAN_USAGE_MANUAL=1 FM_CONFIG_OVERRIDE="$config" run_snapshot "$root" 1785543300) \
    || fail "manual fallback after official expiry failed"
  json_assert "$out" 'value["providers"][1]["status"] == "manual" and value["providers"][1]["reason"] == "manual_snapshot" and value["providers"][1]["plan"] == "pro"'
  out=$(FM_CONFIG_OVERRIDE="$config" run_snapshot "$root" 1785543300) \
    || fail "official provider-expiry snapshot failed"
  json_assert "$out" 'value["providers"][1]["status"] == "unavailable" and value["providers"][1]["reason"] == "expired" and value["providers"][1]["windows"] == []'
  pass "Claude official data is fresh for two minutes, expires windows independently, and falls back to explicit Manual data"
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
  json_assert "$out" 'value["providers"][1]["reason"] == "not_observed"'

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
  assert_no_grep 'api.anthropic.com' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation has direct Anthropic HTTP"
  assert_no_grep 'claude.ai' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation scrapes claude.ai"
  assert_no_grep 'find-generic-password' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation reads Keychain credentials"
  assert_no_grep '/usage' "$ROOT/bin/telemetry/fm-telemetry.py" "plan implementation automates Claude /usage"
  pass "plan cache refuses symlinks and implementation excludes forbidden sources"
}

test_official_protocol_projection_and_cache
test_schema_auth_timeout_stale_and_reset_controls
test_claude_statusline_projection_versions_and_privacy
test_claude_statusline_shape_ranges_and_window_independence
test_claude_cache_security_races_and_passive_failure
test_claude_freshness_independent_expiry_and_manual_fallback
test_manual_claude_boundary_is_disabled_bounded_and_expiring
test_cache_symlink_refused_and_source_policy_static
