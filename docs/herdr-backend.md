# Herdr runtime backend

Herdr is an experimental agent-native terminal backend with native per-pane agent state and push events.
Firstmate requires Herdr protocol 14 or newer; versions 0.7.1, 0.7.3, 0.7.4, and 0.7.5 are verified, with protocol-16 features enabled only when available.
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the experimental limits below.

Prerequisites:

- Herdr protocol 14 or newer, installed from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering and native event subscription.

Herdr is dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

Select Herdr with local `config/backend` containing `herdr`, `FM_BACKEND=herdr` for one launch, or an explicit request to Firstmate.
It is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn prints an opt-out notice.

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those installers and their sourced version contracts own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

## Watching and task containers

Each Firstmate home gets one durable workspace with one task tab per endpoint.
The primary workspace is `firstmate`.
A secondmate home uses `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker.
The secondmate process and every child it launches resolve the same home label; a secondmate launched by the primary receives a narrowly scoped home override during container creation.

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused because no prior target exists, but later task creation does not intentionally steal focus.

Herdr does not enforce workspace or tab label uniqueness.
Firstmate adopts the first workspace matching its derived home label and refuses duplicate task tabs inside it.
Avoid naming a personal workspace `firstmate` or `2ndmate-<id>` because the adapter cannot distinguish that label collision from its own container.
An older secondmate workspace using `firstmate-<id>` is not migrated automatically; rename it manually before expecting new tasks or recovery to use it.

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
The per-home workspace is reused while it has task tabs.
Closing its last tab can remove the workspace, and the next spawn recreates it.

## Firstmate worker identity and No Mistakes child activity

Herdr 0.7.4's stock expanded agent row is `[["state_icon", "workspace", "tab"], ["agent"]]`.
That is why several Pi workers in Firstmate's shared workspace all show the prominent label `firstmate`, a dim task tab on the right, and the generic `pi` label below.
The protocol has no per-pane override for the built-in `workspace` token, and its schema has no nested-agent or child-agent relation.
`agent.start` would create an independently interactive terminal, so Firstmate deliberately does not use it for No Mistakes visibility.

Firstmate requires every new Herdr-backed Pi worker to receive a unique task-specific Herdr agent name after native Pi detection, such as `Pi · firstmate/review-a [w1:p2]`.
The owner/task prefix is human-readable, and the response-derived pane suffix keeps the name distinct even if two homes sharing a session reuse an owner label and task id.
Firstmate verifies `agent=pi` before calling `agent rename`, leaves that canonical identity unchanged, and never renames the shared workspace or the `fm-<id>` task tab.
A shell or non-Pi agent is never renamed.
Missing native registration, a conflicting name, a failed rename, or an unreadable verification response fails the spawn, closes only the exact failed task pane when focus-safe cleanup can be verified, and then runs the normal complete spawn rollback.
An unconfirmed pane close or incomplete rollback retains the task metadata for deterministic teardown rather than discarding its ownership record.

The task-specific Pi name must appear in the prominent first position rather than Herdr's shared workspace label.
Add this supported Herdr sidebar override to the operator's normal Herdr config:

```toml
[ui.sidebar.agents.rows_by_agent]
pi = [["state_icon", "agent", "tab"], ["state_text", "$nm_summary"]]
```

Firstmate never edits, reloads, or restarts the operator's Herdr config or TUI automatically.
It validates the config file as a prerequisite but never treats disk config alone as proof of the running client's presentation.
A Herdr-backed Pi spawn proceeds only when the adapter can also verify that the running session has applied the exact task-name-first Pi row, both before task creation and after the unique rename.
Herdr 0.7.4 protocol 16 exposes no live TUI sidebar-layout read, so the current adapter refuses the spawn even when the config file is valid rather than silently accepting an unverified generic identity.
The non-destructive remediation is to use a Herdr release with exact live sidebar-layout verification, wait until the entire Firstmate fleet using that session is idle, perform one planned Herdr TUI reload or restart, and retry the spawn.
The override uses only Herdr's documented canonical `pi` row selector, built-in `agent` and `tab` values, and the custom metadata token `$nm_summary`.
When no review is active, the optional custom token is elided and the second row still shows Pi's native state text.

While the owning Herdr worker has an attributable active No Mistakes review or fix round, the watcher reports source-scoped `pane.report_metadata` on that worker's existing pane.
The default sidebar's `agent` row becomes a bounded summary beginning with the task identity and including the child role, state, elapsed time, and last allowlisted structural activity.
The recommended Pi row above keeps the same task identity prominent and adds the concise `$nm_summary` row.
Tokens also expose `nm_role`, `nm_state`, `nm_phase`, `nm_elapsed`, and `nm_activity` for other supported custom layouts.
Waiting for the captain, failure, timeout, and completion are distinct states.
Completion, failure, and timeout are transient one-shot presentations, while active and waiting presentations use a renewable bounded TTL sized to cover the eligible-task refresh rotation.
Herdr's TTL removes abandoned metadata on its own, and a later bounded refresh explicitly clears expired source metadata and retires its private non-authoritative cache.

This surface is observational only.
It creates no pane, agent, Firstmate task, dispatch target, or fleet record, and it has no send, focus, interrupt, kill, resume, or control action.
No Mistakes remains the sole owner of child processes, run lifecycle, and structured output.
Only strict run ids, fixed role/state/phase/activity values, and numeric elapsed time reach Herdr.
Prompt text, findings, paths, credentials, environment values, command lines, pids, raw errors, agent prose, and raw log lines are never copied.
If the exact `pane.report_metadata` schema is unavailable, the feature performs no No Mistakes query or Herdr mutation and existing task behavior remains unchanged.
Non-Herdr tasks never enter this path.

[`verification/runtime-backends.md`](verification/runtime-backends.md#pi-worker-identity-and-no-mistakes-activity) records the versioned schema, identity, layout, privacy, and cleanup evidence for this feature.

## Optional presentation spaces

Create local gitignored `config/herdr-presentation-spaces` to request a disposable one-task workspace for each new crewmate or scout.
The setting is inherited into secondmate homes through the normal configuration-convergence owner.
A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An absent or unconverged setting keeps the flat default.

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token before asking Herdr to create anything.
After the new workspace converges to one exact task endpoint beneath one exact parent, the journal advances to a version 2 binding that records the physical home, named session, endpoint, parent, and immutable expected labels.
The token is visible in the workspace title because Herdr exposes no verified hidden persistent field, but neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

The normal `fm-<id>` task tab is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.
Projected children are placed in one contiguous block immediately after their owning home when the session layout, protocol, socket, `python3`, and machine-private per-session lock are all verifiable.
Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker remains on the ordinary flat or Herdr-current-order path.

Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.
Herdr can move focus when closing the last pane of a non-focused projected workspace, so projected cleanup runs under the same session lock, captures the exact active tab, refuses to delete the active tab, closes the exact task pane, and restores only the exact prior tab when needed.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.
A same-identity version 2 binding may replace one exact agent-free restart husk in place only when the physical home, session, metadata endpoint, unique token match, workspace shape and labels, parent identity and placement, and non-target focus snapshot all agree.
The replacement tab and pane are created and verified before the old pane is rechecked and closed, then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.
Version 1 journals, dead or missing panes, duplicate or absent tokens, renamed or detached spaces, cross-home mismatches, inconsistent endpoint bindings, active target tabs, and ambiguous identity or focus fall back flat without mutating the old projection when duplicate-agent risk is positively absent.
A live or unknown recorded or token-matched endpoint refuses duplicate launch.

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal and considers only that home; a primary never recursively sweeps a secondmate home.
Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
The title must contain exactly one token occurrence across the named-session snapshot and must equal the title derived from exactly one valid presentation journal in this home's own `state/`; a version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
The task's ordinary metadata must be absent, and the candidate must have exactly one tab and exactly one pane.
Before cleanup, Firstmate acquires the existing task-id spawn lock and then the shared named-session presentation lock.
Inside both locks it takes one exact snapshot, requires one unambiguous non-target focus and the exact title, token, tab, and pane shape, positively confirms no registered agent, and reads Herdr's process information for the exact named-session pane.
The process proof requires one recognized idle shell as both the shell process and the sole foreground process-group member, an operating-system process-table row for that shell, no child process, and a sleeping or idle shell state.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.
Firstmate immediately revalidates the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus before calling the existing exact-pane focus-preserving close helper.
It closes only that pane, never a workspace.
The matching journal is retired only after the exact pane is positively confirmed gone; an unconfirmed close retains the journal, while a confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.
A malformed or missing title or token, duplicate token, zero or multiple journal matches, cross-home version 2 binding, current metadata, registered or unknown agent, extra tab or pane, active target, busy lock, changed revalidation, unreadable check, or any error preserves the candidate and lets session startup continue with at most a concise warning.

Operational compromises:

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to the ordinary home workspace while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces; session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the flat task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

`tests/fm-backend-herdr-presentation-e2e.test.sh` covers multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path.
`tests/fm-herdr-session-cleanup.test.sh` covers every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary.
`tests/fm-herdr-session-cleanup-e2e.test.sh` covers the restored-shell cleanup in a guarded non-default named lab; [`verification/runtime-backends.md`](verification/runtime-backends.md#per-home-and-presentation-topology) owns the active versioned evidence.

## Default-tab prune safety

`herdr workspace create` seeds one default tab.
Firstmate prunes it only after a real task tab exists and only when the same create response supplied the seeded tab id.
An adopted workspace never supplies that id and can never enter the prune path, regardless of labels or tab count.
Immediately before close, Firstmate rechecks the exact tab, expected seed label, and native agent state.
A working seed pane is never closed.

This created-versus-adopted gate is a destructive safety boundary.
A prior label heuristic could adopt a captain-owned workspace named `firstmate` and close its live seed-shaped tab.
The current structural gate removes label inference from cleanup authority.
`tests/fm-backend-herdr-prune-safety-e2e.test.sh` reproduces the collision in an isolated named session and proves the adopted pane remains untouched.

## Endpoint metadata

```text
backend=herdr
window=<session>:<pane-id>
herdr_session=<session>
herdr_workspace_id=<workspace-id>
herdr_tab_id=<tab-id>
herdr_pane_id=<pane-id>
```

A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.

## Current transport behavior

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.

Literal text and Enter are separate operations for ordinary steers.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.
Slash and dollar-prefixed input uses the shared harness-aware settle before the first Enter so a completion popup cannot consume it.
Text is typed once; only Enter is retried.

On an idle or done native baseline, submit confirmation waits for `working` or `blocked` across a bounded polling window.
On an already active or unreadable baseline, it falls back to conservative composer clearance.
A fully unreadable target stops retrying and reports unknown.
The poll density bounds the residual possibility of an extremely fast complete turn; a missed transition can cause only a redundant Enter on an empty composer, never duplicate message text.

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for small composer and peek reads.

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore corroborates every native non-busy or unreadable result with the recorded harness's rendered busy signature before concluding that a pane is not working.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter locates the bottom-most recognized bordered row, Claude `❯` row, Codex `›` row, or a Pi separator region admitted only when native identity is exactly Pi and state is idle, done, or blocked.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains pending or unknown.

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.
If a future Herdr version strips ANSI style, ghost suggestions become pending rather than empty, which safely defers injection and eventually raises the wedge alarm.

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids, but the underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.
Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.

The generic Herdr agent-liveness probe reuses the same classifier.
A structurally gone pane becomes `missing`, a restored agent-less shell becomes `dead`, a registered agent becomes `alive`, and an unexpected read becomes `unreadable`.
Unlike tmux process-name inspection, native registration can classify Pi without guessing from a generic interpreter name.

The session-start sweep uses this probe.
Mid-session secondmate liveness is not implemented because idle secondmates are deliberately exempt from stale-pane escalation and need a separate periodic identity signal.

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.
The watcher maps the pane back to the task and skips secondmate endpoints and declared `paused:` waits.

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when protocol 16, the event schema, Python, connection, subscription, or repeated reader execution is unavailable.
There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

The away daemon supports tmux and Herdr supervisor panes only.
It refuses Zellij, Orca, and cmux as supervisor backends rather than applying the wrong transport.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

Harnesses with native tracked background execution can run the daemon in their terminal.
Pi has no such mechanism.
`bin/fm-afk-launch.sh` therefore creates a dedicated unfocused Herdr workspace, runs the daemon there with an explicit supervisor target and backend, records the exact daemon pane, and closes only that pane on stop.
It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

On stop, the daemon receives termination while `state/.afk` still exists so its final flush can run, the recorded terminal is closed, and the AFK flag is removed last.
A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server, and the ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
It provisions only non-default names beginning with `fm-lab-`, appends an explicit `--session` to allowed task commands, refuses caller-supplied session flags and server/session lifecycle subcommands, and performs destructive stop/delete only through its guarded lifecycle actions.
Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Active limits

- Herdr remains experimental.
- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Mutable labels can collide; they are never destructive authority.
- Ghost and placeholder recognition depends on ANSI de-emphasis and fails safely to pending when unavailable.
- Mid-session secondmate liveness is not implemented.
- OpenCode 1.18.4 can accept Enter while busy without clearing the composer.
  The tmux backend has a busy-queue fallback, but Herdr still reports this case as submit pending and needs a separate adapter fix.
- Only tmux and Herdr can host the away-mode supervisor terminal.

## Regression entry points

```sh
tests/fm-backend-herdr.test.sh
tests/fm-backend-herdr-smoke.test.sh
tests/fm-backend-herdr-prune-safety-e2e.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-herdr-nm-visibility.test.sh
tests/fm-herdr-nm-visibility-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, projection, event, and lifecycle evidence without task-specific chronology.
