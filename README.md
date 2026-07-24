# PTC Translate

Translate your source files with **[Private Translation Cloud](https://ptc.wpml.org) (WPML)** straight from CI — and get the results back as a self-updating pull request on every source push. PTC never touches your repo; the action runs the pinned [`ptc-cli`](https://github.com/OnTheGoSystems/ptc-cli) in **your** pipeline and your own token opens the PR.

- **GitHub:** a composite Marketplace action — `uses: OnTheGoSystems/ptc-action@v1`
- **GitLab:** a CI/CD Catalog component — `include: component: .../ptc-action/translate@1`

Both pin [`ptc-cli` v1.0.2](https://github.com/OnTheGoSystems/ptc-cli/releases/tag/v1.0.2) — neither ever runs `main` at job time. The GitHub action **vendors** the script inside the action repo. A GitLab component can only ship YAML, so the component **fetches it at an immutable commit and verifies its sha256** before running it.

---

## Quick start (GitHub Actions)

**1. Get a token & config.** In a checkout of your repo, run [`ptc init`](https://github.com/OnTheGoSystems/ptc-cli) — it authenticates, detects your files, and writes `.ptc-config.yml`. Commit that file.

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
          config-file: .ptc-config.yml
          create-pr: true
          pr-token: ${{ secrets.PTC_PR_TOKEN }}
```

> ⚠️ **One-time setting for `create-pr`:** enable **Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests"**. This is the #1 silent first-run failure.

> **Self-hosted runners:** `create-pr` runs `peter-evans/create-pull-request` v8, which needs Node 24 — Actions Runner **v2.327.1 or later**. GitHub-hosted runners already satisfy this.

## Quick start (GitLab CI/CD)

Store `PTC_API_TOKEN` as a **masked** CI/CD variable, then:

```yaml
include:
  - component: $CI_SERVER_FQDN/OnTheGoSystems/ptc-action/translate@1
    inputs:
      config-file: .ptc-config.yml
      open-mr: 'true'
```

The component only runs on a push to your default branch and skips translation commits — no loops.

---

## Inputs (GitHub Action)

| Input | Required | Default | Description |
|---|---|---|---|
| `api-token` | ✅ | — | PTC project token. Passed via the `PTC_API_TOKEN` env var, never argv. |
| `config-file` | | `''` | Path to `.ptc-config.yml`. Takes precedence over `source-locale`/`patterns`. |
| `source-locale` | | `''` | Source language code (with `patterns`). |
| `patterns` | | `''` | Glob(s) with a `{{lang}}` slot. |
| `file-tag-name` | | auto | PTC file tag (defaults to the git branch). |
| `api-url` | | `https://app.ptc.wpml.org/api/v1/` | Override for staging / self-hosted. |
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

- **Trigger on source paths only** (`paths:` / default-branch rule) — a translation-only commit can never re-trigger the run.
- **Stable `ptc/translations` branch** — re-runs update ONE PR instead of spawning new ones.
- **`[skip translations]`** marker on translation commits as a second guard.
- **PR token is explicit** so the translation PR actually runs your repo's own checks.

## Security

- The PTC token is read from an env var and `::add-mask::`ed — it never appears in `argv` or logs.
- Every third-party dependency is pinned to a full commit SHA, not a movable tag (`peter-evans/create-pull-request` v8.1.1); pin the action itself to a full SHA too if your org requires it.
- The GitLab component pins its base image (`alpine:3.22`) and checksum-verifies `ptc-cli.sh` against `cli-sha256` before executing it.

## License

[MIT](LICENSE)
