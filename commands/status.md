---
name: status
description: Pull current status (and result if completed) for one or all running Manus tasks. Usage: /manus-dispatch:status [task_id]
---

# Pull Manus task status

The user invoked this command with arguments: `$ARGUMENTS`

## What to do

### Case 1: a task_id was provided

Run both status and result against the given task_id:

```bash
~/.claude/plugins/cache/nhangen/manus-dispatch/0.1.0/scripts/manus-client.sh result "$ARGUMENTS"
```

The `result` subcommand returns status + assistant text in one call (it fetches a larger message page than `status` alone). Report the status; if the result text is non-empty, surface it back into the conversation so the user can read or have you synthesize it.

### Case 2: no task_id (poll all running tasks)

Iterate over every state file with `status: running` in `~/.config/manus-dispatch/state/`:

```bash
for f in ~/.config/manus-dispatch/state/*.json; do
  [ -f "$f" ] || continue
  s=$(jq -r '.status' "$f")
  id=$(jq -r '.task_id' "$f")
  if [ "$s" = "running" ]; then
    ~/.claude/plugins/cache/nhangen/manus-dispatch/0.1.0/scripts/manus-client.sh result "$id"
  fi
done
```

Group the output:
- **Newly completed**: list task title, surface the result text
- **Still running**: list task_id + title + elapsed time (compute from `started_at` in the state file)
- **Failed**: surface the error code/message

If no state files exist, tell the user there are no tracked tasks and suggest `/manus-dispatch <query>`.

## Notes

- Polling is on-demand only. No background process.
- Once a result is fetched it's written into the state file at `.result` — subsequent calls don't re-fetch the full message log.
- If `obsidian_enabled = true` in config, completed results should also be written to the Obsidian vault. (Phase 3 — not yet implemented in the client.)
