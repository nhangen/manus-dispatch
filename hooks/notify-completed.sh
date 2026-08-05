#!/usr/bin/env bash
# Surface any Manus tasks that completed since the last fire of this hook.
#
# Wired into both SessionStart (catches results when you come back) and Stop
# (catches results that arrive mid-session). Idempotent: each surfaced task
# is marked .notified_at so subsequent fires are silent until something new
# completes.
#
# Walks the state dir, calls manus-client.sh result for each task that hasn't
# been notified yet, and emits additionalContext so Claude sees what came
# back without you having to run /manus-dispatch:manus-status manually.
#
# Skips silently when:
# - no state dir
# - no running or unsurfaced-completed tasks
# - manus-client.sh missing, jq missing, or no API key configured

set -u

# Read the hook event JSON from stdin (non-blocking) to detect which event
# fired — Claude Code expects hookSpecificOutput.hookEventName to match.
HOOK_EVENT="SessionStart"
if [ ! -t 0 ]; then
  hook_input=$(cat 2>/dev/null || true)
  if [ -n "$hook_input" ] && command -v jq >/dev/null 2>&1; then
    evt=$(printf '%s' "$hook_input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
    [ -n "$evt" ] && HOOK_EVENT="$evt"
  fi
fi

: "${HOME:?HOME must be set}"

STATE_DIR="$HOME/.config/manus-dispatch/state"
CLIENT="${CLAUDE_PLUGIN_ROOT:-$HOME/ML-AI/claude/manus-dispatch}/scripts/manus-client.sh"

# Bail quietly if not set up
[ -d "$STATE_DIR" ] || exit 0
[ -x "$CLIENT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Find candidates: any task not yet surfaced (no notified_at). Once a task has
# been surfaced it is done — regardless of its status — so it is never a
# candidate again. Gating purely on notified_at (rather than "status !=
# stopped") is what stops a terminal-but-non-stopped task, e.g. one that ended
# in `error`, from being re-selected on every hook fire forever.
candidates=()
for f in "$STATE_DIR"/*.json; do
  [ -f "$f" ] || continue
  needs_check=$(jq -r '
    if (.notified_at // null) == null then "yes" else "no" end
  ' "$f" 2>/dev/null || echo "no")
  [ "$needs_check" = "yes" ] && candidates+=("$f")
done

[ "${#candidates[@]}" -gt 0 ] || exit 0

# Pull each one; collect completions to surface.
completed_lines=()
still_running=0
for f in "${candidates[@]}"; do
  task_id=$(jq -r '.task_id' "$f" 2>/dev/null)
  [ -n "$task_id" ] && [ "$task_id" != "null" ] || continue

  # Best-effort fetch. Classify on the status the client itself just fetched
  # (its stdout JSON), NOT on the state file: manus-client.sh only writes
  # .status back for `error` and text-bearing results, so a `waiting` task or
  # one cancelled in the Manus UI (`stopped` with no assistant text) keeps a
  # stale `running` in its state file. Reading the state file there would send
  # those tasks down the `running` arm and re-poll them forever — the exact
  # loop this hook is meant to avoid. Ignore fetch failures (bad key, network,
  # rate limit): notified_at stays unset, so the task is retried next fire.
  resp=$("$CLIENT" result "$task_id" 2>/dev/null) || continue
  status=$(printf '%s' "$resp" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
  title=$(jq -r '.title // .query // "untitled"' "$f")

  # `running` and `waiting` are both non-terminal: a waiting task resumes once
  # the user supplies input and then completes, so neither may be marked
  # notified (that would suppress the eventual completion). Only genuinely
  # terminal statuses — `stopped`, `error`, anything unrecognized — are
  # surfaced once and marked notified below.
  case "$status" in
    running)
      still_running=$((still_running + 1))
      continue
      ;;
    waiting)
      # Announce "needs input" once (tracked separately from notified_at) so
      # we neither spam it every fire nor lose the completion notice later.
      seen=$(jq -r '.waiting_notified_at // ""' "$f")
      if [ -z "$seen" ] || [ "$seen" = "null" ]; then
        completed_lines+=("• ${title} — waiting for input (task ${task_id})")
        tmp=$(mktemp -t manus-state.XXXXXX)
        if jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.waiting_notified_at = $t' "$f" > "$tmp"; then
          mv "$tmp" "$f"
        else
          rm -f "$tmp"
          echo "notify-completed: failed to mark $f waiting-notified" >&2
        fi
      fi
      continue
      ;;
    stopped)
      # An attached-file deliverable is easy to miss — the summary text reads as
      # complete while the payload sits behind `download` (issue #6). Say so.
      att=$(printf '%s' "$resp" | jq -r '.attachment_count // 0' 2>/dev/null || echo 0)
      att_note=""
      [ "$att" -gt 0 ] 2>/dev/null && att_note=" — 📎 ${att} file(s), fetch: manus-client.sh download ${task_id}"
      note=$(jq -r '.obsidian_note // ""' "$f")
      if [ -n "$note" ] && [ "$note" != "null" ]; then
        completed_lines+=("• ${title} → ${note}${att_note}")
      else
        completed_lines+=("• ${title} (task ${task_id})${att_note}")
      fi
      ;;
    *)
      completed_lines+=("• ${title} — ended: ${status} (task ${task_id})")
      ;;
  esac

  # Mark notified so a terminal task is never surfaced or re-polled again.
  # Guard the write: on jq failure, don't leave a leaked temp file behind and
  # don't silently drop the mark (which would re-surface the task next fire).
  tmp=$(mktemp -t manus-state.XXXXXX)
  if jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.notified_at = $t' "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    echo "notify-completed: failed to mark $f notified" >&2
  fi
done

[ "${#completed_lines[@]}" -gt 0 ] || [ "$still_running" -gt 0 ] || exit 0

# Build additionalContext payload.
{
  echo "## Manus tasks"
  echo
  if [ "${#completed_lines[@]}" -gt 0 ]; then
    echo "Completed since last session:"
    printf '%s\n' "${completed_lines[@]}"
    echo
  fi
  if [ "$still_running" -gt 0 ]; then
    echo "Still running: ${still_running} task(s). Run /manus-dispatch:manus-status for details."
  fi
} | jq -Rs --arg evt "$HOOK_EVENT" '{
  hookSpecificOutput: {
    hookEventName: $evt,
    additionalContext: .
  }
}'
