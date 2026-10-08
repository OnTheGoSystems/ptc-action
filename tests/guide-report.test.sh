#!/usr/bin/env bash
# The agent-guide report, without docker: runs the action's own "Translate with
# PTC" script (read out of action.yml) in a copy of the act fixture, against
# tests/act/mock_ptc_api.py on loopback, and asserts the /guide/action_runs body.
# The same assertion runs under act in tests/act (job guide-action-run-is-posted).
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
for port in 18987 18997 19007; do
  PTC_MOCK_PORT="$port" PTC_MOCK_LOG="$WORK/journal.log" python3 "$HERE/act/mock_ptc_api.py" >>"$WORK/mock.log" 2>&1 &
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

python3 - "$REPO/action.yml" > "$WORK/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
print(next(s for s in steps if s.get("id") == "ptc")["run"])
PY
cp -R "$HERE/act/fixture/." "$WORK/repo/" 2>/dev/null || { mkdir -p "$WORK/repo"; cp -R "$HERE/act/fixture/." "$WORK/repo/"; }
git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" -c user.email=t@t -c user.name=t add -A
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm fixture
SHA="$(git -C "$WORK/repo" rev-parse HEAD)"

run_step() {  # run_step <guide-report>   (extra env: OIDC_URL -> ACTIONS_ID_TOKEN_REQUEST_URL, STEP_API_URL -> INPUT_API_URL)
  ( cd "$WORK/repo" && env ${OIDC_URL:+ACTIONS_ID_TOKEN_REQUEST_URL="$OIDC_URL" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token} PTC_API_TOKEN=mock-token-abcdef INPUT_API_URL="${STEP_API_URL:-$API}" ACTION_PATH="$REPO" \
      INPUT_CONFIG_FILE="" INPUT_SOURCE_LOCALE="" INPUT_PATTERNS="" INPUT_FILE_TAG_NAME="" \
      INPUT_MONITOR_INTERVAL=1 INPUT_MONITOR_MAX_ATTEMPTS=5 INPUT_CREATE_PR=false \
      INPUT_GUIDE_REPORT="$1" GITHUB_OUTPUT="$WORK/out" GITHUB_SHA="$SHA" GITHUB_REF_NAME=main \
      bash -e "$WORK/step.sh" ) >"$WORK/step.log" 2>&1
}

if run_step true; then pass "action step exits 0"; else fail "action step exits 0: $(tail -20 "$WORK/step.log")"; fi
curl -fsS "${API%/}/guide/action_runs/last" -o "$WORK/run.json" 2>/dev/null
if SHA="$SHA" python3 - "$WORK/run.json" <<'PY'
import json, os, re, sys
d = json.load(open(sys.argv[1]))
b, h = d["body"], d["headers"]
assert sorted(b) == ["branch", "ci_id_token", "commit_sha", "config", "delivered_files_sha", "files_sample", "files_sha", "project_id", "repo_prefix", "scan"], sorted(b)
assert b["repo_prefix"] == ""
assert b["ci_id_token"] is None, "no identity token in this run"
assert b["commit_sha"] == os.environ["SHA"] and b["branch"] == "main"
assert b["scan"]["schema"] == 2 and b["scan"]["repo"]["head_sha"] == os.environ["SHA"]
assert b["config"]["source_locale"] == "en" and b["config"]["files"], b["config"]
assert sorted(b["files_sample"]) == ["locales/en.json"], sorted(b["files_sample"])
assert b["delivered_files_sha"] == {}, b["delivered_files_sha"]
assert h["Authorization"] == "Bearer mock-token-abcdef" and re.match(r"^\d+\.\d+\.\d+$", h["X-PTC-CLI-Version"])
PY
then pass "POST /guide/action_runs body shape (commit, branch, parsed config, scan, files_sample)"; else fail "action_runs body: $(head -c 600 "$WORK/run.json")"; fi
if grep -q "Reported this run to PTC" "$WORK/step.log"; then pass "the step logs the report"; else fail "no report line in the step log"; fi
if grep -q "No CI identity token" "$WORK/step.log"; then pass "no identity token -> the step says the run is unverified provenance"; else fail "no unverified notice"; fi

# GitHub OIDC (workflow has permissions: id-token: write): the step requests the token with audience ptc.
if OIDC_URL="${API%/}/_oidc/token" run_step true; then pass "action step with an identity token exits 0"; else fail "oidc step: $(tail -20 "$WORK/step.log")"; fi
curl -fsS "${API%/}/guide/action_runs/last" -o "$WORK/run.json" 2>/dev/null
if python3 - "$WORK/run.json" <<'PY'
import base64, json, sys
t = json.load(open(sys.argv[1]))["body"]["ci_id_token"]
c = t.split(".")[1]
assert json.loads(base64.urlsafe_b64decode(c + "=" * (-len(c) % 4)))["aud"] == "ptc"
PY
then pass "the GitHub identity token (aud ptc) is posted as ci_id_token"; else fail "ci_id_token: $(head -c 400 "$WORK/run.json")"; fi

# AGD-11: a served config's api_url (a lab PTC) wins over the api-url input's DEFAULT, for every call the step makes
# (report, check, translation); an explicit non-default input still wins over the config. Production is made
# unreachable (every https request goes to a dead proxy), so a call that ignored the config fails instead of leaving.
PROD="https://app.ptc.wpml.org/api/v1/"
with_config_api_url() {  # .ptc-config.yml names api_url: $1; the mock's request journal starts empty
  sed -i '/^api_url:/d' "$WORK/repo/.ptc-config.yml"
  printf 'api_url: %s\n' "$1" >> "$WORK/repo/.ptc-config.yml"
  : > "$WORK/journal.log"
}
journal_has() { grep -q "^$1" "$WORK/journal.log"; }
export https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
with_config_api_url "$API"
if STEP_API_URL="$PROD" INPUT_GUIDE_CHECK=true PTC_GUIDE_SESSION_ID=7 run_step true; then pass "config api_url + default input: the step succeeds against the config's PTC"; else fail "config api_url ignored: $(tail -8 "$WORK/step.log")"; fi
for call in "POST /guide/action_runs" "POST /guide/check" "POST /source_files"; do
  if journal_has "$call"; then pass "config api_url + default input: $call reaches the config's PTC"; else fail "$call did not reach the config's PTC: $(cat "$WORK/journal.log")"; fi
done
with_config_api_url "http://127.0.0.1:1/api/v1/"
if STEP_API_URL="$API" INPUT_GUIDE_CHECK=true PTC_GUIDE_SESSION_ID=7 run_step true && journal_has "POST /guide/action_runs" && journal_has "POST /guide/check" && journal_has "POST /source_files"; then
  pass "an explicit non-default api-url input wins over the config"
else fail "explicit input lost: $(cat "$WORK/journal.log") $(tail -8 "$WORK/step.log")"; fi
sed -i '/^api_url:/d' "$WORK/repo/.ptc-config.yml"
unset https_proxy HTTPS_PROXY no_proxy NO_PROXY

# The guide being off (404) or unreachable must not fail the translation.
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
PTC_MOCK_PORT="$PORT" python3 - "$HERE/act/mock_ptc_api.py" >>"$WORK/mock.log" 2>&1 <<'PY' &
import runpy, sys
sys.argv = [sys.argv[1]]
src = open(sys.argv[0]).read().replace('if route == "guide/action_runs":', 'if route == "guide/action_runs" and False:')
exec(compile(src, sys.argv[0], "exec"), {"__name__": "__main__"})
PY
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.4; done
if run_step true; then pass "guide off (404) does not fail the run"; else fail "guide off fails the run: $(tail -20 "$WORK/step.log")"; fi
if grep -q "PTC guide report skipped" "$WORK/step.log"; then pass "the skip is logged as a notice"; else fail "no skip notice"; fi
if run_step false && ! grep -q "guide" "$WORK/step.log"; then pass "guide-report: false skips the report"; else fail "guide-report false: $(grep -i guide "$WORK/step.log")"; fi

echo; echo "guide-report: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
