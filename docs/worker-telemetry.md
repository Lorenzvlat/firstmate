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

The command emits `fm-plan-usage-snapshot.v1`, always returns one Codex record and one Claude record, and emits at most 64 KiB.
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
The snapshot command projects fields one by one and never forwards a private writer object wholesale.

Telemetry failures are passive.
A producer error, collector error, malformed event, write failure, heartbeat failure, or cleanup error must never stop, interrupt, approve, steer, or otherwise control worker execution.

## Pi producer

Every newly launched non-secondmate Pi worker receives the existing task-scoped generated extension outside the project copy.
The extension retains the established `turn_end` signal and adds only model and usage projection.
It reads the resolved `ctx.model`, `model_select.model`, and finalized assistant message `provider`, `model`, and `usage` fields.
It never reads message content, tool arguments, tool results, context files, the Pi session file, or session history.

The writer adds finalized `usage.input`, `usage.output`, `usage.cacheRead`, `usage.cacheWrite`, and `usage.totalTokens` once per finalized assistant message.
A model switch updates the displayed provider/model without resetting cumulative usage.
A malformed or overflowing usage observation changes coverage to partial rather than emitting an estimate.
The writer emits a 30-second heartbeat and a final observation on Pi session shutdown.

## Claude producer

Claude telemetry is enabled for a newly launched non-secondmate worker only when the built-in privacy self-test passes and a task-scoped loopback collector starts successfully.
Otherwise Claude launches normally and worker telemetry remains unavailable.

The official Claude status-line JSON is the idle/startup model source.
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

Collector cleanup validates the owner-only control record, task ID, PID, process start instant, executable script, state root, and exact collector arguments before signaling.
It waits a bounded interval after TERM and uses KILL only after the same complete process identity is revalidated.
It never searches process namespaces and never targets a shared Claude, Firstmate, Herdr, Codex, or No Mistakes process.

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
  "schema": "fm-plan-usage-snapshot.v1",
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
      "status": "unavailable",
      "observedAt": null,
      "expiresAt": null,
      "reason": "unsupported_machine_readable_source",
      "windows": []
    }
  ]
}
```

The provider array has exactly the Codex and Claude records in that order.
Each provider has at most twelve windows.
`status` is exactly `fresh`, `stale`, `unavailable`, or `manual`.
`reason` is `null` or exactly `not_authenticated`, `api_key_not_subscription`, `timeout`, `source_error`, `unsupported_schema`, `unsupported_machine_readable_source`, `expired`, or `manual_snapshot`.
Official and manual plans are admitted only from their fixed vendor enums.
Percentages are integers from zero through 100, and remaining percentage is exactly `100 - usedPercent`.
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

Claude subscription-plan usage defaults to:

```json
{
  "provider": "claude",
  "product": "claude_subscription",
  "plan": null,
  "status": "unavailable",
  "observedAt": null,
  "expiresAt": null,
  "reason": "unsupported_machine_readable_source",
  "windows": []
}
```

The installed Claude Code client has no supported machine-readable subscription-plan usage source.
Firstmate never automates `/usage`, claude.ai, an undocumented endpoint, credential files, Keychain, or terminal output.
Worker token totals are never converted into a plan percentage.

### Disabled manual Claude boundary

A service may opt into an owner-maintained manual Claude snapshot only by setting `FM_PLAN_USAGE_MANUAL=1` before it starts.
The default and every other value keep the manual source disabled.
The fixed source is `config/plan-usage-manual.json` under the effective Firstmate home or its test-only `FM_CONFIG_OVERRIDE`.
There is no browser read/write route, mutation command, credential access, terminal automation, or UI automation for this file.

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
The output derives keys, labels, seconds, remaining percentage, and reset timestamps exactly as it does for official windows.
A valid unexpired file is visibly `status: manual`, `reason: manual_snapshot`, and carries its explicit `expiresAt` and age source `observedAt`.
An expired file or reset window exposes no percentages and returns unavailable with `reason: expired`.
A missing, unsafe, oversized, malformed, prose-bearing, or unsupported manual input exposes no source value and returns unavailable with a generic reason.
A manual snapshot can never claim official or fresh provenance.

## Retention and browser boundary

Task cleanup removes only that task's generated Pi extension, writer record, writer lock, owner-only Claude launch environment, and identity-validated collector.
Plan cache state is home-local and contains only the normalized provider record.
No raw Pi event, Claude status payload, OTel batch, Codex app-server line, authentication object, account identity, session/thread/request identifier, prompt, response, tool content, terminal content, credential, path, command, cost, or raw log is persisted by this feature.

A dashboard consumer must invoke only the two fixed read-only commands, validate every nested field, join only against known fleet task IDs, replace the task ID with its existing opaque alias, and discard the source task ID before browser projection.
Provider/model labels and bounded numeric telemetry are the only values this contract authorizes for de-aliasing.
