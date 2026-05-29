#!/usr/bin/env bash
# manus-client.sh — thin curl wrapper for the Manus v2 API.
#
# Endpoints (base https://api.manus.ai):
#   POST /v2/task.create        body: {"message":{"content":[{"type":"text","text":"<query>"}]}}
#                               resp: {ok, request_id, task_id, task_title, task_url, share_url}
#   GET  /v2/task.listMessages  ?task_id=<id>&order=desc&limit=10
#                               status surfaces via agent_status in the latest event:
#                                 running | stopped | waiting | error
#   POST /v2/task.stop          (added in phase 2)
#   POST /v2/task.delete        (added in phase 2)
#
# Auth: every request needs header  x-manus-api-key: <key>
# API key is read via a temporary header file (curl -H @file) — never passed
# on the command line. The header file lives under $TMPDIR with mode 600 and
# is removed on exit.
#
# Phase 1: only `create` is implemented end-to-end. status/result/cancel are
# stubs that print "not yet implemented".

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

cmd_status() {
  echo "manus-client: status not yet implemented (phase 2)" >&2
  return 2
}

cmd_result() {
  echo "manus-client: result not yet implemented (phase 2)" >&2
  return 2
}

cmd_cancel() {
  echo "manus-client: cancel not yet implemented (phase 2)" >&2
  return 2
}

usage() {
  cat >&2 <<EOF
usage: manus-client.sh <command> [args]

commands:
  create <query>     Dispatch a research task; writes state file; prints JSON
  status <task_id>   (phase 2) Fetch current task status
  result <task_id>   (phase 2) Fetch final task result
  cancel <task_id>   (phase 2) Cancel a running task

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
