# manus-dispatch

Dispatch long-running research tasks to the [Manus](https://manus.im) AI agent
platform from Claude Code via slash command. Manus does the heavy autonomous
research; Claude orchestrates and synthesizes the result back into your session.

## Slash commands

- `/manus-dispatch <query>` — dispatch a research task. Returns immediately
  with a task id; no background polling.
- `/manus-dispatch:status [task_id]` — pull status (and result if completed)
  for one task, or for every still-running task if no id is given.
- `/manus-dispatch:cancel <task_id>` — best-effort stop.

The plugin also ships `scripts/manus-client.sh`, which you can call directly
outside Claude Code: `manus-client.sh create|status|result|cancel`.

## Auto-notify on completed tasks (v0.1.1)

Two hooks point at the same script `hooks/notify-completed.sh`:

- **`SessionStart`** — catches tasks that completed while Claude Code was
  closed. Fires once when you open a new session.
- **`Stop`** — catches tasks that complete mid-conversation. Fires after
  every Claude response.

Both walk `~/.config/manus-dispatch/state/`, call `manus-client.sh result`
on any task that hasn't been surfaced yet, and emit `additionalContext`:

```
## Manus tasks

Completed since last session:
• <task title> → <obsidian note path>
• <task title> (task <id>)

Still running: N task(s). Run /manus-dispatch:status for details.
```

Cost: zero extra Claude turns (hooks run local bash, not model
invocations). Each surfaced task is marked `notified_at` so subsequent
fires are silent until something new completes. Stop hook bails in a
fork+jq+ls when nothing's dispatched. Cross-platform — pure bash, no
scheduler, no public endpoint.

Caveat: per Claude Code hook semantics, `additionalContext` is advisory
— Claude is free to ignore it. In practice the agent reads it as session
context. Do not rely on it for hard enforcement.

## Why

Manus runs autonomous research tasks (browse, read, synthesize, write) that
take minutes. Claude Code is a good driver for orchestrating them and a poor
host for blocking on them. This plugin keeps Claude responsive: dispatch,
get a task id, do other work, pull the result later.

## Cost model

Manus is credit-based (~$0.005/credit). A research task typically burns
500–900 credits ($2.50–$4.50). The plugin only fires on explicit slash
command invocation — there is no auto-dispatch.

Auth is API-key only in this plugin; Manus also supports OAuth2 in v2, but
for a personal Claude Code plugin the key is simpler. See
<https://open.manus.ai/docs/v2/oauth> if you need scoped tokens.

## Setup

1. Install via the `nhangen-tools` marketplace:
   ```bash
   claude plugin marketplace add nhangen/claude-plugins
   claude plugin install manus-dispatch@nhangen-tools
   ```
2. Get an API key from <https://open.manus.ai/docs/v2/authentication>.
3. Create config:
   ```bash
   mkdir -p ~/.config/manus-dispatch
   cp <plugin>/config/manus.example.toml ~/.config/manus-dispatch/config.toml
   $EDITOR ~/.config/manus-dispatch/config.toml
   ```
4. Either set `api_key` directly, set `api_key_cmd` to a keychain helper, or
   export `MANUS_API_KEY` in your shell — env wins.

## Obsidian filing (optional)

Set `obsidian_enabled = true` and `obsidian_path = "/path/to/vault"` in the
config. When a result is fetched, it's written to
`<vault>/Projects/Research/manus/<YYYY-MM-DD>-<slug>.md` with frontmatter,
and a link is appended under `## Research` in today's daily note
(`<vault>/Daily/<YYYY-MM-DD>.md`).

If `obsidian_enabled = true` and `obsidian_path` is empty or non-existent,
the plugin aborts with a diagnostic (exit 3) — no silent fall-through to
disabled. See [`enum-config-typo-fallback`](https://github.com/nhangen/manus-dispatch).

## Endpoints

Targets the Manus v2 API:

| Subcommand | Method + path | Notes |
|---|---|---|
| `create` | `POST /v2/task.create` | `{"message":{"content":[{"type":"text","text":"..."}]}}` |
| `status` | `GET /v2/task.listMessages` | parses `agent_status` from latest `status_update` event |
| `result` | `GET /v2/task.listMessages` | same, plus extracts most recent `assistant_message.content` |
| `cancel` | `POST /v2/task.stop` | marks state file `cancelled_at` |

`agent_status` ∈ `{running, stopped, waiting, error}`. `stopped` is terminal
for both successful completion and user cancellation — the state file's
`cancelled_at` field distinguishes them.

## State

Runtime state lives outside the plugin tree at
`~/.config/manus-dispatch/state/<task_id>.json`. One file per task, persisted
across sessions. Polling is on-demand only — no background processes.

## Security

- API key passed via a temp header file (`curl -H @file`, mode 600,
  trap-cleanup) — never on the command line or in process args.
- `curl` stderr is scrubbed to drop any `x-manus-api-key` / `Authorization`
  lines before surfacing.
- `rate_limited` errors back off exponentially (1s, 2s, 4s; max 3 attempts).

## Status

v0.1.1 — CLI client, three slash commands, optional Obsidian filing, config
validation, and SessionStart auto-notify hook are all functional and
smoke-tested against the live Manus v2 API.

Not yet implemented:
- PreToolUse hook for hard cost-gating (currently soft via slash-command
  invocation only)
- Codex integration
- Webhook receiver (polling is on-demand + SessionStart only)

## License

MIT
