#!/usr/bin/env bash
# Deterministic behavior/security tests for fm-worker-telemetry-snapshot.v1 and
# the newly launched Pi/Claude producer paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-telemetry)
SNAPSHOT="$ROOT/bin/fm-worker-telemetry-snapshot.sh"
INIT="$ROOT/bin/fm-worker-telemetry-init.sh"
PI_GENERATOR="$ROOT/bin/fm-pi-worker-extension.sh"
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

# Portable stat reads. Platform-detected, never the `stat -f || stat -c` fallback:
# GNU `stat -f` means --file-system, so on Linux it prints filesystem details for
# the file (and fails on the format operand) before the fallback ever runs.
file_mode() { # <path>
  if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

file_inode() { # <path>
  if [ "$(uname)" = Darwin ]; then stat -f '%i' "$1"; else stat -c '%i' "$1"; fi
}

make_meta() { # <state> <id> <harness>
  printf 'harness=%s\nkind=ship\n' "$3" > "$1/$2.meta"
}

test_snapshot_bounds_and_hostile_files() {
  local state external out generation i
  state="$TMP_ROOT/snapshot/state"
  external="$TMP_ROOT/snapshot/private.json"
  mkdir -p "$state"
  make_meta "$state" good-x1 pi
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" good-x1 pi) || fail "worker telemetry init failed"
  [ "${#generation}" -eq 32 ] || fail "generation nonce is not fixed length"
  [ "$(file_mode "$state/good-x1.telemetry.json")" = 600 ] \
    || fail "telemetry record is not owner-only"

  printf '%s\n' '{"prompt":"PRIVATE_PROMPT","token":"sk-private"}' > "$external"
  make_meta "$state" linked-x2 claude
  ln -s "$external" "$state/linked-x2.telemetry.json"

  make_meta "$state" open-x3 codex
  FM_STATE_OVERRIDE="$state" "$INIT" open-x3 codex >/dev/null
  chmod 644 "$state/open-x3.telemetry.json"

  make_meta "$state" huge-x4 pi
  python3 - "$state/huge-x4.telemetry.json" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"x" * (16 * 1024 + 1))
PY
  chmod 600 "$state/huge-x4.telemetry.json"

  for i in $(seq 1 105); do
    make_meta "$state" "many-$i" other
  done
  out=$(FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=1785542400 \
    FM_STATE_OVERRIDE="$state" "$SNAPSHOT" --json) || fail "worker snapshot failed"
  [ "${#out}" -le $((512 * 1024)) ] || fail "worker snapshot exceeded 512 KiB"
  json_assert "$out" 'value["schema"] == "fm-worker-telemetry-snapshot.v1"'
  json_assert "$out" 'len(value["workers"]) == 100 and value["omitted"] == 9'
  json_assert "$out" 'set(value["warnings"]).issubset({"invalid_metadata","invalid_telemetry","worker_limit","output_limit","source_error"}) and len(value["warnings"]) <= 5'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "good-x1")["status"] == "unavailable"'
  assert_not_contains "$out" PRIVATE_PROMPT "snapshot followed a telemetry symlink"
  assert_not_contains "$out" sk-private "snapshot exposed hostile telemetry content"
  pass "worker snapshot bounds count, bytes, owner mode, symlinks, and generic warning enums"
}

test_snapshot_status_timestamp_and_integer_controls() {
  local state id out
  state="$TMP_ROOT/statuses/state"
  mkdir -p "$state"
  for id in fresh-x1 partial-x2 stale-x3 final-x4 overflow-x5 timestamp-x6; do
    make_meta "$state" "$id" pi
    FM_STATE_OVERRIDE="$state" "$INIT" "$id" pi >/dev/null \
      || fail "status fixture init failed for $id"
  done
  printf '%s\n' 'selection_reason=matched_dispatch_rule' 'effort=xhigh' >> "$state/fresh-x1.meta"
  # shellcheck disable=SC2016 # hostile metadata fixture: the command-shaped effort value must reach the snapshot verbatim, not expand here
  printf '%s\n' 'selection_reason=Secret premium strategy from /private/captain' \
    'effort=$(cat ~/.credentials)' >> "$state/partial-x2.meta"
  python3 - "$state" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])

def update(task, **changes):
    path = root / f"{task}.telemetry.json"
    value = json.loads(path.read_text())
    value.update(changes)
    path.write_text(json.dumps(value) + "\n")
    path.chmod(0o600)

zero = {
    "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0,
    "reasoningOutput": None, "total": 0, "totalSemantics": "source_reported",
}
model = {"provider": "openai-codex", "id": "gpt-5.6-sol"}
update("fresh-x1", status="fresh", observedAt="2026-08-01T00:00:50.000Z", coverage="full_worker", final=False, model=model, tokens=zero)
update("partial-x2", status="partial", observedAt="2026-08-01T00:00:50.000Z", coverage="since_observed", final=False, model=model, tokens=zero)
update("stale-x3", status="fresh", observedAt="2026-07-31T23:59:00.000Z", coverage="full_worker", final=False, model=model, tokens=zero)
update("final-x4", status="fresh", observedAt="2026-07-31T23:59:00.000Z", coverage="full_worker", final=True, model=model, tokens=zero)
overflow = dict(zero, total=9007199254740992)
update("overflow-x5", status="fresh", observedAt="2026-08-01T00:00:50.000Z", coverage="full_worker", final=False, model=model, tokens=overflow)
update("timestamp-x6", status="fresh", observedAt="2026-08-01T00:00:50Z", coverage="full_worker", final=False, model=model, tokens=zero)
PY
  out=$(FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=1785542460 \
    FM_STATE_OVERRIDE="$state" "$SNAPSHOT" --json) || fail "status snapshot failed"
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "fresh-x1")["tokens"]["total"] == 0'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "fresh-x1")["selection"] == {"modelReason":"matched_dispatch_rule","modelReasonLabel":"Dispatch rule","effort":"xhigh","effortLabel":"Extra high"}'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "partial-x2")["status"] == "partial"'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "partial-x2")["selection"] == {"modelReason":"unavailable","modelReasonLabel":"Unavailable","effort":None,"effortLabel":"Unavailable"}'
  assert_not_contains "$out" 'Secret premium strategy' "worker snapshot exposed dispatch strategy prose"
  assert_not_contains "$out" '.credentials' "worker snapshot exposed command-shaped effort prose"
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "stale-x3")["status"] == "stale"'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "final-x4")["status"] == "fresh"'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "overflow-x5")["status"] == "unavailable"'
  json_assert "$out" 'next(w for w in value["workers"] if w["taskId"] == "timestamp-x6")["status"] == "unavailable"'
  pass "worker snapshot distinguishes status/integer controls and projects only fixed selection rationale labels"
}

test_pi_projection_exact_usage_and_passive_failure() {
  local state generation plugin out
  state="$TMP_ROOT/pi/state"
  mkdir -p "$state"
  make_meta "$state" pi-x1 pi
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" pi-x1 pi) || fail "Pi telemetry init failed"
  plugin="$state/pi-x1.pi-ext.ts"
  FM_STATE_OVERRIDE="$state" "$PI_GENERATOR" \
    pi-x1 "$generation" "$state/pi-x1.turn-ended" "$state/pi-x1.telemetry.json" "$plugin" \
    || fail "Pi extension generation failed"
  [ "$(file_mode "$plugin")" = 600 ] \
    || fail "generated Pi extension is not owner-only"
  assert_no_grep 'message.content' "$plugin" "Pi extension reads message content"
  assert_no_grep 'sessionManager' "$plugin" "Pi extension reads session history"

  out=$(PLUGIN="$plugin" RECORD="$state/pi-x1.telemetry.json" TURNEND="$state/pi-x1.turn-ended" \
    node --input-type=module <<'JS'
import { existsSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, handler); } };
const extension = await import(pathToFileURL(process.env.PLUGIN).href);
extension.default(pi);
await handlers.get("session_start")({}, { model: { provider: "openai-codex", id: "gpt-5.6-sol" } });
await handlers.get("message_end")({ message: { role: "assistant", provider: "openai-codex", model: "gpt-5.6-sol", usage: { input: 0, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 9 } } });
await handlers.get("model_select")({ model: { provider: "anthropic", id: "claude-sonnet-4-5" } });
await handlers.get("message_end")({ message: { role: "assistant", provider: "anthropic", model: "claude-sonnet-4-5", usage: { input: 5, output: 6, cacheRead: 0, cacheWrite: 1, totalTokens: 12 } } });
await handlers.get("session_shutdown")();
const good = JSON.parse(readFileSync(process.env.RECORD, "utf8"));
rmSync(process.env.RECORD);
symlinkSync("/dev/null", process.env.RECORD);
await handlers.get("turn_end")();
await new Promise((resolve) => setTimeout(resolve, 100));
console.log(JSON.stringify({ good, turnEnd: existsSync(process.env.TURNEND) }));
JS
  ) || fail "generated Pi extension fixture failed"
  json_assert "$out" 'value["good"]["model"] == {"provider":"anthropic","id":"claude-sonnet-4-5"}'
  json_assert "$out" 'value["good"]["tokens"] == {"input":5,"output":8,"cacheRead":3,"cacheWrite":5,"reasoningOutput":None,"total":21,"totalSemantics":"source_reported"}'
  json_assert "$out" 'value["good"]["coverage"] == "full_worker" and value["good"]["status"] == "fresh" and value["good"]["final"] is True'
  json_assert "$out" 'value["turnEnd"] is True'
  pass "Pi projects exact resolved model and finalized token components without content access"
}

test_pi_turn_end_survives_telemetry_registration_and_payload_failures() {
  local state generation plugin staging out
  state="$TMP_ROOT/pi-passive/state"
  mkdir -p "$state"
  make_meta "$state" pi-x2 pi
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" pi-x2 pi) || fail "passive Pi fixture init failed"
  plugin="$state/pi-x2.pi-ext.ts"
  staging="$state/.pi-x2.telemetry.json.tmp"
  FM_STATE_OVERRIDE="$state" "$PI_GENERATOR" \
    pi-x2 "$generation" "$state/pi-x2.turn-ended" "$state/pi-x2.telemetry.json" "$plugin" \
    || fail "passive Pi extension generation failed"
  printf 'leftover staging content\n' > "$staging"

  out=$(PLUGIN="$plugin" RECORD="$state/pi-x2.telemetry.json" TURNEND="$state/pi-x2.turn-ended" \
    STAGING="$staging" node --input-type=module <<'JS'
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const extension = await import(pathToFileURL(process.env.PLUGIN).href);

// A Pi build that rejects every event this launch did not already rely on.
const rejecting = new Map();
let registrationThrew = false;
try {
  extension.default({ on(name, handler) {
    if (name !== "turn_end") throw new Error("unsupported event");
    rejecting.set(name, handler);
  } });
} catch {
  registrationThrew = true;
}
await rejecting.get("turn_end")?.();
await new Promise((resolve) => setTimeout(resolve, 100));

const handlers = new Map();
extension.default({ on(name, handler) { handlers.set(name, handler); } });
let dispatchThrew = false;
try {
  await handlers.get("session_start")({}, undefined);
  await handlers.get("model_select")({});
  await handlers.get("message_end")({});
  await handlers.get("message_end")({ message: { role: "assistant" } });
} catch {
  dispatchThrew = true;
}
await handlers.get("message_end")({ message: { role: "assistant", provider: "anthropic", model: "claude-sonnet-4-5", usage: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 10 } } });
console.log(JSON.stringify({
  registrationThrew,
  dispatchThrew,
  turnEndSignaled: existsSync(process.env.TURNEND),
  turnEndRegistered: rejecting.has("turn_end"),
  stagingLeftover: existsSync(process.env.STAGING),
  record: JSON.parse(readFileSync(process.env.RECORD, "utf8")),
}));
JS
  ) || fail "passive Pi extension fixture failed"
  json_assert "$out" 'value["registrationThrew"] is False and value["turnEndRegistered"] is True'
  json_assert "$out" 'value["turnEndSignaled"] is True'
  json_assert "$out" 'value["dispatchThrew"] is False'
  json_assert "$out" 'value["stagingLeftover"] is False'
  json_assert "$out" 'value["record"]["tokens"]["total"] == 10 and value["record"]["status"] == "partial"'
  pass "Pi turn-end signaling survives a rejected telemetry registration, malformed payloads, and staging leftovers"
}

make_fake_claude() { # <dir>
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "auth status" ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro","email":"PRIVATE_EMAIL@example.invalid"}'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/claude"
}

test_claude_loopback_allowlist_dedupe_and_cleanup() {
  local root state tasktmp fakebin endpoint token out control_pid marker generation
  root="$TMP_ROOT/claude"
  state="$root/state"
  tasktmp="$root/tasktmp"
  fakebin="$root/fakebin"
  mkdir -p "$state" "$tasktmp"
  make_fake_claude "$fakebin"
  make_meta "$state" claude-x1 claude
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" claude-x1 claude) || fail "Claude telemetry init failed"
  PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$state" "$CLAUDE" self-test \
    || fail "Claude privacy self-test failed"
  PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$state" "$CLAUDE" \
    start claude-x1 "$tasktmp/telemetry.env" || fail "Claude collector failed to start"
  [ "$(file_mode "$tasktmp/telemetry.env")" = 600 ] \
    || fail "Claude launch environment is not owner-only"
  assert_grep "OTEL_LOG_USER_PROMPTS='0'" "$tasktmp/telemetry.env" "prompt logging is not pinned off"
  assert_grep "OTEL_LOG_ASSISTANT_RESPONSES='0'" "$tasktmp/telemetry.env" "response logging is not pinned off"
  assert_grep "OTEL_LOG_TOOL_DETAILS='0'" "$tasktmp/telemetry.env" "tool logging is not pinned off"
  assert_grep "OTEL_LOG_RAW_API_BODIES='0'" "$tasktmp/telemetry.env" "raw body logging is not pinned off"

  set -a
  # shellcheck disable=SC1090,SC1091 # Generated owner-only fixture environment.
  . "$tasktmp/telemetry.env"
  set +a
  endpoint=$OTEL_EXPORTER_OTLP_ENDPOINT
  token=${OTEL_EXPORTER_OTLP_HEADERS#*=}
  case "$endpoint" in http://127.0.0.1:*) : ;; *) fail "collector did not bind loopback" ;; esac

  ENDPOINT="$endpoint" TOKEN="$token" python3 - <<'PY'
import http.client, json, os, urllib.error, urllib.request

def row(sequence, model, query_source, values):
    attrs = {
        "event.name": "claude_code.api_request",
        "event.sequence": sequence,
        "session.id": "PRIVATE_SESSION_ID",
        "model": model,
        "query_source": query_source,
        "input_tokens": values[0],
        "output_tokens": values[1],
        "cache_read_tokens": values[2],
        "cache_creation_tokens": values[3],
        "prompt": "PRIVATE_PROMPT_TEXT",
        "response": "PRIVATE_RESPONSE_TEXT",
        "account.uuid": "PRIVATE_ACCOUNT_UUID",
        "request.id": "PRIVATE_REQUEST_ID",
        "tool.parameters": "rm -rf PRIVATE_TOOL_ARGUMENT",
    }
    return {"attributes": [
        {"key": key, "value": ({"intValue": str(value)} if isinstance(value, int) else {"stringValue": value})}
        for key, value in attrs.items()
    ]}

def post(rows, token=os.environ["TOKEN"]):
    payload = {"resourceLogs": [{"scopeLogs": [{"logRecords": rows}]}]}
    request = urllib.request.Request(
        os.environ["ENDPOINT"] + "/v1/logs",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "x-firstmate-telemetry-token": token},
        method="POST",
    )
    return urllib.request.urlopen(request, timeout=2).status

main = row("1", "claude-sonnet-4-5", "main", (1, 2, 3, 4))
assert post([main, main]) == 200
assert post([row("2", "claude-aux", "subagent", (5, 6, 7, 8))]) == 200
try:
    post([main], "wrong")
    raise AssertionError("wrong token accepted")
except urllib.error.HTTPError as error:
    assert error.code == 403
try:
    urllib.request.urlopen(os.environ["ENDPOINT"] + "/", timeout=2)
    raise AssertionError("collector exposed GET route")
except urllib.error.HTTPError as error:
    assert error.code == 404
host_port = os.environ["ENDPOINT"].removeprefix("http://").split(":", 1)
connection = http.client.HTTPConnection(host_port[0], int(host_port[1]), timeout=2)
connection.putrequest("POST", "/v1/logs")
connection.putheader("Content-Type", "application/json")
connection.putheader("x-firstmate-telemetry-token", os.environ["TOKEN"])
connection.putheader("Content-Length", str(64 * 1024 + 1))
connection.endheaders()
assert connection.getresponse().status == 413
connection.close()
PY

  printf '%s' '{"model":{"id":"claude-opus-4"}}' \
    | FM_STATE_OVERRIDE="$state" "$CLAUDE" status claude-x1 "$generation"
  assert_present "$state/.claude-x1.claude-live" "Claude worker liveness was never recorded"
  out=$(FM_STATE_OVERRIDE="$state" "$SNAPSHOT" --json) || fail "Claude worker snapshot failed"
  json_assert "$out" 'value["workers"][0]["model"] == {"provider":"anthropic","id":"claude-opus-4"}'
  json_assert "$out" 'value["workers"][0]["tokens"] == {"input":6,"output":8,"cacheRead":10,"cacheWrite":12,"reasoningOutput":None,"total":36,"totalSemantics":"sum_of_disjoint_components"}'
  for marker in PRIVATE_EMAIL PRIVATE_SESSION PRIVATE_PROMPT PRIVATE_RESPONSE PRIVATE_ACCOUNT PRIVATE_REQUEST PRIVATE_TOOL; do
    assert_not_contains "$out" "$marker" "Claude projection retained raw or identity field $marker"
    assert_no_grep "$marker" "$state/claude-x1.telemetry.json" "Claude summary persisted $marker"
  done
  control_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$state/claude-x1.claude-telemetry.json")
  FM_STATE_OVERRIDE="$state" "$CLAUDE" stop claude-x1
  [ ! -e "$state/claude-x1.telemetry.json" ] || fail "Claude stop retained telemetry record"
  [ ! -e "$state/claude-x1.claude-telemetry.json" ] || fail "Claude stop retained collector control"
  [ ! -e "$state/.claude-x1.claude-live" ] || fail "Claude stop retained the worker liveness marker"
  sleep 0.1
  if kill -0 "$control_pid" 2>/dev/null; then
    fail "Claude stop did not retire its task-scoped collector"
  fi
  pass "Claude collector is loopback-only, privacy-pinned, deduplicated, allowlisted, and task-scoped"
}

test_bounded_budgets_survive_slow_sources_and_lingering_pipes() {
  local state out
  state="$TMP_ROOT/budgets/state"
  mkdir -p "$state"
  make_meta "$state" slow-x1 pi
  FM_STATE_OVERRIDE="$state" "$INIT" slow-x1 pi >/dev/null || fail "budget fixture init failed"
  out=$(FM_TELEMETRY_STATE="$state" FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" python3 - <<'PY'
import importlib.util, json, os, time

spec = importlib.util.spec_from_file_location("fm_telemetry", os.environ["FM_TELEMETRY_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def slow_read(*_args, **_kwargs):
    time.sleep(30)
    return {}

module.read_secure_json = slow_read
started = time.monotonic()
snapshot = module.snapshot_worker_bounded(module.state_root(os.environ["FM_TELEMETRY_STATE"]))
result = {
    "snapshotElapsed": time.monotonic() - started,
    "workers": snapshot["workers"],
    "warnings": snapshot["warnings"],
}

started = time.monotonic()
returncode, output, reason = module.run_bounded_command(
    ["/bin/sh", "-c", "sleep 30 & printf ok"], dict(os.environ), 2, 16 * 1024
)
result["commandElapsed"] = time.monotonic() - started
result["returncode"] = returncode
result["output"] = None if output is None else output.decode()
result["reason"] = reason
print(json.dumps(result))
PY
  ) || fail "bounded budget probe failed"
  json_assert "$out" 'value["snapshotElapsed"] < 10'
  json_assert "$out" 'value["workers"] == [] and value["warnings"] == ["source_error"]'
  json_assert "$out" 'value["commandElapsed"] < 2'
  json_assert "$out" 'value["output"] == "ok" and value["reason"] is None and value["returncode"] == 0'
  pass "snapshot deadline is never absorbed by a projection handler and a bounded command never waits on an inherited pipe"
}

test_claude_usage_gap_downgrades_coverage_permanently() {
  local state dropped_generation overflow_generation out
  state="$TMP_ROOT/coverage/state"
  mkdir -p "$state"
  make_meta "$state" dropped-x1 claude
  make_meta "$state" overflow-x2 claude
  dropped_generation=$(FM_STATE_OVERRIDE="$state" "$INIT" dropped-x1 claude) \
    || fail "dropped-usage fixture init failed"
  overflow_generation=$(FM_STATE_OVERRIDE="$state" "$INIT" overflow-x2 claude) \
    || fail "overflow fixture init failed"
  out=$(FM_TELEMETRY_STATE="$state" FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" \
    FM_TELEMETRY_DROPPED_GENERATION="$dropped_generation" \
    FM_TELEMETRY_OVERFLOW_GENERATION="$overflow_generation" python3 - <<'PY'
import importlib.util, json, os

spec = importlib.util.spec_from_file_location("fm_telemetry", os.environ["FM_TELEMETRY_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = module.state_root(os.environ["FM_TELEMETRY_STATE"])

def usage(values):
    return dict(zip(("input", "output", "cacheRead", "cacheWrite"), values))

def valid(values):
    return {"usage": usage(values), "querySource": "main", "model": "claude-sonnet-4-5"}

def state(task_id):
    record = module.load_current_record(root, task_id)
    return {"status": record["status"], "coverage": record["coverage"], "tokens": record["tokens"]}

dropped = module.UsageCoverage()
generation = os.environ["FM_TELEMETRY_DROPPED_GENERATION"]
module.update_claude_usage(root, "dropped-x1", generation, "anthropic", valid((1, 2, 3, 4)), dropped)
result = {"counted": state("dropped-x1")}
module.update_claude_usage(root, "dropped-x1", generation, "anthropic", {"invalid": True}, dropped)
result["afterDrop"] = state("dropped-x1")
module.update_claude_usage(root, "dropped-x1", generation, "anthropic", valid((1, 1, 1, 1)), dropped)
result["afterRecovery"] = state("dropped-x1")

overflow = module.UsageCoverage()
half = module.MAX_SAFE_INTEGER // 2 + 1
module.update_claude_usage(
    root,
    "overflow-x2",
    os.environ["FM_TELEMETRY_OVERFLOW_GENERATION"],
    "anthropic",
    valid((half, half, 0, 0)),
    overflow,
)
result["afterOverflow"] = state("overflow-x2")
result["overflowDropped"] = not overflow.complete()
print(json.dumps(result))
PY
  ) || fail "Claude usage coverage probe failed"
  json_assert "$out" 'value["counted"]["status"] == "fresh" and value["counted"]["coverage"] == "full_worker"'
  json_assert "$out" 'value["counted"]["tokens"]["total"] == 10'
  json_assert "$out" 'value["afterDrop"]["status"] == "partial" and value["afterDrop"]["coverage"] == "since_observed"'
  json_assert "$out" 'value["afterRecovery"]["status"] == "partial" and value["afterRecovery"]["coverage"] == "since_observed"'
  json_assert "$out" 'value["afterRecovery"]["tokens"]["total"] == 14'
  json_assert "$out" 'value["afterOverflow"]["status"] == "partial" and value["afterOverflow"]["coverage"] == "since_observed"'
  json_assert "$out" 'value["afterOverflow"]["tokens"]["total"] is None and value["overflowDropped"] is True'
  pass "Claude uncounted usage downgrades coverage once and never restores full_worker"
}

test_claude_status_line_skips_redundant_record_writes() {
  local state record generation first second third fourth out
  state="$TMP_ROOT/statusline/state"
  mkdir -p "$state"
  record="$state/statusline-x1.telemetry.json"
  make_meta "$state" statusline-x1 claude
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" statusline-x1 claude) \
    || fail "status-line fixture init failed"
  printf '%s' '{"model":{"id":"claude-sonnet-4-5"}}' \
    | FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=1785542400 \
      FM_STATE_OVERRIDE="$state" "$CLAUDE" status statusline-x1 "$generation"
  first=$(file_inode "$record")
  printf '%s' '{"version":"2.1.221","model":{"id":"claude-sonnet-4-5"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785559400}}}' \
    | FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=1785542400 \
      FM_STATE_OVERRIDE="$state" "$CLAUDE" status statusline-x1 "$generation"
  second=$(file_inode "$record")
  [ "$first" = "$second" ] || fail "an unchanged status-line render rewrote the telemetry record"
  assert_present "$state/.claude-plan-usage-cache.json" \
    "an unchanged model prevented the status-line plan cache write"
  [ "$(file_mode "$state/.claude-plan-usage-cache.json")" = 600 ] \
    || fail "status-line plan cache is not owner-only"
  printf '%s' '{"model":{"id":"claude-opus-4"}}' \
    | FM_STATE_OVERRIDE="$state" "$CLAUDE" status statusline-x1 "$generation"
  third=$(file_inode "$record")
  [ "$second" != "$third" ] || fail "a changed status-line model did not update the telemetry record"
  printf '%s' '{"model":{"id":"claude-haiku-4-5"}}' \
    | FM_STATE_OVERRIDE="$state" "$CLAUDE" status statusline-x1 00000000000000000000000000000000
  printf '%s' '{"model":{"id":"claude-haiku-4-5"}}' \
    | FM_STATE_OVERRIDE="$state" "$CLAUDE" status ../statusline-x1 "$generation"
  fourth=$(file_inode "$record")
  [ "$third" = "$fourth" ] || fail "a foreign generation or task id updated the telemetry record"
  [ ! -e "$state/../.statusline-x1.telemetry.lock" ] \
    || fail "an unvalidated status-line task id created a lock outside the state root"
  out=$(FM_STATE_OVERRIDE="$state" "$SNAPSHOT" --json) || fail "status-line worker snapshot failed"
  json_assert "$out" 'value["workers"][0]["model"] == {"provider":None,"id":"claude-opus-4"}'
  pass "status-line renders independently update generation-bound model and plan projections"
}

test_claude_freshness_follows_worker_liveness() {
  local state generation out
  state="$TMP_ROOT/liveness/state"
  mkdir -p "$state"
  make_meta "$state" live-x1 claude
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" live-x1 claude) || fail "liveness fixture init failed"
  out=$(FM_TELEMETRY_STATE="$state" FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" \
    FM_TELEMETRY_GENERATION="$generation" python3 - <<'PY'
import importlib.util, json, os, time

spec = importlib.util.spec_from_file_location("fm_telemetry", os.environ["FM_TELEMETRY_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = module.state_root(os.environ["FM_TELEMETRY_STATE"])
generation = os.environ["FM_TELEMETRY_GENERATION"]
usage = {"usage": dict(zip(("input", "output", "cacheRead", "cacheWrite"), (1, 2, 3, 4))),
         "querySource": "main", "model": "claude-sonnet-4-5"}
module.update_claude_usage(root, "live-x1", generation, "anthropic", usage, module.UsageCoverage())
result = {"beforeAnyProof": module.heartbeat_tick(root, "live-x1", generation)}
started = module.load_current_record(root, "live-x1")["observedAt"]

module.note_worker_liveness(root, "live-x1")
live = module.liveness_path(root, "live-x1")
result["mode"] = oct(live.stat().st_mode & 0o777)
time.sleep(0.02)
result["whileRunning"] = module.heartbeat_tick(root, "live-x1", generation)
result["advanced"] = module.load_current_record(root, "live-x1")["observedAt"] != started
running = module.load_current_record(root, "live-x1")["observedAt"]

exited = time.time() - module.WORKER_LIVENESS_WINDOW - 5
os.utime(live, (exited, exited))
result["afterExit"] = module.heartbeat_tick(root, "live-x1", generation)
result["frozen"] = module.load_current_record(root, "live-x1")["observedAt"] == running
print(json.dumps(result))
PY
  ) || fail "Claude liveness probe failed"
  json_assert "$out" 'value["beforeAnyProof"] is False'
  json_assert "$out" 'value["whileRunning"] is True and value["advanced"] is True'
  json_assert "$out" 'value["afterExit"] is False and value["frozen"] is True'
  json_assert "$out" 'value["mode"] == "0o600"'
  out=$(FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=4102444800 \
    FM_STATE_OVERRIDE="$state" "$SNAPSHOT" --json) || fail "liveness worker snapshot failed"
  json_assert "$out" 'value["workers"][0]["status"] == "stale"'
  pass "Claude freshness tracks observed worker activity and ages to stale once that activity stops"
}

test_claude_start_leaves_no_orphan_collector() {
  local root state fakebin out
  root="$TMP_ROOT/claude-orphan"
  state="$root/state"
  fakebin="$root/fakebin"
  mkdir -p "$state"
  make_fake_claude "$fakebin"
  make_meta "$state" orphan-x1 claude
  FM_STATE_OVERRIDE="$state" "$INIT" orphan-x1 claude >/dev/null || fail "orphan fixture init failed"
  if PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$state" "$CLAUDE" \
       start orphan-x1 "$root/missing-dir/telemetry.env"; then
    fail "Claude start reported success for an unpublishable launch environment"
  fi
  [ ! -e "$state/orphan-x1.claude-telemetry.json" ] \
    || fail "a failed Claude start retained its collector control record"
  sleep 0.2
  # shellcheck disable=SC2009 # the full command line is both the match and the failure evidence, and a pgrep pattern would have to re-escape the state path as a regex
  out=$(ps -Ao command= | grep -F "claude-collector $state orphan-x1" | grep -v grep || true)
  [ -z "$out" ] || fail "a failed Claude start left an orphan collector running"$'\n'"$out"
  pass "a failed Claude start publishes no environment and leaves no orphan collector"
}

test_every_task_scoped_file_is_in_the_fixed_cleanup_lists() {
  local state generation plugin missing status
  state="$TMP_ROOT/cleanup-names/state"
  mkdir -p "$state"
  make_meta "$state" cleanup-x1 pi
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" cleanup-x1 pi) || fail "cleanup-name fixture init failed"
  plugin="$state/cleanup-x1.pi-ext.ts"
  FM_STATE_OVERRIDE="$state" "$PI_GENERATOR" \
    cleanup-x1 "$generation" "$state/cleanup-x1.turn-ended" "$state/cleanup-x1.telemetry.json" "$plugin" \
    || fail "cleanup-name extension generation failed"
  missing=$(FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" PLUGIN="$plugin" \
    TEARDOWN="$ROOT/bin/fm-teardown.sh" ROLLBACK="$ROOT/bin/fm-spawn-rollback-lib.sh" python3 - <<'PY'
import os, re
from pathlib import Path

module = Path(os.environ["FM_TELEMETRY_MODULE"]).read_text(encoding="utf-8")
names = {name for name in re.findall(r'root / f"([^"]*\{task_id\}[^"]*)"', module)}
staging = re.search(r'const STAGING = "([^"]+)"', Path(os.environ["PLUGIN"]).read_text(encoding="utf-8"))
if staging is None:
    raise SystemExit("generated Pi extension exposes no staging path")
names.add(Path(staging.group(1)).name.replace("cleanup-x1", "{task_id}"))

targets = [
    (os.environ["TEARDOWN"], "$STATE", "$ID"),
    (os.environ["TEARDOWN"], "$sub_state", "$child_id"),
    (os.environ["ROLLBACK"], "$state", "$id"),
]
report = []
for path, root, variable in targets:
    source = Path(path).read_text(encoding="utf-8")
    for name in sorted(names):
        token = f'"{root}/{name.replace("{task_id}", variable)}"'
        if token not in source:
            report.append(f"{Path(path).name} {token}")
print("\n".join(report))
PY
  ) || fail "cleanup-name derivation failed"
  [ -z "$missing" ] \
    || fail "task-scoped telemetry files are absent from a fixed cleanup list"$'\n'"$missing"
  python3 "$ROOT/bin/telemetry/fm-telemetry.py" cleanup "$state" cleanup-x1 >/dev/null 2>&1
  status=$?
  [ "$status" = 2 ] || fail "the retired duplicate cleanup action still dispatches (exit $status)"
  [ -e "$state/cleanup-x1.telemetry.json" ] \
    || fail "the retired duplicate cleanup action still removed the telemetry record"
  pass "every task-scoped telemetry file is removed by name by each fixed cleanup list"
}

test_claude_stop_refuses_unrelated_process() {
  local state unrelated process_start
  state="$TMP_ROOT/claude-unrelated/state"
  mkdir -p "$state"
  make_meta "$state" claude-safe-x2 claude
  FM_STATE_OVERRIDE="$state" "$INIT" claude-safe-x2 claude >/dev/null \
    || fail "unrelated-process telemetry init failed"
  sleep 30 &
  unrelated=$!
  process_start=$(ps -ww -p "$unrelated" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  python3 - "$state/claude-safe-x2.claude-telemetry.json" "$unrelated" "$process_start" <<'PY'
import json, os, sys
path, pid, started = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "schema": "fm-claude-telemetry-collector.v1",
        "taskId": "claude-safe-x2",
        "pid": int(pid),
        "processStart": started,
    }, stream)
os.chmod(path, 0o600)
PY
  FM_STATE_OVERRIDE="$state" "$CLAUDE" stop claude-safe-x2
  kill -0 "$unrelated" 2>/dev/null || fail "Claude stop signaled an unrelated process"
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  pass "Claude stop refuses an unrelated process even when a private control record names its PID"
}

test_a_finished_suite_leaves_no_collector_behind() {
  local root fakebin child out pid tmproot
  root="$TMP_ROOT/suite-cleanup"
  fakebin="$root/fakebin"
  child="$root/child-suite.sh"
  mkdir -p "$root"
  make_fake_claude "$fakebin"

  # A behavior suite that starts a task-scoped collector and then ends: the
  # collector only exits on an explicit stop, so tests/lib.sh must retire it and
  # remove the registered temp root when the suite process exits.
  cat > "$child" <<CHILD
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
tmproot=\$(fm_test_tmproot fm-suite-cleanup-probe)
mkdir -p "\$tmproot/state" "\$tmproot/tasktmp"
printf 'harness=claude\nkind=ship\n' > "\$tmproot/state/childz1.meta"
FM_STATE_OVERRIDE="\$tmproot/state" "$ROOT/bin/fm-worker-telemetry-init.sh" childz1 claude >/dev/null || exit 1
PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="\$tmproot/state" \\
  "$ROOT/bin/fm-claude-telemetry.sh" start childz1 "\$tmproot/tasktmp/telemetry.env" || exit 1
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' \\
  "\$tmproot/state/childz1.claude-telemetry.json" || exit 1
printf '%s\n' "\$tmproot"
CHILD
  chmod +x "$child"

  out=$(bash "$child") || fail "suite-cleanup probe failed to start a collector"
  pid=$(printf '%s\n' "$out" | sed -n 1p)
  tmproot=$(printf '%s\n' "$out" | sed -n 2p)
  case "$pid" in ''|*[!0-9]*) fail "suite-cleanup probe did not report a collector pid" ;; esac

  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    fail "a finished suite left its task-scoped collector running"
  fi
  [ ! -d "$tmproot" ] || fail "a finished suite left its registered temp root behind"
  pass "a finished suite retires its task-scoped collector and removes its temp root"
}

wait_for_exit() { # <pid> <deciseconds>
  local pid=$1 limit=$2 waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

collector_pid() { # <control-record>
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$1"
}

test_status_line_render_loads_no_collector_modules() {
  local state generation out
  state="$TMP_ROOT/status-imports/state"
  mkdir -p "$state"
  make_meta "$state" imports-x1 claude
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" imports-x1 claude) \
    || fail "status-import fixture init failed"
  # The status line re-renders for the whole life of every Claude worker, so the
  # collector, subprocess, and nonce modules must never load on that path.
  out=$(FM_TELEMETRY_STATE="$state" FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" \
    FM_TELEMETRY_GENERATION="$generation" python3 - <<'PY'
import importlib.util, json, os, sys

heavy = ("http.server", "hashlib", "selectors", "shlex", "socket", "subprocess", "tempfile", "secrets")
before = sorted(name for name in heavy if name in sys.modules)
spec = importlib.util.spec_from_file_location("fm_telemetry", os.environ["FM_TELEMETRY_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = module.state_root(os.environ["FM_TELEMETRY_STATE"])
module.claude_status_update(
    root,
    "imports-x1",
    os.environ["FM_TELEMETRY_GENERATION"],
    b'{"model":{"id":"claude-sonnet-4-5"}}',
)
print(json.dumps({
    "preloaded": before,
    "loaded": sorted(name for name in heavy if name in sys.modules),
    "model": module.load_current_record(root, "imports-x1")["model"]["id"],
}))
PY
  ) || fail "status-line import probe failed"
  json_assert "$out" 'value["preloaded"] == []'
  json_assert "$out" 'value["loaded"] == []'
  json_assert "$out" 'value["model"] == "claude-sonnet-4-5"'
  pass "a status-line render updates the record without loading any collector module"
}

test_writes_stage_at_one_fixed_name_per_file() {
  local state generation name leftovers
  state="$TMP_ROOT/staging/state"
  mkdir -p "$state"
  make_meta "$state" staging-x1 claude
  generation=$(FM_STATE_OVERRIDE="$state" "$INIT" staging-x1 claude) \
    || fail "staging fixture init failed"
  assert_no_grep 'mkstemp' "$ROOT/bin/telemetry/fm-telemetry.py" \
    "telemetry writes still stage at a random name no cleanup list can match"
  name=$(FM_TELEMETRY_STATE="$state" FM_TELEMETRY_MODULE="$ROOT/bin/telemetry/fm-telemetry.py" python3 - <<'PY'
import importlib.util, os
from pathlib import Path

spec = importlib.util.spec_from_file_location("fm_telemetry", os.environ["FM_TELEMETRY_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = module.state_root(os.environ["FM_TELEMETRY_STATE"])
print(module.staging_path(root / "staging-x1.telemetry.json").name)
PY
  ) || fail "staging-name probe failed"
  [ "$name" = ".staging-x1.telemetry.json.tmp" ] \
    || fail "the record staging name is not the fixed cleanup name (got '$name')"
  printf '%s' '{"model":{"id":"claude-sonnet-4-5"}}' \
    | FM_STATE_OVERRIDE="$state" "$CLAUDE" status staging-x1 "$generation"
  leftovers=$(find "$state" -maxdepth 1 -name '.staging-x1.telemetry.json.*' | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || fail "a completed record write left staging files behind"

  # An interrupted write leaves exactly these names, and task cleanup removes
  # each one without ever globbing the state directory.
  : > "$state/.staging-x1.telemetry.json.tmp"
  : > "$state/.staging-x1.claude-telemetry.json.tmp"
  : > "$state/.staging-x1.claude-ready.json.tmp"
  : > "$state/.staging-x1.claude-bootstrap.json.tmp"
  FM_STATE_OVERRIDE="$state" "$CLAUDE" stop staging-x1
  assert_absent "$state/.staging-x1.telemetry.json.tmp" "an interrupted record write outlived its task"
  assert_absent "$state/.staging-x1.claude-telemetry.json.tmp" "an interrupted control write outlived its task"
  assert_absent "$state/.staging-x1.claude-ready.json.tmp" "an interrupted ready write outlived its task"
  assert_absent "$state/.staging-x1.claude-bootstrap.json.tmp" "an interrupted bootstrap write outlived its task"
  pass "every telemetry write stages at one fixed name that task cleanup removes"
}

test_collector_stop_survives_whitespace_paths() {
  local root state tasktmp fakebin pid
  root="$TMP_ROOT/claude whitespace"
  state="$root/state dir"
  tasktmp="$root/task tmp"
  fakebin="$root/fake bin"
  mkdir -p "$state" "$tasktmp"
  make_fake_claude "$fakebin"
  make_meta "$state" spaced-x1 claude
  FM_STATE_OVERRIDE="$state" "$INIT" spaced-x1 claude >/dev/null \
    || fail "whitespace-path fixture init failed"
  PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$state" "$CLAUDE" \
    start spaced-x1 "$tasktmp/telemetry.env" \
    || fail "the collector failed to start under a whitespace state root"
  pid=$(collector_pid "$state/spaced-x1.claude-telemetry.json") \
    || fail "the whitespace-path collector wrote no control record"
  # ps joins argv with plain spaces, so an argv-reconstructing identity check
  # mis-splits these paths and silently refuses to retire this task's collector.
  FM_STATE_OVERRIDE="$state" "$CLAUDE" stop spaced-x1
  if ! wait_for_exit "$pid" 30; then
    kill -9 "$pid" 2>/dev/null || true
    fail "a collector under a whitespace state root was never retired"
  fi
  assert_absent "$state/spaced-x1.claude-telemetry.json" \
    "the whitespace-path collector control record outlived its task"
  pass "collector stop retires its own collector even under whitespace paths"
}

test_collector_retires_itself_when_its_task_is_gone() {
  local root state tasktmp fakebin pid
  root="$TMP_ROOT/claude-selfexit"
  state="$root/state"
  tasktmp="$root/tasktmp"
  fakebin="$root/fakebin"
  mkdir -p "$state" "$tasktmp"
  make_fake_claude "$fakebin"

  # A cleanup that removed the record without signaling (a deleted state
  # directory) must not leave a loopback listener behind.
  make_meta "$state" selfexit-x1 claude
  FM_STATE_OVERRIDE="$state" "$INIT" selfexit-x1 claude >/dev/null \
    || fail "self-exit fixture init failed"
  PATH="$fakebin:$BASE_PATH" FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=1785542400 \
    FM_TELEMETRY_TEST_HEARTBEAT=0.05 FM_STATE_OVERRIDE="$state" "$CLAUDE" \
    start selfexit-x1 "$tasktmp/telemetry.env" || fail "self-exit collector failed to start"
  pid=$(collector_pid "$state/selfexit-x1.claude-telemetry.json") \
    || fail "the self-exit collector wrote no control record"
  rm -f "$state/selfexit-x1.telemetry.json"
  if ! wait_for_exit "$pid" 100; then
    kill -9 "$pid" 2>/dev/null || true
    fail "a collector whose own record was removed never retired itself"
  fi
  assert_absent "$state/selfexit-x1.claude-telemetry.json" \
    "a self-retired collector left a control record naming a dead process"

  # A spawn killed before it recorded the task leaves nothing that teardown can
  # find, so the collector bounds that case itself.
  make_meta "$state" selfexit-x2 claude
  FM_STATE_OVERRIDE="$state" "$INIT" selfexit-x2 claude >/dev/null \
    || fail "unclaimed-task fixture init failed"
  PATH="$fakebin:$BASE_PATH" FM_TELEMETRY_TEST_MODE=1 FM_TELEMETRY_TEST_NOW=1785542400 \
    FM_TELEMETRY_TEST_HEARTBEAT=0.05 FM_STATE_OVERRIDE="$state" "$CLAUDE" \
    start selfexit-x2 "$tasktmp/telemetry2.env" || fail "unclaimed-task collector failed to start"
  pid=$(collector_pid "$state/selfexit-x2.claude-telemetry.json") \
    || fail "the unclaimed-task collector wrote no control record"
  rm -f "$state/selfexit-x2.meta"
  if ! wait_for_exit "$pid" 100; then
    kill -9 "$pid" 2>/dev/null || true
    fail "a collector for a task no spawn ever recorded never retired itself"
  fi
  [ -e "$state/selfexit-x2.telemetry.json" ] \
    || fail "a self-retiring collector removed the telemetry record it never owned"
  pass "a collector retires itself once its task record or meta is gone"
}

test_a_suite_with_its_own_trap_leaves_no_registry_file() {
  local root child registry
  root="$TMP_ROOT/registry"
  child="$root/child-suite.sh"
  mkdir -p "$root"

  # Most suites replace the library's EXIT trap with their own, so the shared
  # cleanup registry must not exist until a temp root is actually registered.
  cat > "$child" <<CHILD
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
trap 'exit 0' EXIT
printf '%s\n' "\$FM_TEST_CLEANUP_REGISTRY"
CHILD
  chmod +x "$child"
  registry=$(bash "$child") || fail "cleanup-registry probe failed"
  [ -n "$registry" ] || fail "tests/lib.sh exposes no cleanup registry path"
  assert_absent "$registry" \
    "a suite that registered no temp root still left a cleanup registry file in TMPDIR"
  pass "sourcing tests/lib.sh creates no registry file until a temp root is registered"
}

test_snapshot_bounds_and_hostile_files
test_snapshot_status_timestamp_and_integer_controls
test_pi_projection_exact_usage_and_passive_failure
test_pi_turn_end_survives_telemetry_registration_and_payload_failures
test_claude_loopback_allowlist_dedupe_and_cleanup
test_bounded_budgets_survive_slow_sources_and_lingering_pipes
test_claude_usage_gap_downgrades_coverage_permanently
test_claude_status_line_skips_redundant_record_writes
test_claude_freshness_follows_worker_liveness
test_claude_start_leaves_no_orphan_collector
test_status_line_render_loads_no_collector_modules
test_writes_stage_at_one_fixed_name_per_file
test_collector_stop_survives_whitespace_paths
test_collector_retires_itself_when_its_task_is_gone
test_every_task_scoped_file_is_in_the_fixed_cleanup_lists
test_claude_stop_refuses_unrelated_process
test_a_finished_suite_leaves_no_collector_behind
test_a_suite_with_its_own_trap_leaves_no_registry_file
