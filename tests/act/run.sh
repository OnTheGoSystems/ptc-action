#!/usr/bin/env bash
# Behavioural gate: runs the composite action end to end under `act`, against a
# mock PTC API and a stub standing in for create-pull-request. No PTC token, no
# network to PTC, no pull request opened anywhere.
#
#   ./run.sh              # every job
#   ./run.sh dirty        # only the dirty-workspace job
#   ./run.sh pr           # only the pull_request refusal
#   ./run.sh <job-name>   # one job by name, on push
#
# Requires: act >= 0.2.89, a running docker daemon, and the
# catthehacker/ubuntu:act-latest runner image (pulled once, ~1.5 GB). This is a
# local gate; CI runs tests/translation-paths.test.sh, which needs neither.
#
# The working copy is assembled OUTSIDE this repository. The fixture has to be
# a git repository of its own - the action asks git what it wrote - and a
# nested .git inside ptc-action would be committed as a gitlink.
#
# NOTE on --container-daemon-socket - : with Colima the daemon socket lives
# under ~/.colima and act's attempt to bind-mount it into the job container
# fails. The action needs no docker socket, so it is not mounted.
#
# NOTE on the mock's network: act runs job containers with --network host,
# which under Colima is the VM's network namespace, not macOS. The mock runs in
# a container that is also on --network host, so both see it at 127.0.0.1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${PTC_ACT_WORKDIR:-$HOME/.cache/ptc-action-act}"
RUNNER_IMAGE="${PTC_ACT_RUNNER_IMAGE:-catthehacker/ubuntu:act-latest}"
MOCK_NAME="ptc-action-mock"
MODE="${1:-all}"

# The pin lives in action.yml; read it from there so an upgrade cannot leave
# the stub addressed to a SHA act will no longer match - it would silently
# clone the real action and open nothing, and the tests would still pass.
CPR_SHA="$(grep -oE 'peter-evans/create-pull-request@[0-9a-f]{40}' "$REPO/action.yml" | head -1 | cut -d@ -f2)"
if [ -z "$CPR_SHA" ]; then
  echo "could not read the create-pull-request pin from action.yml" >&2
  exit 1
fi

# The mock answers the vendored CLI's calls, so a CLI bump can silently leave
# it speaking the wrong protocol. Fail here rather than debug a fixture that
# tests the wrong thing.
# `ptc-cli.sh 1.0.4` as well as `ptc-cli 1.0.4`: the first spelling is what the
# mock's own docstring uses, and matching only the second made this guard skip
# itself silently - which is exactly the failure it exists to prevent.
MOCK_CLI_VERSION="$(grep -oE 'ptc-cli(\.sh)? [0-9]+\.[0-9]+\.[0-9]+' "$HERE/mock_ptc_api.py" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
VENDORED_CLI_VERSION="$(grep -m1 -oE 'VERSION="[^"]+"' "$REPO/ptc-cli.sh" | cut -d'"' -f2)"
if [ -z "$MOCK_CLI_VERSION" ]; then
  echo "could not read the CLI version the mock was written for; the drift guard would be silent" >&2
  exit 1
fi
if [ "$MOCK_CLI_VERSION" != "$VENDORED_CLI_VERSION" ]; then
  echo "the mock was written for ptc-cli $MOCK_CLI_VERSION but $VENDORED_CLI_VERSION is vendored; re-check it before trusting these results" >&2
  exit 1
fi

for tool in act docker git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
done

# --- assemble the working copy ------------------------------------------------
echo "==> assembling the fixture in $WORK"
rm -rf "$WORK"
mkdir -p "$WORK"
cp -R "$HERE/fixture/." "$WORK/"
mkdir -p "$WORK/ptc-action"
# The whole action, not a hand-listed subset: a new file it depends on must not
# be something this script has to be told about.
cp "$REPO/action.yml" "$REPO/ptc-cli.sh" "$WORK/ptc-action/"
cp -R "$REPO/lib" "$WORK/ptc-action/lib"
chmod +x "$WORK/ptc-action/ptc-cli.sh"

git -C "$WORK" init -q -b main
git -C "$WORK" config user.email probe@local
git -C "$WORK" config user.name  probe
git -C "$WORK" add -A
git -C "$WORK" commit -qm "fixture baseline"

# --- the mock PTC API ---------------------------------------------------------
echo "==> (re)starting the mock PTC API"
docker rm -f "$MOCK_NAME" >/dev/null 2>&1
docker create --name "$MOCK_NAME" --network host \
  -e PTC_MOCK_PORT=8787 -e PTC_MOCK_PENDING=1 -e PTC_MOCK_LOCALES=de,fr \
  python:3.12-alpine python /mock_ptc_api.py >/dev/null || exit 1
docker cp "$HERE/mock_ptc_api.py" "$MOCK_NAME:/mock_ptc_api.py" >/dev/null
docker start "$MOCK_NAME" >/dev/null
trap 'docker rm -f "$MOCK_NAME" >/dev/null 2>&1' EXIT

# --- run ---------------------------------------------------------------------
FAILED=()
PASSED=()

# One run in three had a job fail because the mock did not answer - `ptc init`
# then reports "could not identify translatable files", which reads exactly
# like a real failure. Confirm the mock is listening before each job rather
# than let that ambiguity into the results.
wait_for_mock() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if docker exec "$MOCK_NAME" python -c \
         "import socket; socket.create_connection(('127.0.0.1', 8787), 1).close()" \
         >/dev/null 2>&1; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$MOCK_NAME" 2>/dev/null)" != "true" ]; then
      echo "==> the mock died; restarting it"
      docker start "$MOCK_NAME" >/dev/null 2>&1
    fi
    echo "==> waiting for the mock (attempt $attempt)"
    sleep 1
  done
  echo "the mock PTC API never came up; results would be meaningless" >&2
  return 1
}

act_job() {  # act_job <event> <job> [extra args...]
  local event="$1" job="$2"; shift 2
  wait_for_mock || { FAILED+=("$job (mock unavailable)"); return 1; }
  echo
  echo "=============================================================="
  echo "==> $job  (on $event)"
  echo "=============================================================="
  # A fresh working tree per job: one job's dirt is another job's false pass.
  git -C "$WORK" reset -q --hard
  git -C "$WORK" clean -qfd
  if ( cd "$WORK" && act "$event" \
      -W .github/workflows/pr-scope.yml -j "$job" \
      -s PTC_API_TOKEN=mock-token-abcdef \
      --var PTC_API_URL=http://127.0.0.1:8787/api/v1/ \
      --local-repository "peter-evans/create-pull-request@${CPR_SHA}=$HERE/stubs/create-pull-request" \
      -P "ubuntu-latest=$RUNNER_IMAGE" \
      --container-daemon-socket - \
      --pull=false "$@" ); then
    PASSED+=("$job")
  else
    FAILED+=("$job")
  fi
}

case "$MODE" in
  dirty) act_job push dirty-workspace ;;
  pr)    act_job pull_request pull-request-is-refused -e "$HERE/events/pull_request.json" ;;
  all)
    act_job push dirty-workspace
    act_job push output-points-elsewhere
    act_job push nothing-written-opens-no-pull-request
    act_job push push-still-opens-a-pull-request
    act_job pull_request pull-request-is-refused -e "$HERE/events/pull_request.json"
    ;;
  # Anything else is taken as a job name, run on push - handy while writing a
  # new case, and it keeps this script from needing an entry per job.
  *) act_job push "$MODE" ;;
esac

echo
echo "=============================================================="
for j in "${PASSED[@]:-}"; do [ -n "$j" ] && echo "  PASS  $j"; done
for j in "${FAILED[@]:-}"; do [ -n "$j" ] && echo "  FAIL  $j"; done
echo "=============================================================="
[ "${#FAILED[@]}" -eq 0 ]
