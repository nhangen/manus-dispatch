#!/usr/bin/env bash
#
# Regression test for attachment retrieval (issue #6).
#
# Pins the fix: an assistant_message carrying .attachments[] must reach the
# caller. Before the fix the client parsed only .assistant_message.content, so
# any task whose deliverable was a file looked complete with the payload gone.
#
# The test runs the REAL client against a local python HTTP server standing in
# for both api.manus.ai (task.listMessages) and the manuscdn.com signed-URL
# host, so it exercises the actual jq extraction, the actual curl download, and
# the actual filename handling — not a stub of them.
#
# Load-bearing checks, each failing when the corresponding part of the fix is
# reverted:
#   1. `files` lists the attachment           -> extract_attachments exists at all
#   2. `download` writes real bytes to disk   -> cmd_download works end to end
#   3. the CDN request carries NO api key     -> we don't leak the key to a
#                                                third-party host (the download
#                                                path deliberately omits the
#                                                auth header file)
#   4. a traversal filename lands inside      -> safe_basename strips ../
#      --out and cannot escape it
#   5. result/status report attachment_count  -> a file deliverable can't look
#                                                complete with the payload gone
#   6. neither the state file nor the vault    -> signed URLs expire; caching one
#      note stores a signed URL                 leaves a link that rots
#   7. an unparseable body errors out          -> it must never degrade to
#                                                "count: 0", which is the same
#                                                silent omission as issue #6
#   8. a 403/404/mid-body-truncated download   -> a partial file counted as
#      is counted as a failure                   delivered is issue #6 again
#   9. re-running download overwrites          -> no -2/-3 pile-up per poll
#
# Usage: tests/attachments-test.sh   (exit 0 = pass, non-zero = fail)

set -u

CLIENT="$(cd "$(dirname "$0")/.." && pwd)/scripts/manus-client.sh"
[ -f "$CLIENT" ] || { echo "FAIL: client not found at $CLIENT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP=$(mktemp -d -t manus-atttest.XXXXXX)
SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
set +m   # no job-control chatter when the trap kills the stub server
trap cleanup EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.config/manus-dispatch/state"
export MANUS_API_KEY="test-key-do-not-leak"

TASK=TESTTASK123
PORT_FILE="$TMP/port"
AUTH_LOG="$TMP/cdn-auth.log"

# --- Fake Manus API + CDN ----------------------------------------------------
# /v2/task.listMessages, keyed on task_id:
#   TESTTASK123 -> three attachments: a normal one, a path-traversal filename,
#                  and a duplicate basename
#   PLAINTASK   -> text-only reply, no attachments
#   TRUNCTASK   -> a truncated (HTTP 200) body that cannot be parsed
#   BADCDNTASK  -> four attachments whose links 403 / 404 / truncate / succeed
# /cdn/<name>      -> file bytes; logs whether an x-manus-api-key came with it
# /cdn-403|404/    -> the matching status
# /cdn-short/      -> promises 999 bytes, sends 7, closes (curl: 200 + exit 18)
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, socketserver, sys, urllib.parse

PORT_FILE = sys.argv[1]
AUTH_LOG = sys.argv[2]
BODY = b"| platform | reach |\n| --- | --- |\n| A | 1 |\n"

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        base = f"http://127.0.0.1:{self.server.server_address[1]}"
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        task = (qs.get("task_id") or [""])[0]
        if path == "/v2/task.listMessages" and task == "PLAINTASK":
            self._json({
                "ok": True,
                "messages": [
                    {"type": "status_update", "id": "s1",
                     "status_update": {"agent_status": "stopped"}},
                    {"type": "assistant_message", "id": "a1",
                     "assistant_message": {"content": "No files here."}},
                ],
                "has_more": False,
            })
            return
        # A truncated (but 200) listMessages body: exercises the parse-failure
        # path, which must NOT degrade to "no attachments".
        if path == "/v2/task.listMessages" and task == "TRUNCTASK":
            b = b'{"ok":true,"messages":[{"type":"assist'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        # An attachment whose CDN link has expired (403) and one that 404s.
        if path == "/v2/task.listMessages" and task == "BADCDNTASK":
            self._json({
                "ok": True,
                "messages": [
                    {"type": "status_update", "id": "s1",
                     "status_update": {"agent_status": "stopped"}},
                    {"type": "assistant_message", "id": "a1", "assistant_message": {
                        "content": "Attached.",
                        "attachments": [
                            {"type": "file", "filename": "expired.md",
                             "content_type": "text/markdown",
                             "url": f"{base}/cdn-403/expired"},
                            {"type": "file", "filename": "gone.md",
                             "content_type": "text/markdown",
                             "url": f"{base}/cdn-404/gone"},
                            {"type": "file", "filename": "truncated.md",
                             "content_type": "text/markdown",
                             "url": f"{base}/cdn-short/truncated"},
                            {"type": "file", "filename": "good.md",
                             "content_type": "text/markdown",
                             "url": f"{base}/cdn/good"},
                        ]}},
                ],
                "has_more": False,
            })
            return
        if path == "/v2/task.listMessages":
            self._json({
                "ok": True,
                "messages": [
                    {"type": "status_update", "id": "s1",
                     "status_update": {"agent_status": "stopped"}},
                    {"type": "assistant_message", "id": "a1", "assistant_message": {
                        "content": "Done. The table is attached.",
                        "attachments": [
                            {"type": "file", "filename": "kinematic_specs.md",
                             "content_type": "text/markdown; charset=utf-8",
                             "url": f"{base}/cdn/specs?Signature=abc"},
                            {"type": "file", "filename": "../../escaped.md",
                             "content_type": "text/markdown",
                             "url": f"{base}/cdn/escaped?Signature=abc"},
                            # Same basename as the first, different URL: must
                            # not silently overwrite it.
                            {"type": "file", "filename": "kinematic_specs.md",
                             "content_type": "text/markdown",
                             "url": f"{base}/cdn/specs-v2?Signature=abc"},
                        ]}},
                ],
                "has_more": False,
            })
            return
        if path.startswith("/cdn-403/"):
            self.send_response(403)
            self.end_headers()
            return
        if path.startswith("/cdn-404/"):
            self.send_response(404)
            self.end_headers()
            return
        # Promises 999 bytes, sends 7, then closes: curl reports HTTP 200 with a
        # non-zero exit. The client must discard the stub, not count it.
        if path.startswith("/cdn-short/"):
            self.send_response(200)
            self.send_header("Content-Type", "text/markdown")
            self.send_header("Content-Length", "999")
            self.end_headers()
            self.wfile.write(b"partial")
            self.close_connection = True
            return
        if path.startswith("/cdn/"):
            with open(AUTH_LOG, "a") as fh:
                fh.write(("KEY_SENT" if self.headers.get("x-manus-api-key")
                          else "NO_KEY") + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "text/markdown")
            self.send_header("Content-Length", str(len(BODY)))
            self.end_headers()
            self.wfile.write(BODY)
            return
        self.send_response(404)
        self.end_headers()

with socketserver.TCPServer(("127.0.0.1", 0), H) as httpd:
    with open(PORT_FILE, "w") as fh:
        fh.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY

python3 "$TMP/server.py" "$PORT_FILE" "$AUTH_LOG" &
SRV_PID=$!

for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || { echo "FAIL: stub server never bound a port"; exit 1; }
export MANUS_BASE_URL="http://127.0.0.1:$(cat "$PORT_FILE")"

fails=0
check() { # check <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"; fails=$((fails + 1))
  fi
}

echo "== files =="
FILES_OUT=$(bash "$CLIENT" files "$TASK" 2>"$TMP/files.err")
if ! printf '%s' "$FILES_OUT" | jq empty 2>/dev/null; then
  echo "  FAIL: files did not emit valid JSON"; cat "$TMP/files.err"; fails=$((fails + 1))
fi
check "files reports 3 attachments" "$(printf '%s' "$FILES_OUT" | jq -r '.count')" "3"
check "first filename surfaced" \
  "$(printf '%s' "$FILES_OUT" | jq -r '.attachments[0].filename')" "kinematic_specs.md"
check "content_type surfaced" \
  "$(printf '%s' "$FILES_OUT" | jq -r '.attachments[0].content_type')" \
  "text/markdown; charset=utf-8"
check "url surfaced" \
  "$(printf '%s' "$FILES_OUT" | jq -r '.attachments[0].url | startswith("http")')" "true"

echo "== download =="
OUT_DIR="$TMP/out"
DL_OUT=$(bash "$CLIENT" download "$TASK" --out "$OUT_DIR" 2>"$TMP/dl.err")
check "download reports 3 files" "$(printf '%s' "$DL_OUT" | jq -r '.count')" "3"
check "download ok" "$(printf '%s' "$DL_OUT" | jq -r '.ok')" "true"
if [ -s "$OUT_DIR/kinematic_specs.md" ]; then
  echo "  ok: attachment bytes written to disk"
else
  echo "  FAIL: $OUT_DIR/kinematic_specs.md missing or empty"; fails=$((fails + 1))
fi
check "downloaded bytes match served body" \
  "$(head -1 "$OUT_DIR/kinematic_specs.md" 2>/dev/null)" "| platform | reach |"

# The traversal filename must be flattened into OUT_DIR, never written above it.
if [ -e "$TMP/escaped.md" ] || [ -e "$TMP/out/../../escaped.md" ]; then
  echo "  FAIL: traversal filename escaped --out"; fails=$((fails + 1))
else
  echo "  ok: traversal filename did not escape --out"
fi
check "traversal filename flattened into out_dir" \
  "$(ls "$OUT_DIR" | grep -c 'escaped.md')" "1"

# A duplicate basename must be suffixed, not overwritten — otherwise half the
# deliverable is silently lost, the same class of bug as issue #6 itself.
check "duplicate basename suffixed, not overwritten" \
  "$(ls "$OUT_DIR" | grep -c '^kinematic_specs')" "2"
check "both duplicate copies have bytes" \
  "$(find "$OUT_DIR" -name 'kinematic_specs*' -size +0 | wc -l | tr -d ' ')" "2"

echo "== api key not leaked to the CDN host =="
if grep -q KEY_SENT "$AUTH_LOG" 2>/dev/null; then
  echo "  FAIL: x-manus-api-key was sent to the CDN host"; fails=$((fails + 1))
else
  echo "  ok: CDN requests carried no api key"
fi
check "CDN was actually hit for every attachment" "$(grep -c NO_KEY "$AUTH_LOG")" "3"

echo "== result surfaces the attachments =="
# result needs a state file to do its bookkeeping; mimic what create writes.
jq -nc --arg id "$TASK" '{task_id:$id, title:"Kinematic specs", query:"q",
  task_url:"https://manus.ai/app/x", started_at:"2026-08-05T00:00:00Z", status:"running"}' \
  > "$HOME/.config/manus-dispatch/state/$TASK.json"
RES_OUT=$(bash "$CLIENT" result "$TASK" 2>"$TMP/res.err")
check "result reports attachment_count" \
  "$(printf '%s' "$RES_OUT" | jq -r '.attachment_count')" "3"
check "result carries a download hint" \
  "$(printf '%s' "$RES_OUT" | jq -r '.attachment_hint | contains("download")')" "true"
check "state file records attachments" \
  "$(jq -r '.attachments | length' "$HOME/.config/manus-dispatch/state/$TASK.json")" "3"
# Signed URLs expire, so they must NOT be persisted into the state file.
check "state file does not persist expiring urls" \
  "$(jq -r '[.attachments[] | has("url")] | any' "$HOME/.config/manus-dispatch/state/$TASK.json")" \
  "false"

echo "== status surfaces the attachments =="
ST_OUT=$(bash "$CLIENT" status "$TASK" 2>"$TMP/st.err")
check "status reports attachment_count" \
  "$(printf '%s' "$ST_OUT" | jq -r '.attachment_count')" "3"

echo "== obsidian note records attachments (filenames, not expiring urls) =="
# Stand up the minimum the client needs to resolve a vault: obsidian_enabled in
# our config, plus a fake obsidian-plugin cache carrying vault_path.
VAULT="$TMP/vault"
mkdir -p "$VAULT"
printf 'obsidian_enabled = true\n' > "$HOME/.config/manus-dispatch/config.toml"
OBS="$HOME/.claude/plugins/cache/nhangen/obsidian/0.9.9"
mkdir -p "$OBS"
printf -- '---\nvault_path: %s\ndaily_path: Daily/\n---\n' "$VAULT" > "$OBS/obsidian.local.md"

# Re-file the task (clear the note marker so cmd_result writes fresh).
jq -nc --arg id "$TASK" '{task_id:$id, title:"Kinematic specs", query:"q",
  task_url:"https://manus.ai/app/x", started_at:"2026-08-05T00:00:00Z", status:"running"}' \
  > "$HOME/.config/manus-dispatch/state/$TASK.json"
OBS_OUT=$(bash "$CLIENT" result "$TASK" 2>"$TMP/obs.err")
NOTE=$(printf '%s' "$OBS_OUT" | jq -r '.obsidian_note // ""')
if [ -n "$NOTE" ] && [ -f "$NOTE" ]; then
  echo "  ok: research note written ($NOTE)"
else
  echo "  FAIL: no research note written"; cat "$TMP/obs.err"; fails=$((fails + 1))
fi
check "note has an Attachments section" \
  "$(grep -c '^## Attachments' "$NOTE" 2>/dev/null || true)" "1"
check "note lists every attachment filename" \
  "$(grep -c '^- `' "$NOTE" 2>/dev/null || true)" "3"
check "note names the primary attachment" \
  "$(grep -c 'kinematic_specs.md' "$NOTE" 2>/dev/null || true)" "2"
check "note gives the download command" \
  "$(grep -c "download $TASK" "$NOTE" 2>/dev/null || true)" "1"
# An expiring signed URL must never be pasted into the vault — it rots.
check "note embeds no signed url" \
  "$(grep -c 'Signature=' "$NOTE" 2>/dev/null || true)" "0"
check "daily note flags the attachment" \
  "$(grep -c '📎' "$VAULT/Daily/$(date +%Y-%m-%d).md" 2>/dev/null || true)" "1"

# Restore: later cases assume no obsidian filing.
printf '' > "$HOME/.config/manus-dispatch/config.toml"

echo "== an unreadable response is an error, NOT 'no attachments' =="
# The whole point of issue #6 is a payload silently going missing. A body we
# can't parse must never be reported as a task that simply has no files.
TRUNC_OUT=$(bash "$CLIENT" files TRUNCTASK 2>"$TMP/trunc.err")
trunc_rc=$?
check "files exits non-zero on an unparseable body" \
  "$([ "$trunc_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
# No JSON at all is the right answer here: emitting {"count":0} would be the
# lie. Accept empty output, reject any object carrying a count.
check "files emits no result object on an unparseable body" \
  "$([ -z "$TRUNC_OUT" ] && echo empty || printf '%s' "$TRUNC_OUT" | jq -r '.count // "no-count"')" \
  "empty"
check "the parse failure is explained on stderr" \
  "$(grep -c 'could not parse attachments' "$TMP/trunc.err" || true)" "1"
TDL_OUT=$(bash "$CLIENT" download TRUNCTASK --out "$TMP/truncout" 2>/dev/null)
tdl_rc=$?
check "download exits non-zero on an unparseable body" \
  "$([ "$tdl_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "download writes nothing on an unparseable body" \
  "$(ls "$TMP/truncout" 2>/dev/null | wc -l | tr -d ' ')" "0"
TRES_RC=0
bash "$CLIENT" result TRUNCTASK >/dev/null 2>&1 || TRES_RC=$?
check "result exits non-zero on an unparseable body" \
  "$([ "$TRES_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

echo "== failed downloads are reported as failures, not skipped silently =="
BAD_DIR="$TMP/badout"
BAD_OUT=$(bash "$CLIENT" download BADCDNTASK --out "$BAD_DIR" 2>"$TMP/bad.err")
bad_rc=$?
check "download exits non-zero when some attachments fail" \
  "$([ "$bad_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "download reports ok:false" "$(printf '%s' "$BAD_OUT" | jq -r '.ok')" "false"
check "download counts 3 failures" "$(printf '%s' "$BAD_OUT" | jq -r '.failed')" "3"
check "download still saves the one good file" \
  "$(printf '%s' "$BAD_OUT" | jq -r '.count')" "1"
check "expired link explained as expiry" \
  "$(grep -c 'signed URL has expired' "$TMP/bad.err" || true)" "1"
# A 200 that dies mid-body must not leave a partial file counted as delivered.
check "truncated transfer called out" \
  "$(grep -c 'transfer incomplete' "$TMP/bad.err" || true)" "1"
check "partial file discarded from disk" \
  "$(ls "$BAD_DIR" 2>/dev/null | grep -c 'truncated.md' || true)" "0"
check "only the good file is on disk" \
  "$(ls "$BAD_DIR" | tr '\n' ' ')" "good.md "

echo "== re-downloading overwrites, does not accumulate copies =="
# manus-status re-runs download on every poll; a -2/-3 pile-up would leave
# Claude reading a stale copy.
bash "$CLIENT" download "$TASK" --out "$OUT_DIR" >/dev/null 2>&1
check "second download leaves the same file count" \
  "$(ls "$OUT_DIR" | wc -l | tr -d ' ')" "3"

echo "== a task with no attachments is not an error =="
PLAIN_FILES=$(bash "$CLIENT" files PLAINTASK 2>"$TMP/plainfiles.err")
check "files reports 0 on a text-only task" \
  "$(printf '%s' "$PLAIN_FILES" | jq -r '.count')" "0"
PLAIN_DL=$(bash "$CLIENT" download PLAINTASK --out "$TMP/plainout" 2>"$TMP/plaindl.err")
plain_rc=$?
check "download exits 0 on a text-only task" "$plain_rc" "0"
check "download reports 0 files, ok:true" \
  "$(printf '%s' "$PLAIN_DL" | jq -r '"\(.count) \(.ok)"')" "0 true"

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: all checks green"
  exit 0
else
  echo "FAIL: $fails check(s) failed"
  exit 1
fi
