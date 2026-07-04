---
name: cancel
description: Cancel a running Manus task by id. Usage: /manus-dispatch:cancel <task_id>
---

# Cancel a Manus task

The user invoked this command with arguments: `$ARGUMENTS`

## What to do

1. If no task_id was provided, list currently-running tasks (from state files) and ask the user which to cancel.

2. Run the cancel call:

```bash
"${CLAUDE_PLUGIN_ROOT:-$HOME/ML-AI/claude/manus-dispatch}/scripts/manus-client.sh" cancel "$ARGUMENTS"
```

3. Report the result. On success the script updates the state file to `status: stopped` and records `cancelled_at`.

## Notes

- Manus uses the same `stopped` agent_status for "completed normally" and "user-cancelled" — the state file's `cancelled_at` field is how the plugin distinguishes them.
- Cancellation is best-effort: Manus may have already completed work by the time the stop request lands. Run `/manus-dispatch:manus-status <id>` afterward to see the final state.
- Credits already consumed cannot be refunded; cancel saves only credits from work not yet done.
