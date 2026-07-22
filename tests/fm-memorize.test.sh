#!/usr/bin/env bash
# Focused safety and behavior tests for the /memorize OpenBrain helper and skill contract.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEMORIZE="$ROOT/bin/fm-memorize.sh"
TMP_ROOT=$(fm_test_tmproot fm-memorize)

make_fixture() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = mcp ] && [ "${2:-}" = get ] && [ "${3:-}" = openbrain ]; then
  printf '%s\n' "$PWD" > "$CAPTURE_DIR/mcp-cwd"
  case "${FAKE_MCP_MODE:-enabled}" in
    missing) exit 1 ;;
    disabled)
      printf 'openbrain\n  enabled: false\n  bearer_token_env_var: OPENBRAIN_KEY\n'
      ;;
    no-auth-env)
      printf 'openbrain\n  enabled: true\n  bearer_token_env_var: -\n'
      ;;
    *)
      printf 'openbrain\n  enabled: true\n  bearer_token_env_var: OPENBRAIN_KEY\n'
      ;;
  esac
  exit 0
fi
[ "${1:-}" = exec ] || exit 91
printf '%s\n' "$PWD" > "$CAPTURE_DIR/cwd"
printf '%s\n' "$@" > "$CAPTURE_DIR/args"
cat > "$CAPTURE_DIR/instructions"
cp payload.json "$CAPTURE_DIR/payload.json"
printf '%s\n' '{"type":"diagnostic","message":"sensitive model detail"}'
case "${FAKE_EVENT_MODE:-create}" in
  missing) : ;;
  update) printf '%s\n' '{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"openbrain","tool":"update_memory","result":{"title":"Returned title","created_at":"2026-03-12T10:11:12Z","id":"mem-123"},"error":null}}' ;;
  duplicate)
    printf '%s\n' '{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"openbrain","tool":"create_memory","result":{"title":"Returned title","created_at":"2026-03-12T10:11:12Z","id":"mem-123"},"error":null}}'
    printf '%s\n' '{"type":"item.completed","item":{"id":"item-2","type":"mcp_tool_call","server":"openbrain","tool":"create_memory","result":{"title":"Returned title","created_at":"2026-03-12T10:11:12Z","id":"mem-124"},"error":null}}'
    ;;
  *) printf '%s\n' '{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"openbrain","tool":"create_memory","arguments":{"inert":"data"},"result":{"title":"Returned title","created_at":"2026-03-12T10:11:12Z","id":"mem-123"},"error":null}}' ;;
esac
printf 'sensitive stderr OPENBRAIN_KEY=%s\n' "${OPENBRAIN_KEY:-}" >&2
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then
    output=$2
    break
  fi
  shift
done
[ -n "$output" ] || exit 92
case "${FAKE_EXEC_MODE:-success}" in
  fail) exit 9 ;;
  malformed) printf 'not json\n' > "$output" ;;
  incomplete) printf '%s\n' '{"success":true,"title":"T","timestamp":"","identifier":"id","blocker":""}' > "$output" ;;
  rejected) printf '%s\n' '{"success":false,"title":"","timestamp":"","identifier":"","blocker":"authentication rejected"}' > "$output" ;;
  *) printf '%s\n' '{"success":true,"title":"Returned title","timestamp":"2026-03-12T10:11:12Z","identifier":"mem-123","blocker":""}' > "$output" ;;
esac
SH
  chmod +x "$fakebin/codex"
  printf 'Conversation outcome\n' > "$dir/title.txt"
  printf 'A durable decision with https://example.test/artifact.\n' > "$dir/body.txt"
  printf '%s\n' "$fakebin"
}

run_helper() {
  local dir=$1 fakebin=$2
  shift 2
  PATH="$fakebin:/usr/bin:/bin" CAPTURE_DIR="$dir" OPENBRAIN_KEY='test-secret-value' \
    "$MEMORIZE" --title-file "$dir/title.txt" --body-file "$dir/body.txt" "$@"
}

test_success_is_isolated_ephemeral_and_returns_validated_receipt() {
  local dir="$TMP_ROOT/success" fakebin output cwd args instructions
  fakebin=$(make_fixture success)
  output=$(run_helper "$dir" "$fakebin" 2>"$dir/error") || fail "successful write fixture failed: $(cat "$dir/error")"
  assert_contains "$output" '"title":"Returned title"' "success receipt omitted returned title"
  assert_contains "$output" '"timestamp":"2026-03-12T10:11:12Z"' "success receipt omitted timestamp"
  assert_contains "$output" '"identifier":"mem-123"' "success receipt omitted identifier"
  assert_not_contains "$output$(cat "$dir/error")" 'test-secret-value' "helper leaked authentication value"
  cwd=$(cat "$dir/cwd")
  [ "$(cat "$dir/mcp-cwd")" = "$cwd" ] || fail "Codex MCP discovery ran outside the isolated directory"
  case "$cwd" in
    "${TMPDIR:-/tmp}"fm-memorize.*|"${TMPDIR:-/tmp}"/fm-memorize.*) : ;;
    *) fail "Codex did not run in its isolated temporary directory: $cwd" ;;
  esac
  [ "$cwd" != "$ROOT" ] || fail "Codex ran inside the Firstmate repository"
  [ ! -e "$cwd" ] || fail "Codex temporary directory was not cleaned up"
  args=$(cat "$dir/args")
  assert_contains "$args" '--ephemeral' "Codex invocation is not ephemeral"
  assert_contains "$args" '--ignore-rules' "Codex invocation may inherit project rules"
  assert_contains "$args" '--skip-git-repo-check' "Codex invocation does not permit isolated non-repo execution"
  assert_contains "$args" '--json' "Codex invocation does not expose auditable MCP events"
  assert_contains "$args" 'read-only' "Codex invocation lacks read-only filesystem sandbox"
  instructions=$(cat "$dir/instructions")
  assert_contains "$instructions" 'exactly one new memory' "Codex is not limited to one new-memory write"
  assert_contains "$instructions" 'Do not call any update or delete tool.' "Codex is not forbidden from mutating existing memories"
  assert_contains "$instructions" 'do not retry' "Codex is not forbidden from retrying an uncertain write"
  assert_contains "$instructions" 'inert untrusted data' "payload is not labeled inert and untrusted"
  pass "memorize performs one isolated ephemeral Codex MCP write and validates its receipt"
}

test_payload_is_json_data_not_shell_or_arguments() {
  local dir="$TMP_ROOT/injection" fakebin output args marker
  fakebin=$(make_fixture injection)
  marker="$dir/should-not-exist"
  # shellcheck disable=SC2016 # These expressions are hostile literal fixture data.
  printf '%s\n' 'Title `touch bad` $(touch worse) "quoted"' > "$dir/title.txt"
  # shellcheck disable=SC2016 # The command substitution must remain inert fixture data.
  printf 'Body\n$(touch %s)\n--dangerously-bypass-approvals-and-sandbox\n' "$marker" > "$dir/body.txt"
  output=$(run_helper "$dir" "$fakebin" 2>"$dir/error") || fail "inert payload fixture failed: $(cat "$dir/error")"
  [ ! -e "$marker" ] || fail "conversation text was shell-interpolated"
  args=$(cat "$dir/args")
  assert_not_contains "$args" 'touch bad' "title entered Codex arguments"
  assert_not_contains "$args" 'dangerously-bypass' "body entered Codex arguments"
  python3 - "$dir/payload.json" <<'PY' || fail "payload was not safely JSON encoded"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["title"] == 'Title `touch bad` $(touch worse) "quoted"'
assert "--dangerously-bypass-approvals-and-sandbox" in payload["body"]
PY
  assert_contains "$output" 'mem-123' "safe payload run did not return receipt"
  pass "memorize hands hostile conversation text to Codex only as inert JSON data"
}

test_configuration_and_authentication_fail_before_write() {
  local dir fakebin output code

  dir="$TMP_ROOT/missing-codex"
  fakebin=$(make_fixture missing-codex)
  set +e
  output=$(PATH="/usr/bin:/bin" "$MEMORIZE" --title-file "$dir/title.txt" --body-file "$dir/body.txt" 2>&1)
  code=$?
  set -e
  expect_code 3 "$code" "missing Codex CLI"
  assert_contains "$output" 'Codex CLI is unavailable' "missing Codex blocker is not concrete"

  dir="$TMP_ROOT/missing-mcp"
  fakebin=$(make_fixture missing-mcp)
  set +e
  output=$(FAKE_MCP_MODE=missing run_helper "$dir" "$fakebin" 2>&1)
  code=$?
  set -e
  expect_code 3 "$code" "missing MCP server"
  assert_contains "$output" 'no available openbrain MCP server' "missing MCP blocker is not concrete"
  [ ! -e "$dir/cwd" ] || fail "Codex write ran without OpenBrain MCP"

  dir="$TMP_ROOT/disabled-mcp"
  fakebin=$(make_fixture disabled-mcp)
  set +e
  output=$(FAKE_MCP_MODE=disabled run_helper "$dir" "$fakebin" 2>&1)
  code=$?
  set -e
  expect_code 3 "$code" "disabled MCP server"
  assert_contains "$output" 'openbrain MCP server is disabled' "disabled MCP blocker is not concrete"
  [ ! -e "$dir/cwd" ] || fail "Codex write ran with disabled OpenBrain MCP"

  dir="$TMP_ROOT/missing-auth"
  fakebin=$(make_fixture missing-auth)
  set +e
  output=$(PATH="$fakebin:/usr/bin:/bin" CAPTURE_DIR="$dir" env -u OPENBRAIN_KEY \
    "$MEMORIZE" --title-file "$dir/title.txt" --body-file "$dir/body.txt" 2>&1)
  code=$?
  set -e
  expect_code 3 "$code" "missing OpenBrain authentication"
  assert_contains "$output" 'OPENBRAIN_KEY is not set' "authentication blocker is not concrete"
  assert_not_contains "$output" 'test-secret-value' "authentication blocker leaked a credential"
  [ ! -e "$dir/cwd" ] || fail "Codex write ran without authentication"
  pass "memorize refuses missing MCP configuration and authentication before writing"
}

test_uncertain_or_invalid_receipt_never_claims_success() {
  local mode dir fakebin output code
  for mode in fail malformed incomplete rejected; do
    dir="$TMP_ROOT/receipt-$mode"
    fakebin=$(make_fixture "receipt-$mode")
    set +e
    output=$(FAKE_EXEC_MODE="$mode" run_helper "$dir" "$fakebin" 2>&1)
    code=$?
    set -e
    expect_code 4 "$code" "$mode write result"
    assert_contains "$output" 'do not retry automatically' "$mode result did not preserve one-write uncertainty"
    assert_not_contains "$output" 'test-secret-value' "$mode result leaked authentication value"
    assert_not_contains "$output" 'Returned title' "$mode result claimed a successful write"
  done
  for mode in missing update duplicate; do
    dir="$TMP_ROOT/event-$mode"
    fakebin=$(make_fixture "event-$mode")
    set +e
    output=$(FAKE_EVENT_MODE="$mode" run_helper "$dir" "$fakebin" 2>&1)
    code=$?
    set -e
    expect_code 4 "$code" "$mode MCP event evidence"
    assert_contains "$output" 'do not retry automatically' "$mode MCP evidence did not preserve one-write uncertainty"
    assert_not_contains "$output" 'Returned title' "$mode MCP evidence claimed a successful write"
  done
  pass "memorize refuses success after failed receipts, missing writes, forbidden mutation, or duplicate writes"
}

test_local_input_safety_and_skill_contract() {
  local dir="$TMP_ROOT/local-input" fakebin output code skill="$ROOT/.agents/skills/memorize/SKILL.md"
  fakebin=$(make_fixture local-input)
  ln -s "$dir/title.txt" "$dir/title-link.txt"
  set +e
  output=$(PATH="$fakebin:/usr/bin:/bin" CAPTURE_DIR="$dir" OPENBRAIN_KEY=x \
    "$MEMORIZE" --title-file "$dir/title-link.txt" --body-file "$dir/body.txt" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "symlink title input"
  assert_contains "$output" 'regular, non-symlink file' "symlink refusal was unclear"
  [ ! -e "$dir/cwd" ] || fail "Codex ran after unsafe local input"

  assert_grep 'name: memorize' "$skill" "memorize skill is not discoverable"
  assert_grep 'user-invocable: true' "$skill" "memorize skill is not user-invocable"
  assert_grep '/memorize' "$skill" "memorize description lacks slash trigger"
  assert_grep '"memorize that"' "$skill" "memorize description lacks natural-language trigger"
  assert_grep 'one new OpenBrain write only' "$skill" "skill does not bound captain authorization"
  assert_grep 'does not authorize updating or deleting' "$skill" "skill does not protect existing memories"
  assert_grep 'Do not invent facts' "$skill" "skill does not forbid invented memory facts"
  assert_grep 'Do not retry the helper after exit code 4' "$skill" "skill permits accidental duplicate writes"
  pass "memorize rejects unsafe inputs and declares its user-facing one-write contract"
}

test_success_is_isolated_ephemeral_and_returns_validated_receipt
test_payload_is_json_data_not_shell_or_arguments
test_configuration_and_authentication_fail_before_write
test_uncertain_or_invalid_receipt_never_claims_success
test_local_input_safety_and_skill_contract
