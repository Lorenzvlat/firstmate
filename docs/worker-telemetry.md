# Worker and plan telemetry

This document is the single contract owner for Firstmate's model, token, and subscription-plan telemetry projections.
The projections are local read-only producer surfaces intended for a separately secured dashboard consumer.
They never grant control, approval, interrupt, merge, browser-write, or credential authority.
Active empirical evidence is recorded in [verification/worker-telemetry.md](verification/worker-telemetry.md).

## Fixed read-only commands

Worker telemetry is available only through this fixed command:

```sh
bin/fm-worker-telemetry-snapshot.sh --json
```

The command emits `fm-worker-telemetry-snapshot.v1`, reads only the current Firstmate home's local task records, returns at most 100 workers, and emits at most 512 KiB.
It takes no task ID, path, command, provider, or source selection from a request.

Subscription-plan telemetry is available only through this fixed command:

```sh
bin/fm-plan-usage-snapshot.sh --json
```

The command emits `fm-plan-usage-snapshot.v2`, always returns one Codex record and one Claude record, and emits at most 64 KiB.
It takes no account, command, endpoint, credential, provider, or source selection from a request.

These commands are independent from `fm-fleet-snapshot.v1` so a local lifecycle read never acquires a vendor-network dependency.

## Worker snapshot contract

The normalized output shape is:

```json
{
  "schema": "fm-worker-telemetry-snapshot.v1",
  "generatedAt": "2026-08-01T00:00:00.000Z",
  "workers": [
    {
      "taskId": "safe-task-id",
      "harness": "pi",
      "status": "fresh",
      "observedAt": "2026-08-01T00:00:00.000Z",
      "coverage": "full_worker",
      "model": {
        "provider": "openai-codex",
        "id": "gpt-5.6-sol"
      },
      "tokens": {
        "input": 1200,
        "output": 300,
        "cacheRead": 800,
        "cacheWrite": 100,
        "reasoningOutput": null,
        "total": 2400,
        "totalSemantics": "source_reported"
      },
      "selection": {
        "modelReason": "matched_dispatch_rule",
        "modelReasonLabel": "Dispatch rule",
        "effort": "high",
        "effortLabel": "High"
      }
    }
  ],
  "omitted": 0,
  "warnings": []
}
```

`harness` is exactly `pi`, `codex`, `claude`, or `other`.
`status` is exactly `fresh`, `stale`, `partial`, or `unavailable`.
`coverage` is exactly `full_worker`, `since_observed`, or `none`.
`totalSemantics` is exactly `source_reported` or `sum_of_disjoint_components`.
Warnings are deduplicated, bounded to five values, and drawn only from `invalid_metadata`, `invalid_telemetry`, `worker_limit`, `output_limit`, and `source_error`.

`selection.modelReason` is exactly `explicit_captain_override`, `matched_dispatch_rule`, `configured_default`, `static_default`, `quota_fallback`, or `unavailable`.
Those codes have the fixed display labels `Captain override`, `Dispatch rule`, `Configured default`, `Static default`, `Quota fallback`, and `Unavailable`.
An omitted selection reason becomes `unavailable`; `fm-spawn` never infers provenance from model, harness, configuration, or other launch arguments.
`selection.effort` is exactly `low`, `medium`, `high`, `xhigh`, `max`, or `null`.
Those values have the fixed display labels `Low`, `Medium`, `High`, `Extra high`, `Maximum`, and `Unavailable`.
Missing, duplicate, unrecognized, prose-bearing, or command-shaped selection metadata becomes the fixed unavailable code and label rather than a reflected value.
Firstmate never projects dispatch-rule text, prompt text, profile strategy, commands, paths, logs, hidden model reasoning, or arbitrary rationale prose.

Provider identifiers are at most 40 ASCII identifier characters.
Model identifiers are at most 120 ASCII identifier characters.
Token values are non-negative safe integers or `null` and never estimates.
Input, output, cache-read, cache-write, and total are either all available or all `null`.
A source-reported zero remains available zero.
The source total is not recomputed when the harness reports its own total because cached and reasoning tokens may be subsets rather than disjoint components.

A live non-final observation becomes stale after 90 seconds without a writer heartbeat.
`stale` means only that no writer heartbeat arrived inside that window; it never asserts that the worker process exited.
A writer-confirmed final observation does not age into stale.
A writer that observed the worker from launch uses `full_worker`.
A writer that missed any earlier usage uses `since_observed`, and consumers must label those values as usage since telemetry began.
An existing worker without a valid generation-bound writer record is `unavailable` and is never backfilled from logs.

The task ID is present only so a trusted local consumer can join against known `fm-fleet-snapshot.v1` tasks before applying its existing opaque alias.
It is not display text and must not cross a browser boundary unchanged.

## Private writer contract

Harness producers atomically replace `state/<task-id>.telemetry.json` with an owner-only `fm-worker-telemetry.v1` record.
The private writer record includes a random launch generation that is never exposed by the snapshot command.
Writers may restore only a matching schema, task ID, harness, and generation.
A telemetry file is admitted only when it is a direct regular-file child of the real state directory, is not a symlink, is owned by the current user, grants no group or other permissions, and is at most 16 KiB.
Temporary files use owner-only creation and atomic replacement.
Every write stages at one deterministic hidden name beside its own file (the file's own name with `.tmp` appended, dot-prefixed first when the file is not already hidden), so an interrupted write leaves at most one leftover per file and each fixed cleanup list removes it by exact name rather than by globbing the state directory.
The snapshot command projects fields one by one and never forwards a private writer object wholesale.

Telemetry failures are passive.
A producer error, collector error, malformed event, write failure, heartbeat failure, or cleanup error must never stop, interrupt, approve, steer, or otherwise control worker execution.

## Pi producer

Every newly launched non-secondmate Pi worker receives the existing task-scoped generated extension outside the project copy.
The extension retains the established `turn_end` signal and adds only model and usage projection.
The `turn_end` registration comes first and each projection registration and handler is isolated, so a rejected event name or a malformed event payload can never cost the worker its turn-end signal.
It reads the resolved `ctx.model`, `model_select.model`, and finalized assistant message `provider`, `model`, and `usage` fields.
It never reads message content, tool arguments, tool results, context files, the Pi session file, or session history.

The writer adds finalized `usage.input`, `usage.output`, `usage.cacheRead`, `usage.cacheWrite`, and `usage.totalTokens` once per finalized assistant message.
A model switch updates the displayed provider/model without resetting cumulative usage.
A malformed or overflowing usage observation changes coverage to partial rather than emitting an estimate.
The writer emits a 30-second heartbeat and a final observation on Pi session shutdown.
It stages each write at one task-scoped owner-only name beside the record, so an interrupted write leaves at most one leftover that normal task cleanup removes by exact name.

## Claude producer

Claude worker telemetry is always on and has no operator opt-out.
Every newly launched non-secondmate Claude worker initializes a record, resolves provider identity, starts its own task-scoped loopback collector, and receives the exporter environment described below.
It is deliberately not a `config/` toggle: the projection is task-scoped, passive, and privacy-pinned, and every one of its artifacts is removed by that task's own cleanup.
The single kill path for a misbehaving collector is `bin/fm-claude-telemetry.sh stop <task-id>`, which retires only that task's identity-checked collector.

The launch also writes a `statusLine` command into that worker's task-local `.claude/settings.local.json`.
It is scoped to the worker worktree, is git-excluded, and is removed with the worktree, but it does override any global status line the captain configured for the duration of that task.
Its effects are the bounded model projection described below and the home-level plan projection owned by [Claude subscription-plan source](#claude-subscription-plan-source).
The status-line render loads no collector, subprocess, or nonce module, leaves an unchanged model record untouched, and refreshes an unchanged plan cache at most once per minute, so it stays a cheap per-render call.

Claude telemetry is enabled for a newly launched non-secondmate worker only when the built-in privacy self-test passes and a task-scoped loopback collector starts successfully.
Otherwise Claude launches normally and worker telemetry remains unavailable.
The launch sources that environment only when it is readable at launch time and never conditions the worker command on that read.
A start that cannot publish its launch environment retires its own collector rather than leaving it running.

The official Claude status-line JSON is the idle/startup model source and the activity-coupled subscription-plan source.
A status-line update is applied only for a valid task ID whose record carries the Claude harness and the exact generation that launch bound into the status-line command.
The official Claude Code OTel `claude_code.api_request` log event is the cumulative token source.
Provider identity comes from an explicit official Bedrock, Vertex, or Foundry launch mode, or from an allowlisted projection of official `claude auth status` under the launch environment.
Raw authentication output is discarded and never reaches a writer record.

The launch pins these content-bearing options off:

```text
OTEL_LOG_USER_PROMPTS=0
OTEL_LOG_ASSISTANT_RESPONSES=0
OTEL_LOG_TOOL_DETAILS=0
OTEL_LOG_RAW_API_BODIES=0
```

Metrics export is disabled because the required usage fields are in the official log event.
Session and account UUID metric attributes are also disabled where the installed client honors those controls.
The exporter uses OTLP/HTTP JSON over a task-scoped `127.0.0.1` endpoint with an owner-only launch token.
The collector has no browser endpoint and rejects every GET, HEAD, non-log path, wrong token, non-JSON content type, oversized body, and malformed batch with a generic response.

The collector accepts at most 64 KiB per request, eight resource groups, sixteen scope groups per resource, 128 records per scope, 256 records per request, and 64 attributes per record.
It admits only the exact `claude_code.api_request` name, model identifier, query source, event sequence, session identifier for in-memory deduplication, and four non-negative safe-integer token fields.
It discards prompts, responses, tool details, paths, standard resource attributes, account identity, request identity, and every arbitrary attribute before updating the private summary.
It retains only a bounded hash of the session/sequence pair in memory and never persists raw OTel messages or raw deduplication identifiers.

Claude input, output, cache-read, and cache-creation values are disjoint categories.
The projected total is therefore their exact safe-integer sum and uses `sum_of_disjoint_components` semantics.
Usage from main, subagent, compaction, and auxiliary requests contributes to the worker total.
Only a main-query event or official status-line update may select the displayed model.
A malformed, rejected, or overflowing usage observation changes coverage to `since_observed` for the remaining life of that collector, so a later valid event never restores `full_worker`.
A status-line update that repeats the already recorded model leaves the record untouched, because the collector heartbeat rather than the status line owns freshness.
Claude freshness is activity-based rather than process-based.
The collector heartbeats only while that worker's own authenticated exporter request or status-line render arrived within the last 120 seconds, so a Claude record stays fresh through continued worker activity and ages to stale roughly three to three and a half minutes after the last such activity (a 30-second heartbeat inside the 120-second activity window, then the 90-second staleness threshold).
A Claude worker that is alive but idle therefore reads stale, and Firstmate deliberately tracks no Claude process lifecycle to distinguish the two.
Activity is recorded as a task-scoped owner-only marker beside the record; it carries no payload, is never projected, and is removed with the rest of that task's telemetry.

Collector cleanup validates the owner-only control record, task ID, PID, process start instant, executable script, state root, and exact collector arguments before signaling.
The argument check compares the raw process command tail, because process listings join arguments with plain spaces and never quote, so a state root, task temp path, or interpreter path containing whitespace still retires its own collector.
It waits a bounded interval after TERM and uses KILL only after the same complete process identity is revalidated.
It never searches process namespaces and never targets a shared Claude, Firstmate, Herdr, Codex, or No Mistakes process.

A collector also retires itself, so no path that skips cleanup can leave a loopback listener behind for the rest of the session.
It exits after three consecutive heartbeats without its own generation-bound record, which covers a removed state directory or a cleanup that removed the record without signaling, and after twenty consecutive heartbeats without the task's own `state/<task-id>.meta`, which covers a spawn killed before it recorded the task.
Both bounds track task-cleanup artifacts rather than worker lifecycle, so an alive-but-idle Claude worker keeps its collector.
A self-retiring collector removes the control record it wrote for itself, and never one a later collector for the same task wrote.

## Codex worker telemetry

Codex worker model and token telemetry is explicitly unavailable in this version.
The established standalone Codex TUI launch remains unchanged.
The installed supported interfaces do not prove that this TUI can attach to a task-scoped app-server while an independent observer safely multiplexes the same thread.
Firstmate therefore does not parse rollouts, transcripts, terminal output, footers, hooks containing prose, or credential stores as a fallback.
A future producer requires fake-protocol coverage plus a no-prompt transport smoke proving official TUI attachment, observer multiplexing, task isolation, and exact teardown before launch behavior can change.

## Plan snapshot contract

The normalized output shape is:

```json
{
  "schema": "fm-plan-usage-snapshot.v2",
  "generatedAt": "2026-08-01T00:00:00.000Z",
  "providers": [
    {
      "provider": "codex",
      "product": "chatgpt_subscription",
      "plan": "plus",
      "status": "fresh",
      "observedAt": "2026-08-01T00:00:00.000Z",
      "expiresAt": null,
      "reason": null,
      "windows": [
        {
          "key": "general:primary:10080",
          "scope": "general",
          "label": "7-day",
          "usedPercent": 43,
          "remainingPercent": 57,
          "windowSeconds": 604800,
          "resetsAt": "2026-08-08T00:34:44.000Z"
        }
      ]
    },
    {
      "provider": "claude",
      "product": "claude_subscription",
      "plan": null,
      "status": "fresh",
      "observedAt": "2026-08-01T00:00:00.000Z",
      "expiresAt": "2026-08-01T00:15:00.000Z",
      "reason": null,
      "windows": [
        {
          "key": "general:five_hour:300",
          "scope": "general",
          "label": "5-hour",
          "usedPercent": 23.5,
          "remainingPercent": 76.5,
          "windowSeconds": 18000,
          "resetsAt": "2026-08-01T04:43:20.000Z"
        }
      ]
    }
  ]
}
```

The provider array has exactly the Codex and Claude records in that order.
Each provider has at most twelve windows.
`status` is exactly `fresh`, `stale`, `unavailable`, or `manual`.
`reason` is `null` or exactly `not_authenticated`, `api_key_not_subscription`, `timeout`, `source_error`, `unsupported_schema`, `expired`, `manual_snapshot`, or `not_observed`.
Official and manual plans are admitted only from their fixed vendor enums.
Percentages are finite JSON numbers from zero through 100, and remaining percentage is exactly `100 - usedPercent` without a floating-point display artifact.
Codex and manual percentages remain integers, while the official Claude source may supply decimals.
Window seconds are exactly documented duration minutes multiplied by 60 with safe-integer checks.
Reset values are canonical millisecond ISO timestamps converted from documented Unix seconds.

The 300-minute and 10,080-minute durations have fixed `5-hour` and `7-day` labels regardless of primary or secondary position.
Other durations receive a mechanical minute, hour, or day label and never guessed semantics.
Keys are locally derived from scope, slot, duration, and a bounded local scoped-window ordinal.
OpenAI account IDs, emails, raw limit IDs, reset-credit IDs, internal map keys, and arbitrary labels are never exposed.
An additional limit name is used only when it passes the bounded model/feature label grammar, and otherwise its label is `Scoped limit`.

## Codex ChatGPT-plan source and cache

Codex ChatGPT-plan usage uses only a bounded official `codex app-server --stdio` process under read-only and untrusted policy.
The reader sends exactly `initialize`, `account/read`, and `account/rateLimits/read`.
It never starts, reads, resumes, or writes a thread or turn, so it makes no model request.

The vendor process receives only `HOME`, `PATH`, `LANG`, and an explicitly present `CODEX_HOME`.
It never receives `OPENAI_API_KEY` from the caller.
The implementation accepts only the empirically verified Codex 0.144 patch line and strictly gates account and rate-limit response shapes.
API-key authentication returns `api_key_not_subscription` because API billing is not ChatGPT subscription usage.

The reader has a five-second total deadline, a 64 KiB stdout bound, a 32 KiB line bound, generic enum errors, and process-group TERM/KILL cleanup.
It never returns stderr or exception text.
It does not call `quota-axi`, direct vendor HTTP, credential files, Keychain, or a browser.

A private owner-only cache permits one successful refresh per 60 seconds.
A nonblocking owner-only lock provides single-flight behavior across concurrent command invocations.
After a refresh error, a prior successful record may be shown as stale for at most fifteen minutes and only while every displayed reset remains in the future.
Once any displayed window reaches reset, all cached Codex percentages are suppressed until a fresh official observation arrives.
The cache is a direct regular-file child of the real state directory, refuses symlinks and non-owner files, and is at most 64 KiB.

## Claude subscription-plan source

Claude subscription-plan usage comes from Anthropic's documented [Claude Code status-line JSON](https://code.claude.com/docs/en/statusline) for Claude.ai Pro and Max subscriptions.
The official [Claude Code changelog](https://code.claude.com/docs/en/changelog) records that version 2.1.80 added this source.
Firstmate accepts supported Claude Code 2.x versions at or above 2.1.80 and rejects older or unrecognized major versions.
The existing task-local status-line command sends the official JSON to the passive 16 KiB `fm-claude-telemetry.sh status` receiver.
The receiver admits plan data only after its existing task ID, launch generation, and Claude harness checks succeed.
No separate Claude process, model request, credential read, or network request is made for this projection.

The complete plan allowlist is:

- `version`.
- `rate_limits.five_hour.used_percentage`.
- `rate_limits.five_hour.resets_at`.
- `rate_limits.seven_day.used_percentage`.
- `rate_limits.seven_day.resets_at`.

Either named window may be absent independently.
A present window must contain both values.
The percentage must be a finite JSON number from zero through 100 and must round-trip through the public JSON number representation without changing its decimal value.
Its published remaining complement must round-trip on the same rule, so a percentage that could not be projected later is refused at admission instead of being cached.
The reset must be a safe integer Unix epoch strictly after observation and no later than the named window duration plus five minutes after observation.
A present malformed window rejects the complete observation, while an already expired window is omitted and another valid window may still refresh the cache.
At least one valid unexpired window is required for a write.
Unknown status-line fields are ignored and never persisted.
The identical admission rule is applied by the writer, the cache validator, and the public projection, so no value can pass one gate and fail the next.

The private cache schema is:

```json
{
  "schema": "fm-claude-plan-statusline-cache.v1",
  "source": "claude_code_statusline",
  "sourceVersion": "2.1.221",
  "observedAt": "2026-08-01T00:00:00.000Z",
  "windows": [
    {
      "window": "five_hour",
      "usedPercent": 23.5,
      "resetsAt": 1785559400
    }
  ]
}
```

The cache is the direct state child `state/.claude-plan-usage-cache.json`, is owned by the current user, grants no group or other permissions, is not a symlink, has one link, and is at most 4 KiB.
Concurrent receivers use the separate owner-only no-follow `state/.claude-plan-usage.lock` without waiting when another writer holds it.
The fixed same-directory staging file is atomically replaced while that lock is held, and an unsafe existing cache or staging path is refused rather than followed or overwritten.
Existing cache content that is unreadable or no longer valid is replaced only after every containment, ownership, permission, no-follow, link-count, and size check on that path has passed, so a corrupt or stepped-clock cache recovers on the next observation instead of blocking the source permanently.
A newer observation whose source version and windows are unchanged rewrites the cache at most once per minute, while any changed window is written immediately; the two-minute fresh and fifteen-minute stale contracts are unaffected because an active worker refreshes well inside both.
The receiver never holds a task telemetry lock while acquiring the shared plan lock.
Cache failure is passive and cannot prevent the already-authorized model projection, worker liveness observation, Stop signaling, collector operation, or Claude worker execution.
Task cleanup deliberately leaves this home-level account cache intact.

A valid cache projects the fixed five-hour and seven-day labels and durations from the source field names.
The official projection has `plan: null`, because the status-line fields are authoritative without adding a separate entitlement read.
It has `status: fresh` through two minutes after `observedAt`, `status: stale` until fifteen minutes, `reason: null`, and `expiresAt` exactly fifteen minutes after observation.
Each window is removed independently at its own reset.
Once all windows have reset or fifteen minutes have elapsed, no official percentage is exposed and the official result is unavailable with `reason: expired`.
When no compatible worker has supplied a valid observation, the result is unavailable with `reason: not_observed`.
An unsafe or malformed cache is unavailable with the generic `source_error` reason and never reflects its contents.

Source precedence is a valid unexpired official cache, then a valid explicitly enabled manual snapshot, then the bounded unavailable result.
Official data never claims a manual plan enum, and manual data remains visibly `status: manual` with `reason: manual_snapshot`.
The source is activity-coupled because Claude Code updates the values after ordinary Claude responses rather than through an idle account poll.
Usage from another device is reflected only after a later local Claude response refreshes the status-line values.

Firstmate never automates `/usage`, scrapes claude.ai, calls an undocumented authenticated endpoint, reads credential files or Keychain, parses terminal output or transcripts, starts browser automation, or infers subscription usage from worker tokens, local context, cost, API billing, or organization analytics.

### Disabled manual Claude boundary

A service may opt into an owner-maintained manual Claude fallback only by setting `FM_PLAN_USAGE_MANUAL=1` before it starts.
The default and every other value keep the manual source disabled.
The fixed source is `config/plan-usage-manual.json` under the effective Firstmate home or its test-only `FM_CONFIG_OVERRIDE`.
The only supported mutation command is the local guided `bin/fm-plan-usage-manual.sh` helper, whose header and `--help` own its exact mechanics.
Its only action creates the fixed snapshot exclusively.
The helper has no clear, overwrite, quarantine, restore, or replacement path; the operator explicitly removes the local snapshot before another import.
There is no browser read/write route, arbitrary mutation input, credential access, terminal automation, or UI automation for this file.

The private input schema is:

```json
{
  "schema": "fm-plan-usage-manual.v1",
  "provider": "claude",
  "plan": "pro",
  "observedAt": "2026-08-01T00:00:00.000Z",
  "expiresAt": "2026-08-01T01:00:00.000Z",
  "windows": [
    {
      "slot": "primary",
      "usedPercent": 40,
      "windowDurationMins": 300,
      "resetsAt": 1785546000
    }
  ]
}
```

The file must be a direct regular-file child of the real config directory, must not be a symlink, must be owned by the current user, must grant no group or other permissions, and must be at most 16 KiB.
Its object and every window use exact keys.
It accepts at most twelve numeric windows, only the fixed `primary` and `secondary` slots, the fixed Claude plan enum, safe integer percentages and durations, canonical observed/expiry timestamps, and documented Unix reset seconds.
The output derives keys from the fixed manual slots and mechanically derives labels, seconds, remaining percentage, and reset timestamps.
A valid unexpired file is visibly `status: manual`, `reason: manual_snapshot`, and carries its explicit `expiresAt` and age source `observedAt`.
An expired file or reset window exposes no percentages and returns unavailable with `reason: expired`.
A missing, unsafe, oversized, malformed, prose-bearing, or unsupported manual input exposes no source value and returns unavailable with a generic reason.
A manual snapshot can never claim official or fresh provenance.

## Retention and browser boundary

Task cleanup removes only that task's generated Pi extension, writer record, writer lock, writer staging leftover, Claude activity marker, Claude collector handshake files, owner-only Claude launch environment, and identity-validated collector.
The fixed removal list is applied by name even when the telemetry helper itself cannot run, so no task-scoped telemetry file outlives its task.
Plan cache state is home-local and contains only normalized allowlisted records.
No raw Pi event, Claude status payload, OTel batch, Codex app-server line, authentication object, account identity, session/thread/request identifier, prompt, response, tool content, terminal content, credential, path, command, cost, or raw log is persisted by this feature.

A dashboard consumer must invoke only the two fixed read-only commands, validate every nested field, join only against known fleet task IDs, replace the task ID with its existing opaque alias, and discard the source task ID before browser projection.
Provider/model labels and bounded numeric telemetry are the only values this contract authorizes for de-aliasing.
