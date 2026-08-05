# manus-dispatch

Dispatch long-running research tasks to the [Manus](https://manus.im) AI agent
platform from Claude Code via slash command. Manus does the heavy autonomous
research; Claude orchestrates and synthesizes the result back into your session.

## Slash commands

- `/manus-dispatch <query>` — dispatch a research task. Returns immediately
  with a task id; no background polling.
- `/manus-dispatch:manus-status [task_id]` — pull status (and result if completed)
  for one task, or for every still-running task if no id is given.
- `/manus-dispatch:cancel <task_id>` — best-effort stop.

The plugin also ships `scripts/manus-client.sh`, which you can call directly
outside Claude Code: `manus-client.sh create|status|result|files|download|cancel`.
When a task's deliverable is an attached file rather than inline text, `files`
lists the attachments and `download` fetches them — see
[File deliverables](#file-deliverables).

## Auto-notify on completed tasks

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

Still running: N task(s). Run /manus-dispatch:manus-status for details.
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

Set `obsidian_enabled = true` in `~/.config/manus-dispatch/config.toml`.
Vault path is read from the `nhangen/obsidian` plugin's local config
(`~/.claude/plugins/cache/nhangen/obsidian/<latest>/obsidian.local.md`,
`vault_path:` frontmatter) — no hardcoded path in this plugin.

### On success

When `cmd_result` fetches a completed task:

1. A research note is written to
   `<vault>/Projects/Research/manus/<YYYY-MM-DD>-<slug>.md` with frontmatter.
2. Today's daily note at `<vault>/Daily/<YYYY-MM-DD>.md` gets an entry under
   `## Research` (section created if absent; daily file created with
   `date:`/`tags:[daily]` frontmatter if absent):

   ```markdown
   - [<title>](../Projects/Research/manus/<date>-<slug>.md) — task `<id>` — [Manus](<url>) <!-- manus:<id> -->
     <first-200-chars of result, headings/code stripped>
   ```

   Entries are deduped by the `<!-- manus:<id> -->` marker. When the task has
   attachments, the daily-note line ends with `📎 <n> file(s): <names>` and the
   research note gains an `## Attachments` section listing the filenames plus
   the `download` command to fetch them. Filenames only — the signed URLs
   expire, so a link pasted into the vault would rot.

### On failure

When `agent_status == "error"`, the plugin writes one line to
`<vault>/CEO/inbox.md`:

```markdown
- [ ] Manus task `<id>` (<title>) failed: <reason> — [Manus](<url>)
```

Per `ceo-automated-writers-are-playbooks`, this writer requires a
`manus-dispatch-failures` entry in the vault's `CEO/registry.json`. Without
it the inbox write is skipped (diagnostic on stderr) and the failure is
still tracked on the per-task state file. See
[`docs/playbooks/manus-dispatch-failures.md`](docs/playbooks/manus-dispatch-failures.md)
for the registry JSON to copy into `claude-ceo`.

Idempotency: one inbox line per task ever (gated by `.failure_reported_at`
on the state file). Re-fetches are no-ops.

### Failure modes

- `obsidian_enabled = true` + plugin not installed → diagnostic, filing
  skipped, task JSON still returned.
- Plugin installed + `vault_path:` missing/invalid → same.
- Success path is independent of `CEO/registry.json` — only the failure
  path is gated by the registry entry.

## Endpoints

Targets the Manus v2 API:

| Subcommand | Method + path | Notes |
|---|---|---|
| `create` | `POST /v2/task.create` | `{"message":{"content":[{"type":"text","text":"..."}]}}` |
| `status` | `GET /v2/task.listMessages` | parses `agent_status` from latest `status_update` event |
| `result` | `GET /v2/task.listMessages` | same, plus extracts most recent `assistant_message.content` and its `attachments[]` |
| `files` | `GET /v2/task.listMessages` | lists `assistant_message.attachments[]` (filename, content type, signed URL) |
| `download` | `GET /v2/task.listMessages` + CDN GET | fetches each attachment to `--out DIR` (default `~/.config/manus-dispatch/files/<task_id>`) |
| `cancel` | `POST /v2/task.stop` | marks state file `cancelled_at` |

`agent_status` ∈ `{running, stopped, waiting, error}`. `stopped` is terminal
for both successful completion and user cancellation — the state file's
`cancelled_at` field distinguishes them.

### File deliverables

Manus often returns the real payload — a table, CSV, report, generated code —
as an **attachment** rather than inline text, with the assistant message
reduced to "the full table is attached." Those attachments arrive on
`assistant_message.attachments[]` in the same `listMessages` response, each
with a pre-signed `manuscdn.com` URL:

```json
{ "type": "file", "filename": "kinematic_specs.md",
  "content_type": "text/markdown; charset=utf-8",
  "url": "https://private-us-east-1.manuscdn.com/sessionFile/...?Policy=...&Signature=..." }
```

Two consequences worth knowing:

- **The URL takes no API key** — it carries its own CloudFront signature, and
  `download` deliberately omits the `x-manus-api-key` header so the key never
  reaches a third-party host. (Sending the key is what makes hand-rolled
  `curl` attempts against guessed API paths return 401 — there is no
  attachment endpoint to authenticate against.)
- **The URL expires** (roughly a month from generation). Nothing caches it:
  the state file and the Obsidian note record filenames only, and `files`
  re-fetches a fresh link each call. An expired link surfaces as `HTTP 403`
  with a re-run instruction, not a generic failure.

`result`, `status`, and the auto-notify hook all report `attachment_count` so a
file deliverable can't look complete while the payload is missing. Because that
silent omission is the whole bug, the retrieval path refuses to guess:

- **An unparseable response is an error, not "no attachments."** If the JSON
  can't be read, `files`/`download`/`result` exit non-zero with a diagnostic
  rather than reporting `count: 0`.
- **A transfer that dies mid-body is a failure even at HTTP 200.** `curl`'s exit
  status is checked alongside the status code; a partial file is discarded, not
  counted. `download` exits non-zero if any attachment failed, and reports
  `failed: <n>` while still saving the ones that succeeded.
- **`download` overwrites its own previous output** rather than accumulating
  `-2`, `-3` copies per poll. Two attachments that genuinely share a filename
  within one response are suffixed so neither is lost.
- **One page of messages is read (`limit=50`).** If nothing is found and the log
  is longer than that page, `has_more` triggers a warning instead of an implied
  "there are none."

## State

Runtime state lives outside the plugin tree at
`~/.config/manus-dispatch/state/<task_id>.json`. One file per task, persisted
across sessions. Polling is on-demand only — no background processes.

## Security

- API key passed via a temp header file (`curl -H @file`, mode 600,
  trap-cleanup) — never on the command line or in process args.
- `curl` stderr is scrubbed to drop any `x-manus-api-key` / `Authorization`
  lines before surfacing.
- Attachment downloads run **without** the auth header — the CDN URL is
  pre-signed, so sending the key would hand it to a host that doesn't need it.
- API-supplied filenames are flattened to a safe basename before writing, so a
  crafted `../../` filename can't escape the `--out` directory.
- `rate_limited` errors back off exponentially (1s, 2s, 4s; max 3 attempts).

## Status

v0.1.6 — CLI client, three slash commands, attachment retrieval
(`files`/`download`), optional Obsidian filing, config validation, and
SessionStart+Stop auto-notify hooks are all functional and smoke-tested against
the live Manus v2 API.

Tests: `tests/notify-completed-test.sh` (hook classification),
`tests/attachments-test.sh` (attachment listing/download against a local stub
of both the API and the CDN).

Not yet implemented:
- PreToolUse hook for hard cost-gating (currently soft via slash-command
  invocation only)
- Codex integration
- Webhook receiver (polling is on-demand + SessionStart only)

## License

MIT
