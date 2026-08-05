---
name: manus-status
description: Pull current status (and result if completed) for one or all running Manus tasks. Usage: /manus-dispatch:manus-status [task_id]
---

# Pull Manus task status

The user invoked this command with arguments: `$ARGUMENTS`

## What to do

### Case 1: a task_id was provided

Run both status and result against the given task_id:

```bash
"${CLAUDE_PLUGIN_ROOT:-$HOME/ML-AI/claude/manus-dispatch}/scripts/manus-client.sh" result "$ARGUMENTS"
```

The `result` subcommand returns status + assistant text in one call (it fetches a larger message page than `status` alone). Report the status; if the result text is non-empty, surface it back into the conversation so the user can read or have you synthesize it.

**If `attachment_count` is greater than zero, the file is the deliverable — the summary text is not the whole answer.** Download it and read it before reporting:

```bash
"${CLAUDE_PLUGIN_ROOT:-$HOME/ML-AI/claude/manus-dispatch}/scripts/manus-client.sh" download "$ARGUMENTS"
```

That writes each attachment under `~/.config/manus-dispatch/files/<task_id>/` and prints the local paths. Read them and synthesize from the file contents, not from the summary. Pass `--out DIR` when the user wants them somewhere specific.

### Case 2: no task_id (poll all running tasks)

Iterate over every state file with `status: running` in `~/.config/manus-dispatch/state/`:

```bash
for f in ~/.config/manus-dispatch/state/*.json; do
  [ -f "$f" ] || continue
  s=$(jq -r '.status' "$f")
  id=$(jq -r '.task_id' "$f")
  if [ "$s" = "running" ]; then
    "${CLAUDE_PLUGIN_ROOT:-$HOME/ML-AI/claude/manus-dispatch}/scripts/manus-client.sh" result "$id"
  fi
done
```

Group the output:
- **Newly completed**: list task title, surface the result text, and note any `attachment_count` — download and read those files (see Case 1) rather than reporting the summary alone
- **Still running**: list task_id + title + elapsed time (compute from `started_at` in the state file)
- **Failed**: surface the error code/message

If no state files exist, tell the user there are no tracked tasks and suggest `/manus-dispatch <query>`.

## Notes

- Polling is on-demand only. No background process.
- Once a result is fetched it's written into the state file at `.result` — subsequent calls don't re-fetch the full message log.
- If `obsidian_enabled = true` in config, completed results are also written to the Obsidian vault (see `file_to_obsidian` in `manus-client.sh`, wired into `cmd_result`). The note lists attachment filenames but does not embed their URLs — Manus signs them with an expiry, so re-run `download` instead of reusing an old link.
- `files <task_id>` lists attachments without downloading them, if you just need names and types.
