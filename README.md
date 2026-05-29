# manus-research

Dispatch long-running research tasks to the [Manus](https://manus.im) AI agent
platform from Claude Code via slash command. Manus does the heavy autonomous
research; Claude orchestrates and synthesizes the result back into your session.

## What it does

- `/manus-research <query>` — dispatches a research task to Manus, returns a
  task id immediately. No background polling.
- `/manus-status [task-id]` — pulls status for all running tasks (or one by id);
  surfaces completed results back into the conversation.
- `/manus-cancel <task-id>` — cancels a running task.

Optional Obsidian filing writes completed results to
`<vault>/Projects/Research/manus/<YYYY-MM-DD>-<slug>.md` when configured.

## Why

Manus runs autonomous research tasks (browse, read, synthesize, write) that
take minutes. Claude Code is a good driver for orchestrating them and a poor
host for blocking on them. This plugin keeps Claude responsive: dispatch,
get a task id, do other work, pull the result later.

## Cost model

Manus is credit-based (~$0.005/credit). A research task typically burns
500–900 credits ($2.50–$4.50). The plugin only fires on explicit slash
command invocation — there is no auto-dispatch.

OAuth is not supported by Manus as of May 2026 (Q3 2026 roadmap). Auth is
API-key only.

## Setup

1. Get an API key from <https://open.manus.im/docs> (Authentication section).
2. `mkdir -p ~/.config/manus-research`
3. Copy `config/manus.example.toml` to `~/.config/manus-research/config.toml`
   and fill in your key.
4. Install the plugin via the `nhangen-tools` marketplace.

## Status

v0.1.0 — early. Phase 1 (CLI client + scaffolding) implemented; slash commands
and Obsidian filing land in v0.2/v0.3.

## License

MIT
