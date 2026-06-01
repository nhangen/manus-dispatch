# manus-dispatch-failures

User-triggered writer to `CEO/inbox.md` for failed Manus tasks.

## Schedule

Event-driven, not cron. Fires inside `scripts/manus-client.sh result` when a
task's `agent_status` is `error`. The result call itself runs only when the
user has Claude Code open (SessionStart/Stop hook in `hooks/notify-completed.sh`)
or runs `/manus-dispatch:status` manually.

## Outputs

- `CEO/inbox.md` — one `- [ ] Manus task <id> ... failed: <reason>` line per
  failed task. Idempotent: re-firing the result call for the same task does
  not re-append (gated by `.failure_reported_at` on the per-task state file
  at `~/.config/manus-dispatch/state/<task_id>.json`).

That's it. No `alerts/`, no `log/`, no `reports/`. Failures are per-task
transient events, not a sustained condition — a single inbox line per
distinct failure is the correct state-machine shape.

## State machine

- Initial: `.failure_reported_at` is absent on the state file.
- Transition: `agent_status == "error"` observed and registry gate passes →
  append inbox line, set `.failure_reported_at = <UTC timestamp>`.
- Terminal: no further inbox writes for this task. Subsequent
  `notify-completed.sh` fires will see the timestamp and skip.

## Registry entry

This writer requires a registry entry in `CEO/registry.json` to be active.
Without the entry, `manus-client.sh` emits a diagnostic on stderr and skips
the inbox write — failures are still tracked on the per-task state file but
do not reach the vault.

Add to `CEO/registry.json` (via the claude-ceo repo):

```json
{
  "name": "manus-dispatch-failures",
  "description": "Append failed Manus task notifications to CEO/inbox.md (one line per failed task, idempotent).",
  "trigger": "event",
  "schedule": "",
  "model": "",
  "preflight": "none",
  "tier": "low-stakes write",
  "status": "active",
  "bin": "",
  "runner": "script",
  "script": "~/ML-AI/claude/manus-dispatch/scripts/manus-client.sh",
  "skill": "",
  "out_pattern": "CEO/inbox.md",
  "inputs": null,
  "requires": null,
  "file": "playbooks/manus-dispatch-failures.md"
}
```

## Why this isn't a cron / daemon writer

The May 2026 disk-monitor incident was a cron writer appending to
`CEO/inbox/disk-alert.md` every hour. This writer is fundamentally different:
it only runs when the user already has Claude Code in the foreground (hook
fires) or invokes `/manus-dispatch:status` directly. It cannot generate
unbounded background noise.

## Origin

Issue [nhangen/manus-dispatch#1](https://github.com/nhangen/manus-dispatch/issues/1)
(2026-06-01). Part of the LLM Tools Integration plan (vault:
`Plans/2026-05-31-llm-tools-integration.md`, T7).
