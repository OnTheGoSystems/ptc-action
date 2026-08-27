#!/usr/bin/env bash
# Tests for lib/gitlab-scope.sh — the merge-request half of the GitLab
# component, which had two defects:
#
#   1. The first run opened no merge request. The guard was
#      `! git diff --quiet` BEFORE staging, and `git diff` looks only at
#      tracked files - on a first run the translations are new files, so it
#      reported "nothing changed", the push was skipped, and the job went green
#      having produced nothing.
#
#   2. `git add -A` committed the whole working directory, so anything the
#      caller's job dirtied before us - an install, a build, a codegen - shipped
#      inside a merge request titled "Update translations from PTC".
#
# The component ships YAML only: it cannot vendor a sibling file the way the
# composite action does, so the shell here is INLINED into
# templates/translate/template.yml. This file is the source of truth, and one
# of the tests below fails if the two drift apart.
#
# The component runs on alpine:3.22, i.e. busybox ash before `before_script`
# installs bash, so everything here must be POSIX: no arrays, no process
# substitution, no `local`. Run this file under sh as well as bash - CI does.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/gitlab-scope.sh"
TEMPLATE="$HERE/../templates/translate/template.yml"

PASS=0
FAIL=0
pass() { printf '  ok  : %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1"
    printf '    expected: [%s]\n    actual  : [%s]\n' "$2" "$3"
  fi
}

new_repo() {
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-gl-XXXXXX")"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email probe@local
  git -C "$dir" config user.name probe
  mkdir -p "$dir/locales"
  printf '{"hello":"world"}\n' > "$dir/locales/en.json"
  printf 'node_modules/\n' > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" commit -qm baseline
  printf '%s' "$dir"
}

# What the job would have pushed, without pushing anything.
staged_in_head() {
  git -C "$1" show --stat --format="" HEAD 2>/dev/null | \
    sed -n 's/^ \([^|]*\)|.*/\1/p' | sed 's/ *$//' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# --- 1. the first run commits, even though every translation is a new file ---
t_first_run_commits() {
  repo="$(new_repo)"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  printf '{"hello":"salut"}\n' > "$repo/locales/fr.json"

  if ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null ); then
    assert_eq "the first run commits, though every translation is a new file" \
      "locales/de.json locales/fr.json" "$(staged_in_head "$repo")"
  else
    fail "the first run commits (ptc_commit_scoped reported nothing to do)"
  fi
  rm -rf "$repo" "$snap"
}

# --- 2. a workspace dirtied before the run stays out ------------------------
t_prior_dirt_excluded() {
  repo="$(new_repo)"
  mkdir -p "$repo/dist"
  printf 'BUILD\n' > "$repo/dist/bundle.js"
  printf '{"touched":true}\n' > "$repo/package-lock.json"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"

  ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null )
  assert_eq "a workspace dirtied before the run is not committed" \
    "locales/de.json" "$(staged_in_head "$repo")"
  rm -rf "$repo" "$snap"
}

# --- 3. a run that wrote nothing commits nothing -----------------------------
t_nothing_written() {
  repo="$(new_repo)"
  mkdir -p "$repo/dist"; printf 'BUILD\n' > "$repo/dist/bundle.js"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )

  if ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null ); then
    fail "a run that wrote nothing must not commit (it reported success)"
  else
    assert_eq "a run that wrote nothing commits nothing" \
      "baseline" "$(git -C "$repo" log -1 --format=%s)"
  fi
  rm -rf "$repo" "$snap"
}

# --- 4. a file the run rewrote is committed; one it left alone is not --------
t_rewrite_vs_untouched() {
  repo="$(new_repo)"
  printf '{"hello":"stale"}\n' > "$repo/locales/de.json"
  printf 'BUILD\n' > "$repo/untouched.txt"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"

  ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null )
  assert_eq "a file the run rewrote is committed, one it left alone is not" \
    "locales/de.json" "$(staged_in_head "$repo")"
  rm -rf "$repo" "$snap"
}

# --- 5. ignored files stay out ----------------------------------------------
t_ignored_excluded() {
  repo="$(new_repo)"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )
  mkdir -p "$repo/node_modules/pkg"; printf 'x\n' > "$repo/node_modules/pkg/i.js"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"

  ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null )
  assert_eq "an ignored file is not committed" \
    "locales/de.json" "$(staged_in_head "$repo")"
  rm -rf "$repo" "$snap"
}

# --- 6. a path with a space survives ----------------------------------------
t_space_in_path() {
  repo="$(new_repo)"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )
  mkdir -p "$repo/my locales"
  printf '{"a":1}\n' > "$repo/my locales/de.json"

  ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null )
  assert_eq "a path containing a space is committed whole" \
    "my locales/de.json" "$(staged_in_head "$repo")"
  rm -rf "$repo" "$snap"
}

# --- 7. a glob metacharacter is staged literally -----------------------------
# `git add -- <path>` takes a pathspec; without literal pathspecs a translation
# written to messages[1].json stages the caller's messages1.json instead.
t_glob_metacharacter() {
  repo="$(new_repo)"
  printf 'CALLER\n' > "$repo/locales/messages1.json"
  git -C "$repo" add -A && git -C "$repo" commit -qm caller
  printf 'CALLER TOUCHED IT\n' > "$repo/locales/messages1.json"
  snap="$repo/../snap.$$"
  ( cd "$repo" && ptc_snapshot > "$snap" )
  printf 'TRANSLATION\n' > "$repo/locales/messages[1].json"

  ( cd "$repo" && ptc_commit_scoped "$snap" "translations" >/dev/null )
  assert_eq "a bracketed name is staged literally, not as a glob" \
    "locales/messages[1].json" "$(staged_in_head "$repo")"
  rm -rf "$repo" "$snap"
}

# --- 8. the component template still carries this exact shell ----------------
# The component cannot source this file at run time, so the template inlines
# it. If the two drift, the tests above stop describing what actually runs.
t_template_matches_lib() {
  if [ ! -f "$TEMPLATE" ]; then
    fail "the component template is missing"
    return
  fi
  missing=""
  # Every non-comment, non-blank line of the library must appear in the
  # template, indented but otherwise unchanged.
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    [ -z "$trimmed" ] && continue
    if ! grep -qF "$trimmed" "$TEMPLATE"; then
      missing="$missing
  $trimmed"
    fi
  done < "$LIB"

  if [ -z "$missing" ]; then
    pass "the component template carries the same shell as the library"
  else
    fail "the component template has drifted from lib/gitlab-scope.sh; missing:$missing"
  fi
}

# -----------------------------------------------------------------------------
if [ ! -f "$LIB" ]; then
  printf 'lib/gitlab-scope.sh does not exist yet\n'
  exit 1
fi
# shellcheck source=../lib/gitlab-scope.sh
. "$LIB"

printf 'gitlab-scope (%s)\n' "${TEST_SHELL_LABEL:-$(command -v sh >/dev/null && echo shell)}"
t_first_run_commits
t_prior_dirt_excluded
t_nothing_written
t_rewrite_vs_untouched
t_ignored_excluded
t_space_in_path
t_glob_metacharacter
t_template_matches_lib

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
