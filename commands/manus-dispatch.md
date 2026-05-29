---
name: manus-dispatch
description: Dispatch a long-running research task to the Manus AI agent platform. Returns immediately with a task id; poll later with /manus-dispatch:status. Usage: /manus-dispatch <research query>
---

# Dispatch a research task to Manus

The user invoked this command with a query: `$ARGUMENTS`

## What to do

1. Surface the cost estimate to the user as advisory text (this is a soft gate — research tasks typically cost 500–900 credits ≈ $2.50–$4.50). If the query is empty or obviously test-y, ask the user to confirm before dispatching.

2. Run the create call:

```bash
~/.claude/plugins/cache/nhangen/manus-dispatch/0.1.0/scripts/manus-client.sh create "$ARGUMENTS"
```

3. Parse the JSON response and report back to the user:
   - `task_id` (so they can reference it later)
   - `task_url` (so they can watch progress in the Manus web UI)
   - State file path
   - A note that they should run `/manus-dispatch:status` later to pull the result

## Error handling

If the script exits non-zero, the error message will be on stderr. Surface it to the user verbatim — do NOT retry automatically. Common cases:
- No API key: tell the user to create `~/.config/manus-dispatch/config.toml` from the example, or set `MANUS_API_KEY` in their shell
- `permission_denied`: their API key is wrong
- `rate_limited`: the script already backs off; if surfaced, their account is throttled

## Notes

- This does NOT poll. The dispatch is one HTTP call and returns. Manus does the long-running work in the background.
- Cost is real: every invocation burns credits. Do not auto-fire on conversational mentions of "research" — only when the user explicitly invokes this command.
- State file at `~/.config/manus-dispatch/state/<task_id>.json` is the source of truth between sessions.
