# PTC Translate

Translate your source files with **[Private Translation Cloud](https://ptc.wpml.org) (WPML)** straight from CI — and get the results back as a self-updating pull request on every source push. PTC never touches your repo; the action runs the pinned [`ptc-cli`](https://github.com/OnTheGoSystems/ptc-cli) in **your** pipeline and your own token opens the PR.

- **GitHub:** a composite action, used straight from this repository — `uses: OnTheGoSystems/ptc-action@v1`
- **GitLab:** an inline job that `ptc init` prints for you — see [below](#quick-start-gitlab-cicd)

There is no GitHub Marketplace listing. `uses:` resolves against the repository, so the reference above works without one.

This action **vendors** [`ptc-cli` v1.0.4](https://github.com/OnTheGoSystems/ptc-cli/tree/v1.0.4) inside the action repo, so it never runs `main` at job time — the script that ships with a given action tag is the script that runs.

---

## Quick start (GitHub Actions)

**1. Get a token.** Grab your PTC project token. A config is optional: with none, the action detects your layout at run time (see [Inputs](#inputs-github-action)). To see and commit the detected layout up front, run [`ptc init`](https://github.com/OnTheGoSystems/ptc-cli) in a checkout of your repo — it needs no token — and commit the `.ptc-config.yml` it writes.

**2. Add secrets.** Repo → Settings → Secrets and variables → Actions:
- `PTC_API_TOKEN` — your PTC project token (**required**).
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

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
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
  rules:
    - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
  before_script:
    - apk add --no-cache bash curl git unzip
  script:
    - curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.0.4/ptc-cli.sh -o ptc-cli.sh
    - chmod +x ptc-cli.sh
    - ./ptc-cli.sh --config-file .ptc-config.yml
    # `git add -A` comes BEFORE the check, and the check reads the index. On the
    # first run the translations are new files, and a plain `git diff` only
    # looks at tracked ones - it would report "nothing changed", skip the push,
    # and leave a green job that produced no merge request.
    - |
      git config user.email "ci@ptc"
      git config user.name "PTC Translate"
      git checkout -B ptc/translations
      git add -A
      if ! git diff --cached --quiet; then
        git commit -m "chore(i18n): update translations via PTC [skip ci]"
        git push -o merge_request.create \
                 -o merge_request.target="$CI_DEFAULT_BRANCH" \
                 -o merge_request.title="Update translations from PTC" \
                 -f "https://gitlab-ci-token:${PTC_GIT_PUSH_TOKEN:-$CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:ptc/translations
      fi
```

Store `PTC_API_TOKEN` as a **masked** CI/CD variable (Settings → CI/CD → Variables). It is read from the environment, never placed on the command line.

On the `before_script` line: `bash` and `curl` are what a bare `alpine:3.22` lacks, `git` is for the push step at the end of the job, and `unzip` unpacks the downloaded translations — alpine already provides it as a busybox applet, so it is named only to survive an image swap. `jq` used to be on that line and is never invoked.

**The push needs a token that may write to the repository.** `CI_JOB_TOKEN` can, but only if a maintainer enables Settings → CI/CD → Job token permissions → *"Allow Git push requests to the repository"* (GitLab 18.4+, off by default). Otherwise set `PTC_GIT_PUSH_TOKEN` to a project access token with the `write_repository` scope, also masked.

Loop-safe twice over: the job only runs on a push to the default branch — the translation push targets `ptc/translations`, so it cannot re-trigger — and the commit carries `[skip ci]`, the only skip token GitLab honours.

Pin `v1.0.4` to a different release if you want, and add a `sha256sum` check to get the same integrity guarantee the GitHub action gets from vendoring:

```
29f66e8a3b89521e8e1e6a1e91e3a6ea014c6258da8518ac0694cb6cf5694945  ptc-cli.sh
```

<details>
<summary>Running it as a component on your own instance</summary>

`templates/translate/template.yml` in this repository is the component source, kept for anyone who wants to mirror it into their **own** GitLab and include it from there — where `$CI_SERVER_FQDN` finally is your server, so the address resolves. Copy the repository to your instance, publish it to your CI/CD Catalog, and include it under your own address. We publish it nowhere, and nothing PTC prints points at it.

</details>

---

## Inputs (GitHub Action)

| Input | Required | Default | Description |
|---|---|---|---|
| `api-token` | ✅ | — | PTC project token. Passed via the `PTC_API_TOKEN` env var, never argv. |
| `config-file` | | `''` | Path to `.ptc-config.yml`. Optional: a `.ptc-config.yml` committed at the repo root is used on its own, and with no config at all the action detects the layout itself. Takes precedence over `source-locale`/`patterns`. |
| `source-locale` | | `''` | Source language code. Only to override detection (with `patterns`). |
| `patterns` | | `''` | Glob(s) with a `{{lang}}` slot. Only to override detection. |
| `file-tag-name` | | auto | PTC file tag (defaults to the git branch). |
| `api-url` | | `https://app.ptc.wpml.org/api/v1/` | Override for a self-hosted instance. |
| `project-dir` | | `.` | Directory treated as project root. |
| `create-pr` | | `false` | Open/update a PR with the translations. |
| `pr-token` | | `''` → falls back to `github.token` | Token that opens the PR (use a PAT/App token to trigger downstream CI). |
| `pr-branch` | | `ptc/translations` | Stable branch — re-runs update the same PR. |

### Outputs

| Output | Description |
|---|---|
| `pr-number` | The PR number (when `create-pr=true` and there were changes). |
| `pr-url` | The PR URL. |

---

## How it stays loop-safe & hands-off

- **Trigger on source paths only** (`paths:` / default-branch rule) — a translation-only commit can never re-trigger the run. This is what actually breaks the loop.
- **Stable `ptc/translations` branch** — re-runs update ONE PR instead of spawning new ones, and a PR branch is not a trigger branch.
- **PR token is explicit** so the translation PR actually runs your repo's own checks.

> The translation commit carries a `[skip translations]` marker. It is a human-readable label, **not** a CI skip token — GitHub honours only `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` and `[actions skip]`. Do not rely on it as a guard; rely on the two above.

## Security

- The PTC token is read from an env var and `::add-mask::`ed — it never appears in `argv` or logs.
- Every third-party dependency is pinned to a full commit SHA, not a movable tag (`peter-evans/create-pull-request` v8.1.1); pin the action itself to a full SHA too if your org requires it.
- `ptc-cli` is vendored in this repo, not downloaded at job time — there is no runtime fetch to intercept.
- The GitLab job pins its base image (`alpine:3.22`) and its `ptc-cli` release tag; add the `sha256sum` check above for full parity.

## License

[MIT](LICENSE)
