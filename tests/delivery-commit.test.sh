#!/usr/bin/env bash
# P4 T14 (R3): the action's "Report the translations-branch commit to PTC" step, read out of action.yml and run against
# the CLI's mock PTC on loopback: it reports the commit create-pull-request made (its head sha, not the work tree's HEAD),
# the pull-request branch, the source commit, and the sha256 of the delivered files AT that commit. Never fails the job.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MOCK="$REPO/../cli/tests/mock_ptc_api.py"
FIXTURE="$REPO/../cli/tests/fixtures/scan-repo"
WORK="$(mktemp -d)"; MOCK_PID=""
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
mkdir -p "$WORK/bodies"
PORT=""
for port in 19217 19227 19237; do
  PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { MOCK_PID=$pid; PORT=$port; break 2; }
    kill -0 "$pid" 2>/dev/null || break; sleep 0.3
  done
  kill "$pid" 2>/dev/null
done
[ -n "$PORT" ] || { echo "mock did not come up"; cat "$WORK/mock.log"; exit 1; }

python3 - "$REPO/action.yml" > "$WORK/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
print(next(s for s in steps if s.get("name") == "Report the translations-branch commit to PTC")["run"])
PY
cp -R "$FIXTURE/." "$WORK/repo/"
g() { git -C "$WORK/repo" -c user.email=t@t -c user.name=t "$@"; }
g init -q -b main && g add -A && g commit -qm source
src=$(g rev-parse HEAD)
g checkout -q -b ptc/translations
printf 'de:\n  hello: "Hallo"\n' > "$WORK/repo/config/locales/de.yml"
g commit -qam "chore(i18n): update translations via PTC [skip translations]"
head=$(g rev-parse HEAD)
want=$(g cat-file blob "$head:config/locales/de.yml" | sha256sum | cut -d' ' -f1)
g checkout -q main   # create-pull-request returns the work tree to the source branch

export GITHUB_OUTPUT="$WORK/gh-output" RUNNER_TEMP="$WORK"
: > "$GITHUB_OUTPUT"
(cd "$WORK/repo" && env -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL PTC_API_TOKEN=project-token ACTION_PATH="$REPO" \
  INPUT_API_URL="http://127.0.0.1:$PORT/api/v1/" INPUT_CONFIG_FILE="" HEAD_SHA="$head" PR_BRANCH=ptc/translations GITHUB_SHA="$src" \
  bash "$WORK/step.sh") > "$WORK/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "the step exits 0"; else fail "rc=$rc $(cat "$WORK/out")"; fi
if python3 - "$WORK/bodies/guide_delivery_commits.json" "$head" "$src" "$want" <<'PY'; then pass "reports the PR head commit, its branch, the source commit and the delivered files' sha256 at that commit"; else fail "body: $(cat "$WORK/bodies/guide_delivery_commits.json" 2>/dev/null)"; fi
import json, sys
d = json.load(open(sys.argv[1]))["body"]
assert d["commit_sha"] == sys.argv[2] and d["source_commit_sha"] == sys.argv[3] and d["branch"] == "ptc/translations", d
assert d["delivered_files_sha"]["config/locales/de.yml"] == sys.argv[4], d
assert "config/locales/en.yml" not in d["delivered_files_sha"], d
PY
if grep -q "Reported the translations-branch commit" "$WORK/out"; then pass "the step log says what PTC matched"; else fail "log: $(cat "$WORK/out")"; fi
# S2-R14 (Eran 2026-10-02): no `ptc validate`; the report is the delivery proof and carries no validate result. PTC's
# recomputed check becomes the step's guide-check outputs, and the log names the proof's effect.
if python3 - "$WORK/bodies/guide_delivery_commits.json" <<'PY'; then pass "the report carries no validate result"; else fail "validate: $(cat "$WORK/bodies/guide_delivery_commits.json" 2>/dev/null)"; fi
import json, sys
assert "validate" not in json.load(open(sys.argv[1]))["body"]
PY
verdict=$(sed -n 's/^guide-check=//p' "$GITHUB_OUTPUT"); cj=$(sed -n 's/^guide-check-json=//p' "$GITHUB_OUTPUT")
if [ "$verdict" = pass ] && [ -s "$cj" ] && grep -q '"verdict"' "$cj"; then pass "PTC's recomputed check is the step's guide-check output ($verdict)"; else fail "outputs: $(cat "$GITHUB_OUTPUT")"; fi
if grep -q "delivery proof: closed" "$WORK/out" && ! grep -q "ptc validate" "$WORK/out"; then pass "the step log says PTC closed the delivery proof"; else fail "log: $(cat "$WORK/out")"; fi
# A second delivery on the branch is reported at its own commit; nothing re-checks the files' content.
g checkout -q ptc/translations
printf 'de:\n  users:\n    greeting: "Hallo!"\n' > "$WORK/repo/config/locales/de.yml"
g commit -qam "chore(i18n): a second delivery"
head2=$(g rev-parse HEAD); g checkout -q main
: > "$GITHUB_OUTPUT"
(cd "$WORK/repo" && env -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL PTC_API_TOKEN=project-token ACTION_PATH="$REPO" \
  INPUT_API_URL="http://127.0.0.1:$PORT/api/v1/" INPUT_CONFIG_FILE="" HEAD_SHA="$head2" PR_BRANCH=ptc/translations GITHUB_SHA="$src" \
  bash "$WORK/step.sh") > "$WORK/out3" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && python3 - "$WORK/bodies/guide_delivery_commits.json" "$head2" <<'PY'; then pass "a second delivery is reported at its own commit, with no validate"; else fail "rc=$rc $(cat "$WORK/out3")"; fi
import json, sys
d = json.load(open(sys.argv[1]))["body"]
assert d["commit_sha"] == sys.argv[2] and "validate" not in d and "config/locales/de.yml" in d["delivered_files_sha"], d
PY
# P4-F3: an untrusted report changes nothing: the log says so and sends no agent to `ptc guide next`.
: > "$GITHUB_OUTPUT"
(cd "$WORK/repo" && env -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL PTC_API_TOKEN=project-token ACTION_PATH="$REPO" \
  INPUT_API_URL="http://127.0.0.1:$PORT/api/v1/" INPUT_CONFIG_FILE="" HEAD_SHA="$head2" PR_BRANCH=ptc/untrusted GITHUB_SHA="$src" \
  bash "$WORK/step.sh") > "$WORK/out4" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q "delivery proof: none - an untrusted report" "$WORK/out4" && ! grep -q "ptc guide next" "$WORK/out4"; then
  pass "an untrusted report: the log says the proof did not change and names no next agent step"
else fail "untrusted case: rc=$rc $(cat "$WORK/out4")"; fi
# AGD-11: the config's api_url (a lab PTC) wins over the api-url input's DEFAULT; production is unreachable here.
rm -f "$WORK/bodies/guide_delivery_commits.json"
cp "$WORK/repo/.ptc-config.yml" "$WORK/cfg.bak"
printf 'api_url: http://127.0.0.1:%s/api/v1/\n' "$PORT" >> "$WORK/repo/.ptc-config.yml"
(cd "$WORK/repo" && env -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
  no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost PTC_API_TOKEN=project-token ACTION_PATH="$REPO" \
  INPUT_API_URL="https://app.ptc.wpml.org/api/v1/" INPUT_CONFIG_FILE="" HEAD_SHA="$head" PR_BRANCH=ptc/translations GITHUB_SHA="$src" \
  bash "$WORK/step.sh") > "$WORK/out5" 2>&1; rc=$?
cp "$WORK/cfg.bak" "$WORK/repo/.ptc-config.yml"
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["body"]["commit_sha"]==sys.argv[2]' "$WORK/bodies/guide_delivery_commits.json" "$head" 2>/dev/null; then
  pass "config api_url + default input: the translations-branch report reaches the config's PTC"
else fail "config api_url ignored: rc=$rc $(tail -5 "$WORK/out5")"; fi
(cd "$WORK/repo" && PTC_API_TOKEN=project-token ACTION_PATH="$REPO" INPUT_API_URL="http://127.0.0.1:1/api/v1/" INPUT_CONFIG_FILE="" \
  HEAD_SHA="$head" PR_BRANCH=ptc/translations GITHUB_SHA="$src" bash "$WORK/step.sh") > "$WORK/out2" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q "report skipped (the run continues)" "$WORK/out2"; then pass "PTC unreachable: a notice, never a failure"; else fail "unreachable rc=$rc $(cat "$WORK/out2")"; fi

echo; echo "delivery-commit: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
