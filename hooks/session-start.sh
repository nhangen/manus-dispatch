#!/usr/bin/env bash
# SessionStart hook: surface any Manus tasks that completed since last session.
#
# Walks the state dir, calls manus-client.sh result for each task that hasn't
# been notified yet, and emits additionalContext so Claude opens the session
# already knowing what came back. Marks notified_at on each surfaced task so
# the next SessionStart doesn't re-fire.
#
# Skips silently when:
# - no state dir
# - no running or unsurfaced-completed tasks
# - manus-client.sh missing or no API key configured (no point alarming)

set -u

: "${HOME:?HOME must be set}"

STATE_DIR="$HOME/.config/manus-dispatch/state"
CLIENT="${CLAUDE_PLUGIN_ROOT:-$HOME/ML-AI/claude/manus-dispatch}/scripts/manus-client.sh"

# Bail quietly if not set up
[ -d "$STATE_DIR" ] || exit 0
[ -x "$CLIENT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Find candidates: status != "stopped", OR status == "stopped" without notified_at.
candidates=()
for f in "$STATE_DIR"/*.json; do
  [ -f "$f" ] || continue
  needs_check=$(jq -r '
    if .status != "stopped" then "yes"
    elif (.notified_at // null) == null then "yes"
    else "no" end
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

  # Best-effort fetch; ignore failures (bad key, network, rate limit).
  if ! "$CLIENT" result "$task_id" >/dev/null 2>&1; then
    continue
  fi

  status=$(jq -r '.status // "unknown"' "$f")
  if [ "$status" = "stopped" ]; then
    title=$(jq -r '.title // .query // "untitled"' "$f")
    note=$(jq -r '.obsidian_note // ""' "$f")
    if [ -n "$note" ] && [ "$note" != "null" ]; then
      completed_lines+=("• ${title} → ${note}")
    else
      completed_lines+=("• ${title} (task ${task_id})")
    fi
    # Mark notified so we don't surface it again
    tmp=$(mktemp -t manus-state.XXXXXX)
    jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.notified_at = $t' "$f" > "$tmp" \
      && mv "$tmp" "$f"
  else
    still_running=$((still_running + 1))
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
    echo "Still running: ${still_running} task(s). Run /manus-dispatch:status for details."
  fi
} | jq -Rs '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: .
  }
}'
