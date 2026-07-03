#!/usr/bin/env bash
#
# Regression test for hooks/notify-completed.sh.
#
# Pins the fix in PR #3: the hook must classify each task on the status the
# client just fetched (its stdout JSON), NOT on the possibly-stale `.status`
# in the state file. The load-bearing case is a task cancelled in the Manus UI
# (fresh status `stopped`, no assistant text) or a `waiting` task: the client
# never writes those statuses back to the state file, so a hook that read the
# state file would see a stale `running`, count it as in-flight, never mark it
# notified, and re-poll it on every fire forever — the exact loop the PR fixes.
#
# The test invokes the REAL hook against a temp HOME + a stubbed client
# (per stub-cli-argv-validation the stub exits non-zero on unexpected argv).
# It fails when the fix is reverted: the buggy hook reads the stale `running`
# from the state file, so the UI-cancelled task never gets notified_at and
# reappears as a candidate on the second fire.
#
# No dependencies beyond bash + jq (both already required by the hook).
# Usage: tests/notify-completed-test.sh   (exit 0 = pass, non-zero = fail)

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/notify-completed.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d -t manus-hooktest.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
SD="$HOME/.config/manus-dispatch/state"
mkdir -p "$SD"

# --- Stub client: emits the *fresh* status per task on stdout ----------------
export CLAUDE_PLUGIN_ROOT="$TMP/plugin"
mkdir -p "$CLAUDE_PLUGIN_ROOT/scripts"
export MANUS_STUB_STATUS_DIR="$TMP/fresh"
mkdir -p "$MANUS_STUB_STATUS_DIR"
cat > "$CLAUDE_PLUGIN_ROOT/scripts/manus-client.sh" <<'STUB'
#!/usr/bin/env bash
set -u
cmd="${1:-}"; id="${2:-}"
if [ "$cmd" != "result" ] || [ -z "$id" ]; then
  echo "stub-client: unexpected argv: $*" >&2
  exit 3
fi
st=$(cat "$MANUS_STUB_STATUS_DIR/$id" 2>/dev/null || echo "unknown")
jq -nc --arg id "$id" --arg s "$st" \
  '{ok:true, task_id:$id, status:$s, result:"", obsidian_note:null}'
STUB
chmod +x "$CLAUDE_PLUGIN_ROOT/scripts/manus-client.sh"

# --- Fixtures: state file carries a STALE `running`; stub carries fresh -------
# task_id | fresh status returned by the stub
mkfixture() {
  local id="$1" fresh="$2"
  printf '%s' "$fresh" > "$MANUS_STUB_STATUS_DIR/$id"
  jq -nc --arg id "$id" --arg t "Task $id" \
    '{task_id:$id, title:$t, query:$t, status:"running", started_at:"2026-07-01T00:00:00Z"}' \
    > "$SD/$id.json"
}
mkfixture ERRTASK error     # errored (state stale-running, fresh error)
mkfixture CANCEL  stopped   # UI-cancelled: fresh stopped, no text  <-- key case
mkfixture WAIT    waiting   # awaiting input
mkfixture RUN     running   # genuinely running

fire() { printf '{"hook_event_name":"Stop"}' | bash "$HOOK"; }
notified() { jq -r '.notified_at // "null"' "$SD/$1.json"; }
waiting_notified() { jq -r '.waiting_notified_at // "null"' "$SD/$1.json"; }

fails=0
check() { # check <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"; fails=$((fails + 1))
  fi
}
check_ne() { # check_ne <desc> <actual> <not-expected>
  if [ "$2" != "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (got '$2', should not equal '$3')"; fails=$((fails + 1))
  fi
}

echo "== fire 1 =="
OUT1=$(fire)
echo "$OUT1" | jq empty 2>/dev/null && echo "  ok: fire 1 emitted valid JSON" \
  || { echo "  FAIL: fire 1 output is not valid JSON"; fails=$((fails + 1)); }

# Terminal tasks marked notified (the fix). On buggy code CANCEL reads stale
# `running` from the state file and is NEVER marked -> this is the regression.
check_ne "ERRTASK marked notified"          "$(notified ERRTASK)" "null"
check_ne "CANCEL (UI-cancel) marked notified" "$(notified CANCEL)" "null"
# Non-terminal tasks NOT marked notified (must still surface on completion).
check    "WAIT not marked notified"          "$(notified WAIT)" "null"
check    "RUN not marked notified"           "$(notified RUN)"  "null"
check_ne "WAIT got waiting_notified_at"      "$(waiting_notified WAIT)" "null"

# still_running counts only genuinely-running tasks (RUN) — not WAIT, not terminal.
SR1=$(echo "$OUT1" | jq -r '.hookSpecificOutput.additionalContext' | grep -oE 'Still running: [0-9]+' | grep -oE '[0-9]+' || echo "")
check "still_running = 1 (only RUN)" "${SR1:-none}" "1"

echo "== fire 2 (no recurrence) =="
OUT2=$(fire)
# Candidate = a state file with no notified_at. ERRTASK/CANCEL must no longer
# qualify; on buggy code CANCEL still would (regression tripwire).
cand2=$(for f in "$SD"/*.json; do
  [ "$(jq -r 'if (.notified_at // null)==null then "y" else "n" end' "$f")" = y ] && basename "$f" .json
done | sort | tr '\n' ' ')
check "fire 2 candidates are exactly 'RUN WAIT '" "$cand2" "RUN WAIT "
# CANCEL surfaced once, silent on fire 2:
if echo "$OUT2" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q CANCEL; then
  echo "  FAIL: CANCEL re-surfaced on fire 2 (loop not fixed)"; fails=$((fails + 1))
else
  echo "  ok: CANCEL not re-surfaced on fire 2"
fi
# WAIT announced once, not repeated on fire 2:
if echo "$OUT2" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "waiting for input"; then
  echo "  FAIL: WAIT 'waiting for input' repeated on fire 2 (spam)"; fails=$((fails + 1))
else
  echo "  ok: WAIT notice not repeated on fire 2"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: all checks green"
  exit 0
else
  echo "FAIL: $fails check(s) failed"
  exit 1
fi
