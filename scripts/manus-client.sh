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
      http_code=$(curl -sS -w '%{http_code}' -o "$resp_file" \
        -H @"$HEADER_FILE" \
        -X "$method" "$BASE_URL$path" \
        --data "${body:-{}}" \
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
  if [ -f "$state_file" ] && [ -n "$text" ]; then
    local tmp
    tmp=$(mktemp -t manus-state.XXXXXX)
    jq --arg s "$status" \
       --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg r "$text" \
       '.status = $s | .last_checked_at = $checked | .result = $r' \
       "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi

  jq -n \
    --arg id "$task_id" \
    --arg s "$status" \
    --arg text "$text" \
    --arg state "$state_file" \
    '{ok:true, task_id:$id, status:$s, result:$text, state_file:$state}'

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
