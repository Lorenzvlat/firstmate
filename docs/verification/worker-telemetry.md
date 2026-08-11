# Worker telemetry verification

This page records dated evidence for the active transport and privacy claims owned by [worker-telemetry.md](../worker-telemetry.md).
It is evidence rather than a second copy of the contracts.

## 2026-08-01 installed versions

Command:

```sh
claude --version && codex --version && pi --version && python3 --version && node --version
```

Exact output:

```text
2.1.220 (Claude Code)
codex-cli 0.144.1
0.80.10
Python 3.13.14
v26.5.0
```

## Pi extension surface

The installed Pi 0.80.10 documentation defines `ctx.model`, `model_select`, finalized `message_end`, and assistant `usage.input`, `usage.output`, `usage.cacheRead`, `usage.cacheWrite`, and `usage.totalTokens`.
The implementation test drives only those fields through a generated extension and verifies model switching, exact zero preservation, cumulative source totals, owner-only atomic output, and independent turn-end signaling after a telemetry write failure.

Command:

```sh
bin/fm-test-run.sh tests/fm-worker-telemetry.test.sh
```

Exact focused result on 2026-08-11 after the passive-failure, activity-based freshness, generation, orphan-collector, and fixed-cleanup fixes:

```text
ok - worker snapshot bounds count, bytes, owner mode, symlinks, and generic warning enums
ok - worker snapshot distinguishes status/integer controls and projects only fixed selection rationale labels
ok - Pi projects exact resolved model and finalized token components without content access
ok - Pi turn-end signaling survives a rejected telemetry registration, malformed payloads, and staging leftovers
ok - Claude collector is loopback-only, privacy-pinned, deduplicated, allowlisted, and task-scoped
ok - snapshot deadline is never absorbed by a projection handler and a bounded command never waits on an inherited pipe
ok - Claude uncounted usage downgrades coverage once and never restores full_worker
ok - status-line renders update the record only for this task, generation, and a changed model
ok - Claude freshness tracks observed worker activity and ages to stale once that activity stops
ok - a failed Claude start publishes no environment and leaves no orphan collector
ok - every task-scoped telemetry file is removed by name by each fixed cleanup list
ok - Claude stop refuses an unrelated process even when a private control record names its PID
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

The bounded-budget fixture holds the snapshot's record reader for 30 seconds and confirms the 3-second deadline still returns the empty bounded projection, and it runs a bounded command whose exited child leaves a 30-second grandchild holding the stdout pipe, confirming the reader returns immediately instead of blocking past its budget.
The coverage fixture drops one admitted observation, then feeds a valid one, and confirms the record stays `partial`/`since_observed` while still summing the counted tokens.
The passive-failure fixture loads the generated extension under a Pi stub that throws for every event other than `turn_end`, confirms the export still loads and still signals turn end, dispatches empty and usage-free payloads without a throw, and confirms one pre-existing staging leftover is replaced rather than accumulated.
The freshness fixture confirms the collector heartbeat refuses to advance `observedAt` before any recorded worker activity and after activity older than the 120-second window, and that the record then projects as `stale`.
No claim is made here about Claude's idle status-line cadence, because that cadence was not observed on this installation; the contract therefore describes freshness in terms of observed authenticated exporter and status-line activity only.
The fixed-cleanup fixture derives every task-scoped file name from the telemetry module and the generated Pi extension itself, then requires each name to appear in the teardown, child-teardown, and spawn-rollback removal lists, so a new task-scoped file cannot be added without its cleanup entry.
Both suites' JSON assertions now fail the run rather than only printing to stderr.

The generated-extension fixture also asserts that the extension source contains neither `message.content` nor `sessionManager` access.

## Claude loopback collector

The Claude fixture starts the real task-scoped collector with an official-auth-status fake on `PATH`, verifies a `127.0.0.1` endpoint, and submits synthetic OTLP/HTTP JSON with approved usage fields plus hostile prompt, response, tool, account, request, email, and session markers.
It verifies exact token projection, main-model selection, auxiliary usage inclusion, duplicate suppression, wrong-token rejection, absent browser routes, raw-marker absence from both snapshot and private summary, owner-only launch state, and exact-process cleanup.
The runtime privacy self-test performs the same field-projection assertion before any real Claude launch can enable telemetry.

The exact privacy pins asserted by the test are:

```text
OTEL_LOG_USER_PROMPTS='0'
OTEL_LOG_ASSISTANT_RESPONSES='0'
OTEL_LOG_TOOL_DETAILS='0'
OTEL_LOG_RAW_API_BODIES='0'
```

The collector cleanup test records its task PID, invokes the fixed stop helper, and verifies both process absence and removal of only that task's control, activity, and summary records.
A separate start test points the launch environment at an unpublishable location and confirms the failed start reports failure, publishes nothing, retires its own collector, and leaves no control record behind.

## Codex worker transport refusal

Command:

```sh
codex app-server --help
```

Relevant exact output from codex-cli 0.144.1:

```text
--listen <URL>
    Transport endpoint URL. Supported values: `stdio://` (default), `unix://`, `unix://PATH`,
    `ws://IP:PORT`, `off`
```

The server exposes official transports, but the standalone Codex TUI help on this installation exposes no option to attach that TUI to a caller-owned app-server thread while a second observer multiplexes it.
No prompt or thread was started to investigate that limitation.
Firstmate therefore leaves the existing Codex TUI launch unchanged and reports worker model/token telemetry unavailable.

## Codex account protocol schemas

Command:

```sh
codex app-server generate-json-schema --out <temporary-directory> --experimental
```

The generated `ClientRequest.json` on codex-cli 0.144.1 includes exactly the read methods used by Firstmate:

```text
account/read
account/rateLimits/read
```

The generated `v2/GetAccountResponse.json` requires `requiresOpenaiAuth` and distinguishes `apiKey` from `chatgpt` accounts.
The generated `v2/GetAccountRateLimitsResponse.json` requires `rateLimits` and defines `usedPercent` as an integer, `windowDurationMins` as an integer or null, and `resetsAt` as Unix seconds or null.
The response schema also contains email, `limitId`, reset-credit IDs, and internal keyed limit maps, which are deliberately discarded before projection.

The fake app-server test verifies the exact outbound method list and fails if any thread or turn method appears.
It also supplies hostile account, map, limit, credit, and credential markers and verifies that none reaches the result.

Command:

```sh
bin/fm-test-run.sh tests/fm-plan-usage.test.sh
```

Exact focused result on 2026-08-01:

```text
ok - Codex official account protocol projects exact durations and honors 60-second single-flight caching
ok - plan reader gates auth/version/schema, bounds timeout, and suppresses expired cached windows
ok - manual Claude plan input is disabled by default, owner-only, bounded, explicit, and expiring
ok - plan cache refuses symlinks and implementation excludes forbidden sources
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

## Codex live no-prompt smoke

The live smoke used only the fixed Firstmate plan command and immediately reduced its output to non-identity shape fields.
It did not start a thread or turn and made no model request.

Command:

```sh
state=.telemetry-evidence-state
rm -rf "$state"
mkdir "$state"
FM_STATE_OVERRIDE="$PWD/$state" bin/fm-plan-usage-snapshot.sh --json \
  | python3 -c 'import json,sys; x=json.load(sys.stdin); c=x["providers"][0]; print("schema="+x["schema"]); print("provider="+c["provider"]); print("status="+c["status"]); print("plan_present="+str(c["plan"] is not None).lower()); print("window_labels="+",".join(w["label"] for w in c["windows"])); print("claude_reason="+x["providers"][1]["reason"])'
rm -rf "$state"
```

Exact output on 2026-08-01:

```text
schema=fm-plan-usage-snapshot.v1
provider=codex
status=fresh
plan_present=true
window_labels=7-day
claude_reason=unsupported_machine_readable_source
```

The allowlist intentionally omits percentages, reset times, account data, session data, and internal limit identifiers from tracked evidence.
