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
#                               assistant_message events carry the final reply,
#                               and optionally .attachments[] — the deliverable
#                               as a file, with a pre-signed (expiring)
#                               manuscdn.com URL that takes no API key.
#   POST /v2/task.stop          body: {"task_id":"<id>"}   resp: {ok, request_id}
#
# Auth: every request needs header  x-manus-api-key: <key>
# API key is read via a temporary header file (curl -H @file) — never passed
# on the command line. The header file lives under $TMPDIR with mode 600 and
# is removed on exit.
#
# Subcommands: create | status | result | files [--with-urls] | download [--out DIR] | cancel

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

# Locate the obsidian plugin's obsidian.local.md, the single source of truth for
# the vault path. Prints the file path on stdout, or nothing.
#
# The cache directory under ~/.claude/plugins/cache/ is keyed by MARKETPLACE
# name, not by repo owner, and the version segment is optional depending on how
# the plugin was installed. Both segments are therefore globbed rather than
# assumed: pinning either one silently resolves to nothing, which reads
# identically to "no vault configured".
find_obsidian_local_md() {
  local candidate
  for candidate in \
    "$HOME"/.claude/plugins/cache/*/obsidian/*/obsidian.local.md \
    "$HOME"/.claude/plugins/cache/*/obsidian/obsidian.local.md
  do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Resolve vault from the obsidian plugin's own local config.
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

  local local_md path
  # An explicit obsidian_path in our own config wins — it lets a user who has no
  # obsidian plugin, or a non-standard install, still file notes.
  path=$(read_config_string obsidian_path)
  if [ -n "$path" ]; then
    if [ ! -d "$path" ]; then
      echo "manus-client: obsidian_path '$path' (from $CONFIG_FILE) is not a directory" >&2
      return 1
    fi
    printf '%s' "$path"
    return 0
  fi

  if ! local_md=$(find_obsidian_local_md); then
    echo "manus-client: obsidian_enabled = true but no obsidian.local.md found under $HOME/.claude/plugins/cache/*/obsidian/" >&2
    echo "manus-client: configure the nhangen/obsidian plugin, set obsidian_path in $CONFIG_FILE, or set obsidian_enabled = false" >&2
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
  local local_md path
  if local_md=$(find_obsidian_local_md); then
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

  http_code=$(curl -sS --connect-timeout 5 --max-time 30 -w '%{http_code}' -o "$resp_file" \
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
    : > "$resp_file"
    : > "$err_file"
    if [ "$method" = "GET" ]; then
      http_code=$(curl -sS --connect-timeout 5 --max-time 30 -w '%{http_code}' -o "$resp_file" \
        -H @"$HEADER_FILE" \
        "$BASE_URL$path" \
        2> >(scrub_stderr >"$err_file") || true)
    else
      local _body="${body:-\{\}}"
      http_code=$(curl -sS --connect-timeout 5 --max-time 30 -w '%{http_code}' -o "$resp_file" \
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

# Reject an unparseable body before anything reads it. Without this, the first
# bare `jq` on the body (extract_agent_status) dies under `set -e` and the reader
# sees jq's raw parse error instead of the crafted diagnostic further down.
assert_parseable_body() {
  local resp_file="$1"
  jq -e . "$resp_file" >/dev/null 2>&1 && return 0
  echo "manus-client: the API response could not be parsed as JSON — treating this as an error, not as an empty result" >&2
  return 1
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

# Pull attachments from a listMessages response as a compact JSON array of
# {filename, content_type, url}. Emits `[]` when there are none.
#
# Shape (v2, exercised end-to-end by tests/attachments-test.sh's stub server):
#   .messages[] | select(.type=="assistant_message")
#     | .assistant_message.attachments[] = {type, filename, content_type, url}
# The url is a PRE-SIGNED manuscdn.com link (CloudFront Policy/Signature in the
# query string) — it needs no Manus API key, and must never be sent one (see
# cmd_download). It also EXPIRES, which is why we surface it rather than cache it.
#
# Messages arrive newest-first (order=desc). This collects from every assistant
# message, not only the last one, and dedupes by url while preserving that order.
#
# A parse failure must NOT degrade to "[]": reporting zero attachments for a
# body we couldn't read is precisely the silent-payload-loss bug this path
# exists to fix.
extract_attachments() {
  local resp_file="$1" out jq_err rc=0
  jq_err=$(mktemp -t manus-jqerr.XXXXXX)
  out=$(jq -c '
    [ .messages[]?
      | select(.type == "assistant_message")
      | .assistant_message.attachments[]?
      | select((.url // "") != "")
      | { filename: (.filename // "attachment"),
          content_type: (.content_type // ""),
          url: .url }
    ]
    | reduce .[] as $a ([]; if any(.[]; .url == $a.url) then . else . + [$a] end)
  ' "$resp_file" 2>"$jq_err") || rc=$?

  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    echo "manus-client: could not parse attachments from the API response — treating this as an error, not as 'no attachments' (jq: $(head -c 200 "$jq_err" | tr '\n' ' '))" >&2
    rm -f "$jq_err"
    return 1
  fi
  rm -f "$jq_err"

  # Count what the response carried before the url filter. If Manus renames the
  # field, the jq above still succeeds and returns [] — the original bug back
  # under a different cause. A visible warning is the difference between
  # "no files" and "files we can't reach".
  local raw kept
  raw=$(jq -r '[.messages[]? | select(.type == "assistant_message")
                | .assistant_message.attachments[]?] | length' "$resp_file" 2>/dev/null || echo 0)
  kept=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo 0)
  if [ "$raw" -gt "$kept" ] 2>/dev/null; then
    echo "manus-client: $((raw - kept)) of $raw attachment(s) had no usable download url and were dropped — the API's attachment shape may have changed" >&2
  fi

  printf '%s' "$out"
}

# We read one page of messages, so any attachment count we report is a count of
# what fit on that page. Warn whenever the log is longer, whether or not we found
# something: a partial set of files is as wrong as none, and reporting either as
# the whole answer is the silent-omission failure in a new place.
warn_if_truncated() {
  local resp_file="$1"
  local has_more
  has_more=$(jq -r '.has_more // false' "$resp_file" 2>/dev/null || echo false)
  [ "$has_more" = "true" ] || return 0
  echo "manus-client: the message log is longer than one page (has_more=true) — attachments on older messages are not visible here, so this count may be short" >&2
}

# -> "2 file(s): a.md, b.csv"
# Empty string when there are none.
describe_attachments() {
  printf '%s' "$1" | jq -r '
    if length == 0 then ""
    else "\(length) file(s): " + (map(.filename) | join(", "))
    end
  ' 2>/dev/null || true
}

# Sanitize an API-supplied filename into a safe basename. The filename is
# untrusted input: strip any directory component so a crafted
# "../../.ssh/authorized_keys" can't escape the output dir, and refuse names
# that reduce to nothing or to a dot-entry.
safe_basename() {
  local name="$1" base
  base=${name##*/}
  base=${base//\\//}
  base=${base##*/}
  base=$(printf '%s' "$base" | tr -d '\000-\037' | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^\.+//')
  base=$(printf '%s' "$base" | cut -c1-120)
  [ -n "$base" ] || return 1
  printf '%s' "$base"
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
  local task_id="$1" title="$2" query="$3" result="$4" task_url="$5" atts="${6:-[]}"

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
    printf '## Result\n\n%s\n' "${result:-_(no summary text — the deliverable is attached, see below)_}"
    # The signed URLs expire, so record the filenames and the command that
    # re-fetches them rather than pasting links that rot inside the vault.
    if [ "$(printf '%s' "$atts" | jq -r 'length')" != "0" ]; then
      printf '\n## Attachments\n\n'
      printf '%s' "$atts" | jq -r '.[] | "- `\(.filename)` — \(.content_type)"'
      printf '\nManus serves these as expiring signed URLs. Fetch them with:\n\n'
      printf '```bash\nmanus-client.sh download %s\n```\n' "$task_id"
    fi
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
  local att_desc
  att_desc=$(describe_attachments "$atts")
  if [ -n "$att_desc" ]; then
    summary="${summary:+$summary }📎 $att_desc"
  fi
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
  resp_file=$(http_call GET "/v2/task.listMessages?task_id=$task_id&order=desc&limit=50") || return 1

  local status state_file atts rc=0
  assert_parseable_body "$resp_file" || { rm -f "$resp_file"; return 1; }
  status=$(extract_agent_status "$resp_file")
  atts=$(extract_attachments "$resp_file") || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$resp_file"
    return 1
  fi
  warn_if_truncated "$resp_file"
  state_file="$STATE_DIR/$task_id.json"

  if [ -f "$state_file" ]; then
    local tmp
    tmp=$(mktemp -t manus-state.XXXXXX)
    # Only record attachments when this read actually saw some. A page that
    # happened not to include them is not evidence that the task has none, and
    # overwriting with [] would erase what an earlier read established.
    jq --arg s "$status" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson a "$atts" \
      '.status = $s | .last_checked_at = $checked
       | if ($a | length) > 0 then .attachments = ($a | map({filename, content_type})) else . end' \
      "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi

  jq -n --arg id "$task_id" --arg s "$status" --arg state "$state_file" --argjson a "$atts" \
    '{ok:true, task_id:$id, status:$s, state_file:$state,
      attachment_count:($a|length), attachments:($a | map({filename, content_type}))}'

  rm -f "$resp_file"
}

cmd_result() {
  local task_id="${1:?usage: manus-client.sh result <task_id>}"
  make_header_file

  local resp_file
  resp_file=$(http_call GET "/v2/task.listMessages?task_id=$task_id&order=desc&limit=50") || return 1

  local status text atts att_count rc=0
  assert_parseable_body "$resp_file" || { rm -f "$resp_file"; return 1; }
  status=$(extract_agent_status "$resp_file")
  text=$(extract_assistant_text "$resp_file")
  atts=$(extract_attachments "$resp_file") || rc=$?
  if [ "$rc" -eq 0 ]; then
    warn_if_truncated "$resp_file"
  fi
  if [ "$rc" -ne 0 ]; then
    # Bail rather than file a note claiming a text-only result — a task whose
    # payload is a file would be recorded as complete with the file dropped.
    rm -f "$resp_file"
    return 1
  fi
  att_count=$(printf '%s' "$atts" | jq -r 'length')

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
    elif [ -n "$text" ] || [ "$att_count" != "0" ]; then
      tmp=$(mktemp -t manus-state.XXXXXX)
      jq --arg s "$status" \
         --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg r "$text" \
         --argjson a "$atts" \
         '.status = $s | .last_checked_at = $checked | .result = $r
          | .attachments = ($a | map({filename, content_type}))' \
         "$state_file" > "$tmp" && mv "$tmp" "$state_file"

      local file_rc=0
      note_path=$(file_to_obsidian "$task_id" "$title" "$query" "$text" "$task_url" "$atts") || file_rc=$?
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
    --argjson a "$atts" \
    '{ok:true, task_id:$id, status:$s, result:$text, state_file:$state,
      obsidian_note:(if $note == "" then null else $note end),
      attachment_count:($a|length),
      attachments:($a | map({filename, content_type})),
      attachment_hint:(if ($a|length) > 0
        then "deliverable includes \($a|length) file(s); fetch with: manus-client.sh download \($id)"
        else null end)}'

  rm -f "$resp_file"
}

# List a task's attachments. URLs are withheld unless --with-urls is passed:
# each one is a signed ~month-long bearer capability, and this output goes into
# Claude's context, from there into session notes, and from there into a synced
# vault. Names and types answer "what came back"; the url is only needed by a
# caller that intends to fetch outside `download`.
cmd_files() {
  local task_id="" with_urls=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-urls) with_urls=1; shift ;;
      -*) echo "manus-client: unknown files flag: $1" >&2; return 2 ;;
      *) [ -z "$task_id" ] || { echo "manus-client: unexpected argument: $1" >&2; return 2; }
         task_id="$1"; shift ;;
    esac
  done
  [ -n "$task_id" ] || { echo "usage: manus-client.sh files <task_id> [--with-urls]" >&2; return 2; }
  make_header_file

  local resp_file
  resp_file=$(http_call GET "/v2/task.listMessages?task_id=$task_id&order=desc&limit=50") || return 1

  local atts rc=0
  atts=$(extract_attachments "$resp_file") || rc=$?
  # After the rc check: claiming anything about how much of the log we saw is
  # meaningless over a body we already know we could not read.
  [ "$rc" -eq 0 ] || { rm -f "$resp_file"; return 1; }
  warn_if_truncated "$resp_file"
  rm -f "$resp_file"

  jq -n --arg id "$task_id" --argjson a "$atts" --argjson urls "$with_urls" \
    '{ok:true, task_id:$id, count:($a|length),
      attachments:(if $urls == 1 then $a else ($a | map({filename, content_type})) end)}'
}

# Download a task's attachments to a local directory.
#
# The URLs are pre-signed CDN links, so the download runs WITHOUT the Manus
# auth header — sending x-manus-api-key to manuscdn.com would hand our key to a
# host that does not need it (see ~/.claude/rules/no-secrets-in-logs.md). The
# flip side is expiry: a signed URL older than its Policy window returns 403,
# which we report as a re-fetch instruction rather than a generic HTTP error.
cmd_download() {
  local task_id="" out_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ -n "${2:-}" ] || { echo "manus-client: --out requires a directory" >&2; return 2; }
             out_dir="$2"; shift 2 ;;
      --out=*) out_dir="${1#--out=}"
               [ -n "$out_dir" ] || { echo "manus-client: --out requires a directory" >&2; return 2; }
               shift ;;
      -*) echo "manus-client: unknown download flag: $1" >&2; return 2 ;;
      *) [ -z "$task_id" ] || { echo "manus-client: unexpected argument: $1" >&2; return 2; }
         task_id="$1"; shift ;;
    esac
  done
  [ -n "$task_id" ] || { echo "usage: manus-client.sh download <task_id> [--out DIR]" >&2; return 2; }
  out_dir="${out_dir:-$CONFIG_DIR/files/$task_id}"

  make_header_file

  local resp_file
  resp_file=$(http_call GET "/v2/task.listMessages?task_id=$task_id&order=desc&limit=50") || return 1
  local atts extract_rc=0
  atts=$(extract_attachments "$resp_file") || extract_rc=$?
  [ "$extract_rc" -eq 0 ] || { rm -f "$resp_file"; return 1; }
  warn_if_truncated "$resp_file"
  rm -f "$resp_file"

  local count
  count=$(printf '%s' "$atts" | jq -r 'length')
  if [ "$count" = "0" ]; then
    jq -n --arg id "$task_id" --arg dir "$out_dir" \
      '{ok:true, task_id:$id, out_dir:$dir, count:0, failed:0, files:[],
        note:"no attachments on this task"}'
    return 0
  fi

  mkdir -p "$out_dir"

  local saved="[]" lost="[]" failures=0 i=0 claimed=""
  while [ "$i" -lt "$count" ]; do
    local filename url base dest http_code err_file curl_rc
    filename=$(printf '%s' "$atts" | jq -r ".[$i].filename")
    url=$(printf '%s' "$atts" | jq -r ".[$i].url")
    i=$((i + 1))

    if ! base=$(safe_basename "$filename"); then
      echo "manus-client: skipping attachment with unusable filename '$filename'" >&2
      failures=$((failures + 1))
      lost=$(printf '%s' "$lost" | jq -c --arg f "$filename" '. + [$f]')
      continue
    fi
    # Two attachments can share a filename (or collapse onto one after
    # sanitizing). Suffix rather than let the second silently overwrite the
    # first.
    #
    # Collision is judged against names claimed EARLIER IN THIS RUN, not
    # against what's on disk: re-downloading a task must overwrite its own
    # previous output, not accumulate a -2, -3, -4 copy per poll. The
    # manus-status command re-runs download on every status check.
    dest="$out_dir/$base"
    case " $claimed " in
      *" $base "*)
        local stem ext n=2
        case "$base" in
          ?*.*) stem="${base%.*}"; ext=".${base##*.}" ;;
          *)    stem="$base"; ext="" ;;
        esac
        while case " $claimed " in *" $stem-$n$ext "*) true ;; *) false ;; esac; do
          n=$((n + 1))
        done
        base="$stem-$n$ext"
        dest="$out_dir/$base"
        ;;
    esac
    claimed="$claimed $base"

    err_file=$(mktemp -t manus-dlerr.XXXXXX)
    # Fetch to a staging file beside the destination and promote it with mv only
    # once the whole transfer checks out. Writing straight to $dest means any
    # failure — and the signed URL 403s about a month out, while manus-status
    # re-runs download on every poll — lands on the only copy of the deliverable
    # and takes it with it. mv within the same directory is also atomic, so a
    # concurrent reader sees either the old file or the new one, never a
    # half-written one.
    local tmp_dest
    tmp_dest=$(mktemp "$out_dir/.manus-dl.XXXXXX") || {
      echo "manus-client: cannot stage a download in '$out_dir'" >&2
      rm -f "$err_file"
      failures=$((failures + 1))
      lost=$(printf '%s' "$lost" | jq -c --arg f "$base" '. + [$f]')
      continue
    }

    # No -H @"$HEADER_FILE" here — deliberate; see the comment above.
    # curl's own exit status matters as much as the HTTP code: a transfer that
    # dies mid-body (server closes early) still reports 200, and keeping that
    # stub file would report half a deliverable as delivered.
    curl_rc=0
    http_code=$(curl -sS -L --connect-timeout 5 --max-time 120 \
      -w '%{http_code}' -o "$tmp_dest" "$url" 2>"$err_file") || curl_rc=$?

    if [ "$http_code" != "200" ] || [ "$curl_rc" -ne 0 ] || [ ! -s "$tmp_dest" ]; then
      rm -f "$tmp_dest"
      if [ "$http_code" = "403" ]; then
        echo "manus-client: '$base' download refused (HTTP 403) — the link may have expired; re-run 'download $task_id' to fetch a fresh link" >&2
      elif [ "$http_code" = "200" ] && [ "$curl_rc" -ne 0 ]; then
        echo "manus-client: '$base' transfer incomplete (HTTP 200 but curl exit $curl_rc) — partial file discarded" >&2
      elif [ "$http_code" = "200" ]; then
        echo "manus-client: '$base' arrived empty (HTTP 200, zero bytes) — an empty file is not a deliverable, discarded" >&2
      else
        echo "manus-client: '$base' download failed (HTTP $http_code, curl exit $curl_rc)" >&2
      fi
      [ -s "$err_file" ] && scrub_stderr < "$err_file" >&2
      rm -f "$err_file"
      [ -e "$dest" ] && echo "manus-client: kept the existing '$base' already on disk" >&2
      failures=$((failures + 1))
      lost=$(printf '%s' "$lost" | jq -c --arg f "$base" '. + [$f]')
      continue
    fi
    rm -f "$err_file"
    if ! mv "$tmp_dest" "$dest"; then
      rm -f "$tmp_dest"
      echo "manus-client: could not move '$base' into place in '$out_dir'" >&2
      failures=$((failures + 1))
      lost=$(printf '%s' "$lost" | jq -c --arg f "$base" '. + [$f]')
      continue
    fi
    chmod 644 "$dest" 2>/dev/null || true

    saved=$(printf '%s' "$saved" | jq -c --arg f "${dest##*/}" --arg p "$dest" \
      --arg b "$(wc -c < "$dest" | tr -d ' ')" '. + [{filename:$f, path:$p, bytes:($b|tonumber)}]')
  done

  jq -n --arg id "$task_id" --arg dir "$out_dir" --argjson f "$saved" \
    --argjson fail "$failures" --argjson lost "$lost" \
    '{ok:($fail == 0), task_id:$id, out_dir:$dir, count:($f|length), failed:$fail,
      files:$f, failed_files:$lost}'

  [ "$failures" -eq 0 ]
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
  files <task_id> [--with-urls]
                     List the task's attachments (filename + type; --with-urls
                     also prints the signed CDN link, which is a bearer
                     capability valid for weeks)
  download <task_id> [--out DIR | --out=DIR]
                     Download the task's attachments (default:
                     ~/.config/manus-dispatch/files/<task_id>)
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
    files) cmd_files "$@" ;;
    download) cmd_download "$@" ;;
    cancel) cmd_cancel "$@" ;;
    -h|--help|help) usage ;;
    *) echo "manus-client: unknown command: $cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
