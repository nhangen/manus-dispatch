#!/usr/bin/env bash
# manus-client.sh — thin curl wrapper for the Manus v2 API.
#
# Endpoints (base https://api.manus.ai):
#   POST /v2/task.create        body: {"message":{"content":[{"type":"text","text":"<query>"}]}}
#                               resp: {ok, request_id, task_id, task_title, task_url, share_url}
#   GET  /v2/task.listMessages  ?task_id=<id>&order=desc&limit=N
#                               returns {ok, messages, has_more, next_cursor}.
#                               status_update events carry agent_status ∈
#                                 {running, stopped, waiting, error}.
#                               'stopped' is terminal (success or user-cancel).
#                               assistant_message events carry the final reply.
#   POST /v2/task.stop          body: {"task_id":"<id>"}   resp: {ok, request_id}
#
# Auth: every request needs header  x-manus-api-key: <key>
# API key is read via a temporary header file (curl -H @file) — never passed
# on the command line. The header file lives under $TMPDIR with mode 600 and
# is removed on exit.
#
# Subcommands: create | status | result | cancel

set -euo pipefail

# --- Required env / config ---------------------------------------------------

: "${HOME:?HOME must be set}"

CONFIG_DIR="$HOME/.config/manus-dispatch"
CONFIG_FILE="$CONFIG_DIR/config.toml"
STATE_DIR="$CONFIG_DIR/state"
BASE_URL="${MANUS_BASE_URL:-https://api.manus.ai}"

mkdir -p "$STATE_DIR"

# Vault path is sourced from the obsidian plugin's own local config (single
# source of truth — no hardcoded duplicate in this plugin). Validation is
# lazy inside resolve_obsidian_vault so non-Obsidian users aren't blocked at
# import time.

# --- API key resolution ------------------------------------------------------
#
# Precedence: MANUS_API_KEY env var > config.toml api_key > config.toml api_key_cmd

resolve_api_key() {
  if [ -n "${MANUS_API_KEY:-}" ]; then
    printf '%s' "$MANUS_API_KEY"
    return 0
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "manus-client: no MANUS_API_KEY env var and no $CONFIG_FILE" >&2
    return 1
  fi
  local key
  key=$(awk -F '=' '/^[[:space:]]*api_key[[:space:]]*=/ {gsub(/^[[:space:]]*"|"[[:space:]]*$|^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$CONFIG_FILE")
  if [ -n "$key" ] && [ "$key" != '""' ]; then
    printf '%s' "$key"
    return 0
  fi
  local key_cmd
  key_cmd=$(awk -F '=' '/^[[:space:]]*api_key_cmd[[:space:]]*=/ {gsub(/^[[:space:]]*"|"[[:space:]]*$|^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$CONFIG_FILE")
  if [ -n "$key_cmd" ]; then
    eval "$key_cmd"
    return 0
  fi
  echo "manus-client: no api_key or api_key_cmd in $CONFIG_FILE" >&2
  return 1
}

# --- Obsidian config -------------------------------------------------------
#
# Read a string field from the config TOML. Tolerant of quoted/unquoted values.
read_config_string() {
  local field="$1"
  [ -f "$CONFIG_FILE" ] || return 0
  awk -F '=' -v f="$field" '
    $0 ~ "^[[:space:]]*" f "[[:space:]]*=" {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  ' "$CONFIG_FILE"
}

read_config_bool() {
  local v
  v=$(read_config_string "$1")
  case "$v" in true|1|yes) echo 1 ;; *) echo 0 ;; esac
}

# Resolve vault from the obsidian plugin's own local config.
#
# Single source of truth: ~/.claude/plugins/cache/nhangen/obsidian/<latest>/
# obsidian.local.md (YAML frontmatter `vault_path:`). Version segment is
# resolved dynamically so plugin bumps don't break this lookup.
#
# Returns 0 with stdout = vault path when enabled and valid.
# Returns 1 with diagnostic when enabled-but-not-resolvable.
# Returns 2 (silent) when manus-dispatch's obsidian_enabled is false.
resolve_obsidian_vault() {
  local enabled
  enabled=$(read_config_bool obsidian_enabled)
  if [ "$enabled" != "1" ]; then
    return 2
  fi

  local plugin_root plugin_dir local_md path
  plugin_root="$HOME/.claude/plugins/cache/nhangen/obsidian"
  if [ ! -d "$plugin_root" ]; then
    echo "manus-client: obsidian_enabled = true but obsidian plugin not installed at $plugin_root" >&2
    echo "manus-client: install nhangen/obsidian plugin or set obsidian_enabled = false" >&2
    return 1
  fi
  plugin_dir=$(ls -1d "$plugin_root"/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')
  if [ -z "$plugin_dir" ]; then
    echo "manus-client: obsidian plugin dir empty under $plugin_root" >&2
    return 1
  fi
  local_md="$plugin_dir/obsidian.local.md"
  if [ ! -f "$local_md" ]; then
    echo "manus-client: $local_md not found — configure the obsidian plugin first" >&2
    return 1
  fi
  path=$(awk '
    /^---[[:space:]]*$/ { fm = !fm; next }
    fm && /^vault_path:[[:space:]]*/ {
      sub(/^vault_path:[[:space:]]*/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }
  ' "$local_md")
  if [ -z "$path" ]; then
    echo "manus-client: vault_path missing from $local_md" >&2
    return 1
  fi
  if [ ! -d "$path" ]; then
    echo "manus-client: vault_path '$path' (from $local_md) is not a directory" >&2
    return 1
  fi
  printf '%s' "$path"
}

# Read daily_path from the obsidian plugin's obsidian.local.md frontmatter.
# Defaults to "Daily/" when unset. Trailing slash is stripped. Returns 0 always;
# stdout is the (possibly default) relative path.
read_obsidian_daily_path() {
  local plugin_root plugin_dir local_md path
  plugin_root="$HOME/.claude/plugins/cache/nhangen/obsidian"
  plugin_dir=$(ls -1d "$plugin_root"/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')
  local_md="$plugin_dir/obsidian.local.md"
  if [ -f "$local_md" ]; then
    path=$(awk '
      /^---[[:space:]]*$/ { fm = !fm; next }
      fm && /^daily_path:[[:space:]]*/ {
        sub(/^daily_path:[[:space:]]*/, "", $0)
        gsub(/^"|"$/, "", $0)
        print
        exit
      }
    ' "$local_md")
  fi
  path="${path:-Daily/}"
  printf '%s' "${path%/}"
}

# --- Header file (key never on command line) --------------------------------

HEADER_FILE=""
cleanup() { [ -n "$HEADER_FILE" ] && rm -f "$HEADER_FILE"; }
trap cleanup EXIT INT TERM

make_header_file() {
  local key
  key=$(resolve_api_key) || return 1
  HEADER_FILE=$(mktemp -t manus-hdr.XXXXXX)
  chmod 600 "$HEADER_FILE"
  printf 'x-manus-api-key: %s\nContent-Type: application/json\n' "$key" > "$HEADER_FILE"
}

# --- Stderr scrubber ---------------------------------------------------------
#
# Even though we pass the key via @file, curl can echo headers under -v or on
# certain errors. Scrub any Authorization / x-manus-api-key line before
# surfacing stderr to the user.

scrub_stderr() {
  sed -E '/^[[:space:]]*(x-manus-api-key|Authorization)[[:space:]]*:/Id'
}

# --- Subcommands -------------------------------------------------------------

cmd_create() {
  local query="${1:?usage: manus-client.sh create <query>}"

  make_header_file

  # Build JSON body. jq quoting handles all escaping safely.
  local body
  body=$(jq -nc --arg q "$query" '{
    message: { content: [ { type: "text", text: $q } ] }
  }')

  local resp_file err_file http_code
  resp_file=$(mktemp -t manus-resp.XXXXXX)
  err_file=$(mktemp -t manus-err.XXXXXX)

  http_code=$(curl -sS -w '%{http_code}' -o "$resp_file" \
    -H @"$HEADER_FILE" \
    -X POST "$BASE_URL/v2/task.create" \
    --data "$body" \
    2> >(scrub_stderr >"$err_file") || true)

  if [ "$http_code" != "200" ]; then
    echo "manus-client: create failed (HTTP $http_code)" >&2
    [ -s "$err_file" ] && cat "$err_file" >&2
    [ -s "$resp_file" ] && cat "$resp_file" >&2
    rm -f "$resp_file" "$err_file"
    return 1
  fi

  local task_id task_title task_url
  task_id=$(jq -r '.task_id // empty' "$resp_file")
  task_title=$(jq -r '.task_title // empty' "$resp_file")
  task_url=$(jq -r '.task_url // empty' "$resp_file")

  if [ -z "$task_id" ]; then
    echo "manus-client: response missing task_id" >&2
    cat "$resp_file" >&2
    rm -f "$resp_file" "$err_file"
    return 1
  fi

  local state_file="$STATE_DIR/$task_id.json"
  jq -n \
    --arg id "$task_id" \
    --arg title "$task_title" \
    --arg url "$task_url" \
    --arg query "$query" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id:$id, title:$title, task_url:$url, query:$query, started_at:$started, status:"running"}' \
    > "$state_file"

  jq -n \
    --arg id "$task_id" \
    --arg title "$task_title" \
    --arg url "$task_url" \
    --arg state "$state_file" \
    '{ok:true, task_id:$id, title:$title, task_url:$url, state_file:$state}'

  rm -f "$resp_file" "$err_file"
}

# --- Shared HTTP helper with rate_limited backoff ---------------------------
#
# Usage: http_call <method> <path> [body]  → echoes path to a file containing
# the parsed JSON response. Caller reads with jq and rm's the file. Retries
# rate_limited with exponential backoff (1s, 2s, 4s; max 3 attempts).

http_call() {
  local method="$1" path="$2" body="${3:-}"
  local resp_file err_file http_code attempt=0 sleep_secs=1

  resp_file=$(mktemp -t manus-resp.XXXXXX)
  err_file=$(mktemp -t manus-err.XXXXXX)

  while :; do
    : > "$resp_file" : > "$err_file"
    if [ "$method" = "GET" ]; then
      http_code=$(curl -sS -w '%{http_code}' -o "$resp_file" \
        -H @"$HEADER_FILE" \
        "$BASE_URL$path" \
        2> >(scrub_stderr >"$err_file") || true)
    else
      local _body="${body:-\{\}}"
      http_code=$(curl -sS -w '%{http_code}' -o "$resp_file" \
        -H @"$HEADER_FILE" \
        -X "$method" "$BASE_URL$path" \
        --data "$_body" \
        2> >(scrub_stderr >"$err_file") || true)
    fi

    if [ "$http_code" = "200" ]; then
      echo "$resp_file"
      rm -f "$err_file"
      return 0
    fi

    local err_code
    err_code=$(jq -r '.error.code // empty' "$resp_file" 2>/dev/null || true)
    if [ "$err_code" = "rate_limited" ] && [ "$attempt" -lt 2 ]; then
      sleep "$sleep_secs"
      sleep_secs=$((sleep_secs * 2))
      attempt=$((attempt + 1))
      continue
    fi

    echo "manus-client: $method $path failed (HTTP $http_code, code=$err_code)" >&2
    [ -s "$err_file" ] && cat "$err_file" >&2
    [ -s "$resp_file" ] && cat "$resp_file" >&2
    rm -f "$resp_file" "$err_file"
    return 1
  done
}

# Pull the most recent status_update.agent_status from a listMessages response.
# Returns one of: running | stopped | waiting | error | unknown
extract_agent_status() {
  local resp_file="$1"
  local s
  s=$(jq -r '
    .messages
    | map(select(.type == "status_update"))
    | first(.[]? | .status_update.agent_status // empty)
    // empty
  ' "$resp_file")
  if [ -z "$s" ]; then
    s=$(jq -r '
      .messages
      | map(select(.type == "status_update"))
      | first(.[]? | (.agent_status // .status_update.agent_status // empty))
      // empty
    ' "$resp_file")
  fi
  echo "${s:-unknown}"
}

# Pull the most recent assistant_message text from a listMessages response.
# When messages are ordered desc (newest first), the first assistant_message is
# the final reply. .assistant_message.content is a plain string in v2.
extract_assistant_text() {
  local resp_file="$1"
  jq -r '
    [ .messages[]? | select(.type == "assistant_message") ]
    | first
    | (.assistant_message.content // .content // "")
    | if type == "array" then map(.text // .) | join("\n") else . end
  ' "$resp_file" 2>/dev/null | head -c 65536
}

# --- Obsidian filing --------------------------------------------------------
#
# Write a research result to <vault>/Projects/Research/manus/<date>-<slug>.md.
# Best-effort daily-note link append under ## Research.

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-60
}

summarize_result() {
  printf '%s' "$1" \
    | awk '
        /^[[:space:]]*```/ { in_code = !in_code; next }
        in_code { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { sub(/^[[:space:]]*[-*+][[:space:]]+/, ""); print; exit }
      ' \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | cut -c1-200
}

file_to_obsidian() {
  local task_id="$1" title="$2" query="$3" result="$4" task_url="$5"

  local vault
  vault=$(resolve_obsidian_vault)
  local rc=$?
  case $rc in
    2) return 0 ;;        # disabled, no-op
    1) return 1 ;;        # enabled-but-misconfigured (diagnostic already emitted)
  esac

  local date_str slug note_dir note_path
  date_str=$(date +%Y-%m-%d)
  slug=$(slugify "${title:-$query}")
  [ -n "$slug" ] || slug="manus-$task_id"
  note_dir="$vault/Projects/Research/manus"
  note_path="$note_dir/$date_str-$slug.md"
  mkdir -p "$note_dir"

  {
    printf -- '---\n'
    printf 'date: %s\n' "$date_str"
    printf 'source: manus\n'
    printf 'task_id: %s\n' "$task_id"
    printf 'task_url: %s\n' "$task_url"
    printf 'tags: [manus, research]\n'
    printf -- '---\n\n'
    printf '# %s\n\n' "${title:-Manus research}"
    printf '## Query\n\n%s\n\n' "$query"
    printf '## Result\n\n%s\n' "$result"
  } > "$note_path"

  local daily_rel daily_dir daily
  daily_rel=$(read_obsidian_daily_path)
  daily_dir="$vault/$daily_rel"
  daily="$daily_dir/$date_str.md"
  mkdir -p "$daily_dir"
  if [ ! -f "$daily" ]; then
    {
      printf -- '---\n'
      printf 'date: %s\n' "$date_str"
      printf 'tags: [daily]\n'
      printf -- '---\n\n'
      printf '# %s\n' "$date_str"
    } > "$daily"
  fi

  local summary rel_path entry_marker entry
  summary=$(summarize_result "$result")
  local up_segments=""
  local _segs="${daily_rel%/}"
  while [ -n "$_segs" ]; do
    up_segments="../$up_segments"
    case "$_segs" in
      */*) _segs="${_segs%/*}" ;;
      *)   _segs="" ;;
    esac
  done
  rel_path="${up_segments}Projects/Research/manus/$date_str-$slug.md"
  entry_marker="<!-- manus:$task_id -->"
  if grep -qF "$entry_marker" "$daily"; then
    printf '%s' "$note_path"
    return 0
  fi

  entry=$(printf -- '- [%s](%s) — task `%s` — [Manus](%s) %s\n  %s' \
    "${title:-Manus research}" "$rel_path" "$task_id" "${task_url:-#}" \
    "$entry_marker" "${summary:-(no summary)}")

  if grep -q '^## Research' "$daily"; then
    awk -v line="$entry" '
      BEGIN { inserted=0 }
      /^## Research/ && !inserted { print; getline blank; if (blank ~ /^[[:space:]]*$/) { print blank } else { print ""; print blank }; print line; inserted=1; next }
      { print }
      END { if (!inserted) { print ""; print "## Research"; print ""; print line } }
    ' "$daily" > "$daily.tmp" && mv "$daily.tmp" "$daily"
  else
    printf '\n## Research\n\n%s\n' "$entry" >> "$daily"
  fi

  printf '%s' "$note_path"
}

# Pull a short failure reason from a listMessages response. Looks for explicit
# error events; falls back to a generic string. Never returns empty.
extract_failure_reason() {
  local resp_file="$1"
  local reason jq_err
  jq_err=$(mktemp -t manus-jqerr.XXXXXX)
  reason=$(jq -r '
    [ .messages[]? | select(.type == "error" or .type == "status_update") ]
    | map(.error.message // .status_update.error // .status_update.detail // empty)
    | map(select(. != null and . != ""))
    | first // empty
  ' "$resp_file" 2>"$jq_err")
  reason=$(printf '%s' "$reason" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-200)
  if [ -z "$reason" ]; then
    if [ -s "$jq_err" ]; then
      reason="error: failed to parse response ($(head -c 80 "$jq_err" | tr '\n' ' '))"
    else
      reason="error: agent_status=error, no message in response (head=$(head -c 80 "$resp_file" | tr -d '\n' | sed 's/"/\\"/g'))"
    fi
  fi
  rm -f "$jq_err"
  printf '%s' "$reason"
}

# Append a single failure line to <vault>/CEO/inbox.md, once per task.
#
# Per ~/.claude/rules/ceo-automated-writers-are-playbooks.md any automated
# writer to the CEO vault must be a registered playbook. We require the
# vault's CEO/registry.json to list a `manus-dispatch-failures` entry before
# writing. If the entry is missing we emit a diagnostic and skip — better to
# silently no-op than to spam an unsanctioned inbox.
#
# Idempotency is handled by the caller via the `.failure_reported_at` field
# on the per-task state file; once set, we don't re-enter this function for
# the same task.
report_failure_to_inbox() {
  local task_id="$1" title="$2" reason="$3" task_url="$4"

  local vault
  vault=$(resolve_obsidian_vault)
  local rc=$?
  case $rc in
    2) return 0 ;;
    1) return 1 ;;
  esac

  local registry="$vault/CEO/registry.json"
  if [ ! -f "$registry" ]; then
    echo "manus-client: $registry missing — failure not reported to CEO/inbox.md" >&2
    return 1
  fi
  if ! jq -e '.playbooks[]? | select(.name == "manus-dispatch-failures")' "$registry" >/dev/null 2>&1; then
    echo "manus-client: CEO/registry.json missing 'manus-dispatch-failures' playbook — failure not reported" >&2
    echo "manus-client: register the writer per docs/playbooks/manus-dispatch-failures.md" >&2
    return 1
  fi

  local inbox="$vault/CEO/inbox.md"
  mkdir -p "$vault/CEO"
  [ -f "$inbox" ] || printf '# Inbox\n\n' > "$inbox"

  local line url_part=""
  [ -n "$task_url" ] && url_part=" — [Manus]($task_url)"
  line=$(printf -- '- [ ] Manus task `%s` (%s) failed: %s%s' \
    "$task_id" "${title:-untitled}" "$reason" "$url_part")
  printf '%s\n' "$line" >> "$inbox"
}

# --- status / result / cancel -----------------------------------------------

cmd_status() {
  local task_id="${1:?usage: manus-client.sh status <task_id>}"
  make_header_file

  local resp_file
  resp_file=$(http_call GET "/v2/task.listMessages?task_id=$task_id&order=desc&limit=20") || return 1

  local status state_file
  status=$(extract_agent_status "$resp_file")
  state_file="$STATE_DIR/$task_id.json"

  if [ -f "$state_file" ]; then
    local tmp
    tmp=$(mktemp -t manus-state.XXXXXX)
    jq --arg s "$status" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.status = $s | .last_checked_at = $checked' \
      "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi

  jq -n --arg id "$task_id" --arg s "$status" --arg state "$state_file" \
    '{ok:true, task_id:$id, status:$s, state_file:$state}'

  rm -f "$resp_file"
}

cmd_result() {
  local task_id="${1:?usage: manus-client.sh result <task_id>}"
  make_header_file

  local resp_file
  resp_file=$(http_call GET "/v2/task.listMessages?task_id=$task_id&order=desc&limit=50") || return 1

  local status text
  status=$(extract_agent_status "$resp_file")
  text=$(extract_assistant_text "$resp_file")

  local state_file="$STATE_DIR/$task_id.json"
  local title query task_url note_path=""
  if [ -f "$state_file" ]; then
    title=$(jq -r '.title // empty' "$state_file")
    query=$(jq -r '.query // empty' "$state_file")
    task_url=$(jq -r '.task_url // empty' "$state_file")
    local tmp

    if [ "$status" = "error" ]; then
      local already_reported reason
      already_reported=$(jq -r '.failure_reported_at // empty' "$state_file")
      if [ -z "$already_reported" ]; then
        reason=$(extract_failure_reason "$resp_file")
        if report_failure_to_inbox "$task_id" "$title" "$reason" "$task_url"; then
          tmp=$(mktemp -t manus-state.XXXXXX)
          jq --arg s "$status" \
             --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             --arg reason "$reason" \
             '.status = $s | .last_checked_at = $checked
              | .failure_reported_at = $ts | .failure_reason = $reason' \
             "$state_file" > "$tmp" && mv "$tmp" "$state_file"
        else
          tmp=$(mktemp -t manus-state.XXXXXX)
          jq --arg s "$status" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             '.status = $s | .last_checked_at = $checked' \
             "$state_file" > "$tmp" && mv "$tmp" "$state_file"
        fi
      fi
    elif [ -n "$text" ]; then
      tmp=$(mktemp -t manus-state.XXXXXX)
      jq --arg s "$status" \
         --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg r "$text" \
         '.status = $s | .last_checked_at = $checked | .result = $r' \
         "$state_file" > "$tmp" && mv "$tmp" "$state_file"

      local file_rc=0
      note_path=$(file_to_obsidian "$task_id" "$title" "$query" "$text" "$task_url") || file_rc=$?
      if [ "$file_rc" -eq 0 ] && [ -n "$note_path" ] && [ -f "$note_path" ]; then
        tmp=$(mktemp -t manus-state.XXXXXX)
        jq --arg p "$note_path" '.obsidian_note = $p' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
      elif [ "$file_rc" -eq 1 ]; then
        note_path=""
        tmp=$(mktemp -t manus-state.XXXXXX)
        jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           '.obsidian_failed_at = $ts' \
           "$state_file" > "$tmp" && mv "$tmp" "$state_file"
        echo "manus-client: obsidian filing failed for task $task_id (vault misconfigured); will retry on next result fetch" >&2
      else
        note_path=""
      fi
    fi
  fi

  jq -n \
    --arg id "$task_id" \
    --arg s "$status" \
    --arg text "$text" \
    --arg state "$state_file" \
    --arg note "$note_path" \
    '{ok:true, task_id:$id, status:$s, result:$text, state_file:$state, obsidian_note:(if $note == "" then null else $note end)}'

  rm -f "$resp_file"
}

cmd_cancel() {
  local task_id="${1:?usage: manus-client.sh cancel <task_id>}"
  make_header_file

  local body
  body=$(jq -nc --arg id "$task_id" '{task_id:$id}')

  local resp_file
  resp_file=$(http_call POST "/v2/task.stop" "$body") || return 1

  local state_file="$STATE_DIR/$task_id.json"
  if [ -f "$state_file" ]; then
    local tmp
    tmp=$(mktemp -t manus-state.XXXXXX)
    jq --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.status = "stopped" | .cancelled_at = $checked' \
       "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi

  jq -n --arg id "$task_id" --arg state "$state_file" \
    '{ok:true, task_id:$id, status:"stopped", state_file:$state}'

  rm -f "$resp_file"
}

usage() {
  cat >&2 <<EOF
usage: manus-client.sh <command> [args]

commands:
  create <query>     Dispatch a research task; writes state file; prints JSON
  status <task_id>   Fetch current agent_status; update state file
  result <task_id>   Fetch latest assistant_message text and current status
  cancel <task_id>   Stop a running task

env:
  MANUS_API_KEY      Overrides config api_key
  MANUS_BASE_URL     Defaults to https://api.manus.ai
EOF
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { usage; exit 2; }
  shift
  case "$cmd" in
    create) cmd_create "$@" ;;
    status) cmd_status "$@" ;;
    result) cmd_result "$@" ;;
    cancel) cmd_cancel "$@" ;;
    -h|--help|help) usage ;;
    *) echo "manus-client: unknown command: $cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
