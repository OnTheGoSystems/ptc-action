# PTC Translate

> **Source of truth: `action/` in `ci18n/private-translation-cloud`.**
> This directory is where the action is developed and gated (`action-tests`
> and `component-vendor-check` in `.gitlab-ci/component-tests.yml`). It is
> published to <https://github.com/OnTheGoSystems/ptc-action> by the release
> job on tags matching `action/vX.Y.Z` (cut by hand on `release`; the floating `v1` is moved onto the same commit); the GitHub repository is a publish
> target, not a place to commit. `ptc-cli.sh` here is vendored from `cli/`.

Translate your source files with **[Private Translation Cloud](https://ptc.wpml.org) (WPML)** straight from CI — and get the results back as a self-updating pull request on every source push. PTC never touches your repo; the action runs the pinned [`ptc-cli`](https://github.com/OnTheGoSystems/ptc-cli) in **your** pipeline and your own token opens the PR.

- **GitHub:** a composite action, used straight from this repository — `uses: OnTheGoSystems/ptc-action@v1`
- **GitLab:** an inline job that `ptc init` prints for you — see [below](#quick-start-gitlab-cicd)

There is no GitHub Marketplace listing. `uses:` resolves against the repository, so the reference above works without one.

This action **vendors** [`ptc-cli` v1.3.1](https://github.com/OnTheGoSystems/ptc-cli/tree/v1.3.1) inside the action repo, so it never runs `main` at job time — the script that ships with a given action tag is the script that runs.

---

## Quick start (GitHub Actions)

**1. Get a token.** Grab your PTC API token (your agent token when the agent guide set this repository up; a project token otherwise). A config is optional: with none, the action detects your layout at run time (see [Inputs](#inputs-github-action)). To see and commit the detected layout up front, run [`ptc init`](https://github.com/OnTheGoSystems/ptc-cli) in a checkout of your repo — it needs no token — and commit the `.ptc-config.yml` it writes.

**2. Add secrets.** Repo → Settings → Secrets and variables → Actions:
- `PTC_API_TOKEN` — your PTC API token (**required**): your agent token (one secret for every product in the repository) or a project token.
- `PTC_PR_TOKEN` — *(recommended)* a PAT or GitHub App token so the translation PR triggers your other CI checks. A bare `GITHUB_TOKEN`-opened PR does **not** trigger downstream workflows.

**3. Add the workflow** — `.github/workflows/translate.yml`:

```yaml
name: Translate
on:
  push:
    branches: [main]
    paths: ['locales/en.json']   # trigger only on SOURCE changes → loop-safe
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write
  id-token: write   # identity token: proves to PTC's agent guide that this CI ran the commit

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 2   # HEAD's parent: lets the run name the files its commit changed (agent guide)
      - uses: OnTheGoSystems/ptc-action@v1
        with:
          api-token: ${{ secrets.PTC_API_TOKEN }}
          create-pr: true
          pr-token: ${{ secrets.PTC_PR_TOKEN }}
```

`api-token` is the only input you have to pass. Add `config-file: .ptc-config.yml` only to point at a config somewhere other than the repository root — one committed at the root is picked up on its own.

> ⚠️ **One-time setting for `create-pr`:** enable **Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests"**. This is the #1 silent first-run failure.

> **Self-hosted runners:** `create-pr` runs `peter-evans/create-pull-request` v8, which needs Node 24 — Actions Runner **v2.327.1 or later**. GitHub-hosted runners already satisfy this.

> **`create-pr` needs a branch to open the pull request against**, so it runs on `push`, `schedule` and a `workflow_dispatch` from a branch. On a `pull_request` or `pull_request_target` event the run sits on GitHub's internal merge ref, and the translations it produces cover strings that exist in neither the base nor the head branch on its own — so the action **fails the step** with an explanation rather than open a pull request against a branch that never had them. The same applies to `pull_request_target` (that event holds a write-scoped token while the workspace can contain a fork's files), to `merge_group` (the queue branch is deleted when the queue resolves) and to a tag or `release` (a tag is not a base branch). Anything else running from a branch is accepted. Translate on a push to your source branch, or set `create-pr: false` on those events.

> **The pull request is scoped to what the translation run wrote.** The action records the working tree before it starts and stages only what appeared or changed afterwards, so a job that installs or builds before this step does not ship its lockfile or its `dist/` under a translations title. If a run writes nothing, no pull request is opened. Two limits worth knowing: anything your job had already `git add`-ed is part of the commit regardless (the commit takes the whole index), and a source file your job regenerates *before* this step is not part of it — if your pipeline extracts strings and then translates in the same job, commit the extracted source yourself, or the pull request will carry translations for strings the base branch does not have.

## Quick start (GitLab CI/CD)

There is no GitLab component. `include: component:` is resolved by **your own** GitLab — the `$CI_SERVER_FQDN` in a component address is always your server — so a component we publish on one instance is unreachable from gitlab.com and from every self-hosted instance. Instead, `ptc init` prints a self-contained job you paste into `.gitlab-ci.yml`:

```yaml
ptc-translate:
  stage: deploy
  image: alpine:3.22
  # A first translation of a large project outlives GitLab's default 1 h job limit (CI-16), so the job asks for 3 h; the
  # project's timeout and the runner's maximum can still shorten it. The CLI reads the job's real limit (CI_JOB_TIMEOUT)
  # and stops 10 minutes before it, or at its own 45-minute bound (monitor_max_minutes in .ptc-config.yml), delivers
  # what finished and exits 7. PTC keeps translating; the next run delivers the rest and translates nothing again.
  timeout: 3h
  # The preflight writes the CI-time limit note here (balance short of the census); the merge request description
  # below carries it, as a GitHub pull request body does.
  variables:
    PTC_LIMIT_NOTE_FILE: /tmp/ptc-limit-note
  # The job's identity token proves to PTC that this CI ran the commit (agent guide provenance).
  id_tokens:
    PTC_ID_TOKEN:
      aud: ptc
  # Loop-safe twice over: the job only runs on a push to the default branch (the
  # translation push targets ptc/translations, so it cannot retrigger this job),
  # and rules: below refuses a commit marked [skip translations].
  rules:
    # The second condition is what keeps this loop-safe, and it has to live
    # here: GitLab evaluates rules: against the commit message, whereas
    # `[skip ci]` in the message would suppress the pipeline of the merge
    # request itself - leaving the translations untested and, with "Pipelines
    # must succeed" enabled, unmergeable.
    - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_MESSAGE !~ /\[skip translations\]/'
  before_script:
    # jq is never invoked by the CLI. unzip is - it unpacks the downloaded
    # translations; alpine already provides it as a busybox applet, so it is
    # named here only to keep the job working if the image is ever changed.
    # git is needed by the push step below, not by the CLI.
    - apk add --no-cache bash curl git unzip python3
  script:
    # Downloaded OUTSIDE the checkout: anything this job writes into the working
    # tree is a file the commit below could sweep into the merge request, and
    # the CLI is 100+ KB of it.
    # Fetched through PTC's CLI door, which counts the download and redirects to the release tag.
    # A CI/CD variable PTC_CLI_URL pins another copy of the CLI (curl accepts
    # file://, e.g. file://$CI_PROJECT_DIR/cli/ptc-cli.sh for the repository's own).
    - curl -fsSL "${PTC_CLI_URL:-https://app.ptc.wpml.org/cli/v1.5.6/ptc-cli.sh}" -o /tmp/ptc-cli.sh
    - chmod +x /tmp/ptc-cli.sh
    - rm -f /tmp/ptc-written /tmp/ptc-limit-note
    # Report the run to PTC's agent guide (scan, config digests, identity token); never fails the job.
    - /tmp/ptc-cli.sh guide action-run --config-file .ptc-config.yml || true
    # Check first (agent guide): PTC reports missing information for this commit; it never withholds the translation.
    # PTC_API_TOKEN (the agent token PTC asks for) comes first; the legacy PTC_ORG_TOKEN is read only without it.
    - if [ -z "${PTC_API_TOKEN:-}" ] && [ -n "${PTC_ORG_TOKEN:-}" ]; then echo "PTC_ORG_TOKEN is deprecated - set the masked CI/CD variable PTC_API_TOKEN (your agent token) instead."; fi
    - PTC_ORG_TOKEN="${PTC_API_TOKEN:-$PTC_ORG_TOKEN}" /tmp/ptc-cli.sh guide check --json --config-file .ptc-config.yml > /tmp/ptc-check.json || true
    # The merge request's description carries PTC's findings (set by the push below; the project setting in PTC turns
    # them off). They are printed here too, so every job log shows them, also when there is nothing new to push.
    - ptc_mr_description="$(/tmp/ptc-cli.sh guide mr-description --file /tmp/ptc-check.json)"
    # Exit 5 = partial: PTC rejected some files or could not be reached for them, and
    # every other file was written.
    # Exit 6 = partial: some files wait in PTC (an over-limit approval, or paused
    # out-of-credit) and every other file was written. Exit 7 = the translation is still running in PTC at the
    # CLI's monitor bound and every finished file was written. Deliver those below,
    # then fail the job at the end with the reason.
    - ptc_rc=0
    - /tmp/ptc-cli.sh --config-file .ptc-config.yml --written-manifest /tmp/ptc-written || ptc_rc=$?
    - if [ "$ptc_rc" -ne 0 ] && [ "$ptc_rc" -ne 5 ] && [ "$ptc_rc" -ne 6 ] && [ "$ptc_rc" -ne 7 ]; then exit "$ptc_rc"; fi
    # Exit 7: the delivery-commit report below tells PTC the run stopped while it was still translating.
    - ptc_stopped=""; if [ "$ptc_rc" -eq 7 ]; then ptc_stopped="--stopped-reason monitor_bound"; fi
    # Pushing needs a token that may write to the repository. CI_JOB_TOKEN can,
    # but ONLY if a maintainer turns on Settings > CI/CD > Job token permissions
    # > "Allow Git push requests to the repository" (GitLab 18.4+, off by
    # default). Otherwise set PTC_GIT_PUSH_TOKEN to a project access token with
    # the write_repository scope, as a masked CI/CD variable.
    # Staged from the manifest, so the merge request carries the translations and
    # nothing else - not this job's downloads, not whatever an earlier step in
    # your pipeline left in the working directory.
    #
    # Exit 1 from git add is tolerated, not cosmetic: if a translation lands on a path your
    # .gitignore covers, git exits 1 while still staging everything else, and
    # GitLab would abort the job on that exit code alone.
    #
    # Staging comes BEFORE the check, and the check reads the index: on the
    # first run the translations are new files, and a plain `git diff` only
    # looks at tracked ones - it would report "nothing changed", skip the push,
    # and leave a green job that produced no merge request.
    #
    # The manifest's paths are relative to the repository root, and a job may run
    # from a subdirectory (a suite job starts with `cd <product dir>`), so the
    # staging runs at the root. A file the run wrote that is still unstaged after
    # it means git matched none of the paths: the job says so and fails, never a
    # green job without a merge request.
    - |
      git config user.email "ci@ptc"
      git config user.name "PTC Translate"
      git checkout -B ptc/translations
      ptc_top="$(git rev-parse --show-toplevel)"
      ptc_add_rc=0
      git -C "$ptc_top" add --pathspec-from-file=/tmp/ptc-written --pathspec-file-nul || ptc_add_rc=$?
      # 1 = some path is ignored (the rest is staged); 128 = a path matched nothing and git staged NOTHING.
      if [ "$ptc_add_rc" -gt 1 ]; then
        echo "git add of the translations this run wrote failed (exit $ptc_add_rc), so nothing was staged for the merge request."
        exit 1
      fi
      if [ -s /tmp/ptc-written ]; then
        ptc_unstaged="$(xargs -0 git -C "$ptc_top" status --porcelain --untracked-files=all -- < /tmp/ptc-written | grep '^.[^ ]' || true)"
        if [ -n "$ptc_unstaged" ]; then
          echo "PTC wrote these translations, but they were not staged for the merge request (git add matched none of them):"
          echo "$ptc_unstaged"
          exit 1
        fi
      fi
      if ! git diff --cached --quiet; then
        git commit -m "chore(i18n): update translations via PTC [skip translations]"
        ptc_mr_description="$(/tmp/ptc-cli.sh guide mr-description --file /tmp/ptc-check.json)"
        git push -o merge_request.create \
                 -o merge_request.target="$CI_DEFAULT_BRANCH" \
                 -o merge_request.title="Update translations from PTC" \
                 -o merge_request.description="$ptc_mr_description" \
                 -f "https://gitlab-ci-token:${PTC_GIT_PUSH_TOKEN:-$CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:ptc/translations
        # PTC observes its delivery on the translations branch (P4 T14): the commit and its delivered files'
        # sha256 (S2-R14: a trusted report of PTC's delivery on the translations branch is the delivery proof).
        /tmp/ptc-cli.sh guide delivery-commit --commit "$(git rev-parse HEAD)" --branch ptc/translations --source-commit "$CI_COMMIT_SHA" --config-file .ptc-config.yml $ptc_stopped || true
      elif [ -n "$ptc_stopped" ]; then
        # Nothing finished inside the bound: PTC still hears that this run stopped, so the guide says "re-run the job".
        /tmp/ptc-cli.sh guide delivery-commit $ptc_stopped --source-commit "$CI_COMMIT_SHA" --config-file .ptc-config.yml || true
      fi
    - if [ "$ptc_rc" -eq 5 ]; then echo "PTC rejected some files or could not be reached for them (see 'Rejected by PTC' / 'Could not reach PTC' above); the rest was delivered."; exit 5; fi
    - if [ "$ptc_rc" -eq 6 ]; then echo "Some files wait in PTC - parked for an over-limit approval, or paused out-of-credit (see the lists above); the rest was delivered. Approve in PTC or top up the credit, then re-run."; exit 6; fi
    - if [ "$ptc_rc" -eq 7 ]; then echo "The translation is still running in PTC (see 'Still translating in PTC' above); the finished files were delivered. Retry this job once PTC finishes, or check progress / download manually with the commands printed there."; exit 7; fi
```

Store `PTC_API_TOKEN` as a **masked** CI/CD variable (Settings → CI/CD → Variables). It is read from the environment, never placed on the command line.

On the `before_script` line: `bash` and `curl` are what a bare `alpine:3.22` lacks, `git` is for the push step at the end of the job, and `unzip` unpacks the downloaded translations — alpine already provides it as a busybox applet, so it is named only to survive an image swap. `jq` used to be on that line and is never invoked.

**The push needs a token that may write to the repository.** `CI_JOB_TOKEN` can, but only if a maintainer enables Settings → CI/CD → Job token permissions → *"Allow Git push requests to the repository"* (GitLab 18.4+, off by default). Otherwise set `PTC_GIT_PUSH_TOKEN` to a project access token with the `write_repository` scope, also masked.

Loop-safe twice over: the job only runs on a push to the default branch — the translation push targets `ptc/translations`, so it cannot re-trigger — and the commit carries `[skip ci]`, the only skip token GitLab honours.

Pin `v1.3.1` to a different release if you want, and add a `sha256sum` check to get the same integrity guarantee the GitHub action gets from vendoring:

```
3894f8c6172b8228008a5450860d7bf2affebe2adfc9f0086bec167b25008e93  ptc-cli.sh
```

<details>
<summary>Running it as a component on your own instance</summary>

`templates/translate/template.yml` in this repository is the component source, kept for anyone who wants to mirror it into their **own** GitLab and include it from there — where `$CI_SERVER_FQDN` finally is your server, so the address resolves. Copy the repository to your instance, publish it to your CI/CD Catalog, and include it under your own address. We publish it nowhere, and nothing PTC prints points at it.

</details>

---

## Inputs (GitHub Action)

| Input | Required | Default | Description |
|---|---|---|---|
| `api-token` | ✅ | — | PTC API token (organization or project token). Passed via the `PTC_API_TOKEN` env var, never argv. |
| `config-file` | | `''` | Path to `.ptc-config.yml`. Optional: a `.ptc-config.yml` committed at the repo root is used on its own, and with no config at all the action detects the layout itself. Takes precedence over `source-locale`/`patterns`. |
| `source-locale` | | `''` | Source language code. Only to override detection (with `patterns`). |
| `patterns` | | `''` | Glob(s) with a `{{lang}}` slot. Only to override detection. |
| `file-tag-name` | | auto | PTC file tag (defaults to the git branch). |
| `api-url` | | `https://app.ptc.wpml.org/api/v1/` | Override for a self-hosted instance. Left at the default, an `api_url` in the config file is used instead. |
| `project-dir` | | `.` | Directory treated as project root. |
| `create-pr` | | `false` | Open/update a PR with the translations. |
| `pr-token` | | `''` → falls back to `github.token` | Token that opens the PR (use a PAT/App token to trigger downstream CI). |
| `pr-branch` | | `ptc/translations` | Stable branch — re-runs update the same PR. |
| `monitor-interval` | | `''` → 5 | Seconds between translation-status polls. |
| `monitor-max-minutes` | | `''` → sized from the estimate | Wall-clock bound from the first upload. Left empty (and no `monitor_max_minutes` in the config), the estimate of the configured census at about 250 words a minute plus 15 minutes, never below 45, at most 170 (the GitLab job's sizing), under `timeout-minutes: 180`. Reached with files still translating, the job delivers what finished and fails with exit 7. |
| `monitor-max-attempts` | | `''` → max(100, 20 x files) | Status polls before the run gives up and exits 1 listing the unfinished files. The default scales with the number of files pushed (100 polls minimum, 20 per file); a value given here is used as is. With an agent token PTC accepts 600 uploads a minute per organization (a project token: 10). |

### Outputs

| Output | Description |
|---|---|
| `pr-number` | The PR number (when `create-pr=true` and there were changes). |
| `pr-url` | The PR URL. |

---

## Agent guide report

After the configuration is resolved, the action runs `ptc scan --json` and posts
it to PTC's `/guide/action_runs` together with the commit sha, the branch, the
parsed `.ptc-config.yml` and the content of the source files (up to 200 KB), using
the same token, plus `files_sha` (sha256 of the committed `.ptc-config.yml`
files and CI workflow files), `delivered_files_sha` (sha256 of the committed
delivered translation files, so PTC can tell a delivered file edited in git) and `ci_id_token`: the run's GitHub identity token
(audience `ptc`), which proves to PTC that CI — not an agent — ran the commit.
The token exists only when the workflow grants `permissions: id-token: write`
(as in the Quick start); without it the run is reported as *unverified
provenance* and the guide will ask for the permission. PTC uses the report to
verify the steps of its agent guide and ignores it when the guide is off for
the organization. The report never fails the
run; set `guide-report: 'false'` to turn it off. It needs `python3` on the runner
(present on GitHub-hosted runners; skipped with a notice when missing).

**Guide check.** With `guide-check: 'true'` the action, BEFORE translating, asks PTC which
information is missing for this commit (`ptc guide check`): `pass`, `fail` (new strings
without a description, new templates not checked, setup not finished) or `error` (PTC could
not evaluate: no guide session, no report for the commit, PTC unreachable). The check never
withholds the translation: the translation and its pull request always happen, and PTC
redelivers the affected strings once the information arrives. New strings with no code usage
yet are listed as notes, never failures. With `create-pr: 'true'` the action posts ONE
findings comment on the translation pull request (updated in place on later runs): the
findings, the notes, the next step for an agent (`ptc guide next`) and the project's guide
page, plus a link to the repository's settings for auto-merge. The comment needs
`permissions: pull-requests: write`; it is on by default and switched off on the project's
guide page in PTC. The verdict is the `guide-check` output; `guide-check-fail: 'true'` fails
the job on anything else, in its own last step, after the pull request.
When the translation itself fails (any exit other than 0 or 5), the check still runs,
report-only: the Translate step keeps the translation's exit code, and the last step
("Fail on the agent-guide check") reports both the translation failure and the check
verdict, so a failed translation never hides the gate. The check's own exit code stays
0 (pass), 1 (fail) or 2 (cannot evaluate).
In a suite, the check uses `guide.session_id` of the product's `.ptc-config.yml`.
The check never changes the guide; the report does.

## Running the job locally: `ptc sync`

The same steps this action runs — report the run, PTC's check, translate, report the written files — run on an agent's
machine with `ptc sync` (the vendored `ptc-cli.sh sync`; agent token in `PTC_API_TOKEN`, `PTC_ORG_TOKEN` still accepted). It exits with this
action's codes (0, 5 rejected/unreachable, 6 parked, 7 still translating) and prints the same final lines; its delivery
report names no branch: the working tree's fingerprint and the sha256 of the files it wrote. See the CLI README
(`ptc sync`).

## How it stays loop-safe & hands-off

- **Trigger on source paths only** (`paths:` / default-branch rule) — a translation-only commit can never re-trigger the run. This is what actually breaks the loop.
- **Stable `ptc/translations` branch** — re-runs update ONE PR instead of spawning new ones, and a PR branch is not a trigger branch.
- **Exit 7 is one click** — when the run stops at its bound while PTC is still translating, click "Re-run failed jobs" (GitLab: "Retry this job") once PTC finishes. The re-run keeps the run id, so PTC translates nothing again; it keeps every file the first job delivered (downloaded again into the fresh checkout) and adds the rest, so the PR grows run by run.
- **PR token is explicit** so the translation PR actually runs your repo's own checks.

> The translation commit carries a `[skip translations]` marker. It is a human-readable label, **not** a CI skip token — GitHub honours only `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` and `[actions skip]`. Do not rely on it as a guard; rely on the two above.

## Security

- The PTC token is read from an env var and `::add-mask::`ed — it never appears in `argv` or logs.
- Every third-party dependency is pinned to a full commit SHA, not a movable tag (`peter-evans/create-pull-request` v8.1.1); pin the action itself to a full SHA too if your org requires it.
- `ptc-cli` is vendored in this repo, not downloaded at job time — there is no runtime fetch to intercept.
- The GitLab job pins its base image (`alpine:3.22`) and its `ptc-cli` release tag; add the `sha256sum` check above for full parity.

## License

[MIT](LICENSE)
