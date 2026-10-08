#!/usr/bin/env bash
# P4 (R2 check-first, R4 findings comment), without docker: runs the action's own "Translate with PTC" step and its
# "Comment the agent-guide findings" step (read out of action.yml) against tests/act/mock_ptc_api.py on loopback, with
# a guide/check route patched in and `gh` shimmed. Asserts: the check runs BEFORE the translation (mock journal order),
# a failing check never stops the translation, the step exposes the check JSON, and the comment step posts ONE comment,
# then updates it in place, and stays silent when PTC's project setting turns it off.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
MOCK_PID=""
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }

PORT=""
for port in 19017 19027 19037; do
  PTC_MOCK_PORT="$port" python3 - "$HERE/act/mock_ptc_api.py" >>"$WORK/mock.log" 2>&1 <<'PY' &
import sys
sys.argv = [sys.argv[1]]
check = '''if route == "guide/check":
            return self._json(200, {"verdict": "fail", "reasons": [{"code": "under_specified_string", "message": "app/x.js:3: new string `a.b` has no description; next: run `ptc guide next --session-id 7`"}],
                                    "reasons_total": 1, "notes": [{"code": "carried_string", "message": "n"}], "notes_total": 1,
                                    "comment": {"enabled": COMMENT_ON, "marker": "<!-- ptc-agent-guide-findings -->", "body": "<!-- ptc-agent-guide-findings -->\\\\nfindings"}})
        if route == "guide/action_runs":'''
import os
src = open(sys.argv[0]).read().replace('if route == "guide/action_runs":', check, 1)
src = src.replace("def journal(line):", "COMMENT_ON = os.environ.get('MOCK_COMMENT', '1') == '1'\ndef journal(line):", 1)
exec(compile("import os\n" + src, sys.argv[0], "exec"), {"__name__": "__main__"})
PY
  pid=$!
  for _ in $(seq 1 30); do
    if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null; then
      MOCK_PID=$pid; PORT=$port; break 2
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.4
  done
  kill "$pid" 2>/dev/null
done
[ -n "$PORT" ] || { echo "mock did not come up"; cat "$WORK/mock.log"; exit 1; }
API="http://127.0.0.1:$PORT/api/v1/"

python3 - "$REPO/action.yml" "$WORK" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
open(sys.argv[2] + "/step.sh", "w").write(next(s for s in steps if s.get("id") == "ptc")["run"])
open(sys.argv[2] + "/comment.sh", "w").write(next(s for s in steps if s["name"].startswith("Comment the agent-guide findings"))["run"])
PY
mkdir -p "$WORK/repo" && cp -R "$HERE/act/fixture/." "$WORK/repo/"
git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" -c user.email=t@t -c user.name=t add -A
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm fixture
SHA="$(git -C "$WORK/repo" rev-parse HEAD)"

: > "$WORK/out"
if ( cd "$WORK/repo" && env PTC_API_TOKEN=mock-token-abcdef INPUT_API_URL="$API" ACTION_PATH="$REPO" PTC_GUIDE_SESSION_ID=7 \
      INPUT_CONFIG_FILE="" INPUT_SOURCE_LOCALE="" INPUT_PATTERNS="" INPUT_FILE_TAG_NAME="" \
      INPUT_MONITOR_INTERVAL=1 INPUT_MONITOR_MAX_ATTEMPTS=5 INPUT_CREATE_PR=false INPUT_GUIDE_REPORT=true INPUT_GUIDE_CHECK=true \
      GITHUB_OUTPUT="$WORK/out" GITHUB_SHA="$SHA" GITHUB_REF_NAME=main bash -e "$WORK/step.sh" ) >"$WORK/step.log" 2>&1; then
  pass "a failing check never stops the translation (step exits 0)"
else fail "step: $(tail -20 "$WORK/step.log")"; fi
order="$(grep -oE 'POST /(guide/check|source_files|guide/action_runs)' "$WORK/mock.log" | awk '!seen[$0]++' | tr '\n' ' ')"
if [ "$order" = "POST /guide/action_runs POST /guide/check POST /source_files " ]; then pass "order: report -> check -> translate ($order)"
else fail "order: $order"; fi
if grep -q '^guide-check=fail$' "$WORK/out"; then pass "guide-check output = fail"; else fail "outputs: $(cat "$WORK/out")"; fi
CHECK_JSON="$(sed -n 's/^guide-check-json=//p' "$WORK/out")"
if [ -s "$CHECK_JSON" ]; then pass "the check JSON is exposed to the comment step"; else fail "no guide-check-json"; fi
if grep -q "note: n" "$WORK/step.log"; then pass "carried-string notes are printed in the step log"; else fail "no note in the log"; fi

# gh shim: comments live in a file; `gh api ... comments --jq` lists the ids carrying the marker.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
prev=""; for a in "$@"; do [ "$prev" = "--input" ] && cp "$a" "$GH_LOG.body"; prev="$a"; done
case "$*" in
  *"-X POST"*) echo 101 > "$GH_STATE" ;;
  *"-X PATCH"*) : ;;
  *"--jq"*) [ -s "$GH_STATE" ] && cat "$GH_STATE" ;;
esac
exit 0
SHIM
chmod +x "$WORK/bin/gh"
run_comment() {
  ( env PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log" GH_STATE="$WORK/gh.state" GH_TOKEN=t PR_NUMBER=5 CHECK_JSON="$CHECK_JSON" \
      PR_BRANCH=ptc/translations GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r RUNNER_TEMP="$WORK" bash "$WORK/comment.sh" ) >"$WORK/comment.log" 2>&1
}
if run_comment && grep -q -- "-X POST repos/o/r/issues/5/comments" "$WORK/gh.log"; then pass "first run posts one comment"; else fail "post: $(cat "$WORK/gh.log" "$WORK/comment.log")"; fi
: > "$WORK/gh.log"; if run_comment && grep -q -- "-X PATCH repos/o/r/issues/comments/101" "$WORK/gh.log" && ! grep -q -- "-X POST" "$WORK/gh.log"; then pass "second run updates the same comment in place"; else fail "update: $(cat "$WORK/gh.log")"; fi
if python3 - "$WORK/gh.log.body" <<'PY'; then pass "the posted body is PTC's comment plus the auto-merge settings link and the fetch command"; else fail "body: $(cat "$WORK/gh.log.body")"; fi
import json, sys
b = json.load(open(sys.argv[1]))["body"]
assert b.startswith("<!-- ptc-agent-guide-findings -->"), b
assert "#managing-auto-merge" in b and "#enabling-auto-merge" in b and "/o/r/settings" not in b and "git fetch origin ptc/translations" in b, b
PY
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d['comment']['enabled']=False; json.dump(d, open(sys.argv[1],'w'))" "$CHECK_JSON"
: > "$WORK/gh.log"; if run_comment && [ ! -s "$WORK/gh.log" ] && grep -q "off for this project" "$WORK/comment.log"; then pass "project setting off -> no gh call, a notice instead"; else fail "off: $(cat "$WORK/gh.log" "$WORK/comment.log")"; fi

echo; echo "guide-check: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
