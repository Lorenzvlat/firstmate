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
  JSON_INPUT=$1 ASSERTION=$2 python3 - <<'PY'
import json, os
value = json.loads(os.environ["JSON_INPUT"])
assert eval(os.environ["ASSERTION"], {"value": value})
PY
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
  [ "$(stat -f '%Lp' "$state/good-x1.telemetry.json" 2>/dev/null || stat -c '%a' "$state/good-x1.telemetry.json")" = 600 ] \
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
  [ "$(stat -f '%Lp' "$plugin" 2>/dev/null || stat -c '%a' "$plugin")" = 600 ] \
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
  local root state tasktmp fakebin endpoint token out control_pid marker
  root="$TMP_ROOT/claude"
  state="$root/state"
  tasktmp="$root/tasktmp"
  fakebin="$root/fakebin"
  mkdir -p "$state" "$tasktmp"
  make_fake_claude "$fakebin"
  make_meta "$state" claude-x1 claude
  FM_STATE_OVERRIDE="$state" "$INIT" claude-x1 claude >/dev/null || fail "Claude telemetry init failed"
  PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$state" "$CLAUDE" self-test \
    || fail "Claude privacy self-test failed"
  PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$state" "$CLAUDE" \
    start claude-x1 "$tasktmp/telemetry.env" || fail "Claude collector failed to start"
  [ "$(stat -f '%Lp' "$tasktmp/telemetry.env" 2>/dev/null || stat -c '%a' "$tasktmp/telemetry.env")" = 600 ] \
    || fail "Claude launch environment is not owner-only"
  assert_grep "OTEL_LOG_USER_PROMPTS='0'" "$tasktmp/telemetry.env" "prompt logging is not pinned off"
  assert_grep "OTEL_LOG_ASSISTANT_RESPONSES='0'" "$tasktmp/telemetry.env" "response logging is not pinned off"
  assert_grep "OTEL_LOG_TOOL_DETAILS='0'" "$tasktmp/telemetry.env" "tool logging is not pinned off"
  assert_grep "OTEL_LOG_RAW_API_BODIES='0'" "$tasktmp/telemetry.env" "raw body logging is not pinned off"

  set -a
  # shellcheck disable=SC1090 # Generated owner-only fixture environment.
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
    | FM_STATE_OVERRIDE="$state" "$CLAUDE" status claude-x1
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
  sleep 0.1
  if kill -0 "$control_pid" 2>/dev/null; then
    fail "Claude stop did not retire its task-scoped collector"
  fi
  pass "Claude collector is loopback-only, privacy-pinned, deduplicated, allowlisted, and task-scoped"
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

test_snapshot_bounds_and_hostile_files
test_snapshot_status_timestamp_and_integer_controls
test_pi_projection_exact_usage_and_passive_failure
test_claude_loopback_allowlist_dedupe_and_cleanup
test_claude_stop_refuses_unrelated_process
