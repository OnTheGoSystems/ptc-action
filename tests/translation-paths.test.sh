#!/usr/bin/env bash
# Unit tests for lib/translation-paths.sh — the list of files the translation
# run actually wrote, which becomes `add-paths` for the pull request.
#
# The list used to be guessed from the config's `output:` entries. It is now
# observed from the working tree, because `output:` is not where translations
# land: the CLI sends it to the API as `output_file_path` and unpacks the
# archive next to the SOURCE file (ptc-cli.sh, download_translations). A config
# whose `output:` points elsewhere produced a path list that matched nothing.
#
# What counts as "written by this run" is decided by comparing the content of
# the working tree before and after, not by comparing timestamps against a
# marker: the CLI unpacks translations from a ZIP, ZIP stores mtimes at
# two-second granularity, and unzip restores them from the archive - so a fresh
# translation can carry a timestamp from before the run started.
#
# Plain bash on purpose: no bats, no docker, runs in well under a second, and
# works on the bash 3.2 that ships with macOS as well as the 5.x on the runner.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/translation-paths.sh"

PASS=0
FAIL=0

fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
pass() { printf '  ok  : %s\n' "$1"; PASS=$((PASS + 1)); }

# assert_lines <name> <expected-newline-separated> <actual>
assert_lines() {
  local name="$1" expected="$2" actual="$3"
  # Order is not part of the contract; git decides it. Compare as sets.
  local e a
  e="$(printf '%s' "$expected" | LC_ALL=C sort)"
  a="$(printf '%s' "$actual"   | LC_ALL=C sort)"
  if [ "$e" = "$a" ]; then
    pass "$name"
  else
    fail "$name"
    printf '    expected:\n%s\n    actual:\n%s\n' \
      "$(printf '%s' "$e" | sed 's/^/      /')" \
      "$(printf '%s' "$a" | sed 's/^/      /')"
  fi
}

# Each case gets its own repository, so one case cannot leak into the next.
new_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-paths-XXXXXX")"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email probe@local
  git -C "$dir" config user.name  probe
  mkdir -p "$dir/locales"
  printf '{"hello":"world"}\n' > "$dir/locales/en.json"
  printf 'node_modules/\n' > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" commit -qm baseline
  printf '%s' "$dir"
}

# Stands in for the snapshot the action takes before it runs the CLI. No sleep
# and no clock: the comparison is between two states of the working tree.
snapshot() {
  local dir="$1"
  local snap
  snap="$(mktemp "${TMPDIR:-/tmp}/ptc-snap-XXXXXX")"
  ( cd "$dir" && ptc_snapshot_worktree "$snap" )
  printf '%s' "$snap"
}

# --- 1. a file the run wrote is reported -------------------------------------
t_writes_are_reported() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a translation written after the marker is reported" \
    "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 2. what the caller's job dirtied before us stays out ---------------------
# This is the whole point of the ticket: a job that builds before the action
# runs must not have its build output committed under our name.
t_prior_dirt_is_excluded() {
  local repo marker out
  repo="$(new_repo)"
  mkdir -p "$repo/dist"
  printf 'BUILD\n' > "$repo/dist/bundle.js"
  printf '{"dirty":true}\n' > "$repo/package-lock.json"
  marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a workspace dirtied before the run is excluded" \
    "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 3. a file dirty before us AND rewritten by us is ours -------------------
t_rewritten_prior_dirt_is_included() {
  local repo marker out
  repo="$(new_repo)"
  printf '{"hello":"stale"}\n' > "$repo/locales/de.json"
  marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a pre-dirtied file the run rewrote is reported" \
    "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 4. a brand new directory is reported file by file ----------------------
# git abbreviates an untracked directory to "dir/" unless asked otherwise; a
# directory is not a path create-pull-request can stage predictably.
t_new_directory_is_expanded() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  mkdir -p "$repo/public/i18n"
  printf '{"a":1}\n' > "$repo/public/i18n/de.json"
  printf '{"a":2}\n' > "$repo/public/i18n/fr.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a new directory is reported as individual files" \
    "public/i18n/de.json
public/i18n/fr.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 5. ignored files stay out ----------------------------------------------
# Passing an ignored path to `git add` is fatal, and it takes the whole
# staging call down with it — including the paths that were fine.
t_ignored_files_are_excluded() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  mkdir -p "$repo/node_modules/pkg"
  printf 'x\n' > "$repo/node_modules/pkg/index.js"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "an ignored file is excluded" "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 6. an untouched file is not reported ------------------------------------
t_untouched_files_are_excluded() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "an unchanged tree reports nothing" "" "$out"
  rm -rf "$repo" "$marker"
}

# --- 7. paths are repository-root-relative, whatever the working directory ---
# create-pull-request resolves add-paths from the repository root, while the
# action runs the CLI in project-dir.
t_paths_are_root_relative() {
  local repo marker out
  repo="$(new_repo)"
  mkdir -p "$repo/packages/app/locales"
  printf '{"hello":"world"}\n' > "$repo/packages/app/locales/en.json"
  git -C "$repo" add -A && git -C "$repo" commit -qm sub
  marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/packages/app/locales/de.json"
  out="$(cd "$repo/packages/app" && ptc_translation_paths "$marker")"
  assert_lines "paths are relative to the repository root, not the cwd" \
    "packages/app/locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 8. a path with a space survives -----------------------------------------
t_spaces_survive() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  mkdir -p "$repo/my locales"
  printf '{"a":1}\n' > "$repo/my locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a path containing a space is reported whole" \
    "my locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 9. a deleted file is not reported ---------------------------------------
# It has no working-tree file to compare, and a deletion is not something a
# translation run produces.
t_deletions_are_excluded() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  rm "$repo/locales/en.json"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a deleted file is not reported" "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 10. a file dated in the past is still ours ------------------------------
# The act fixture caught this against a marker-and-mtime implementation: the
# CLI unpacks translations from a ZIP, ZIP keeps mtimes to a two-second
# granularity, and unzip restores them from the archive - so a translation
# written seconds ago can be dated before the run began, and a timestamp
# comparison drops it. Nothing was committed, and the run stayed green.
t_files_dated_in_the_past_are_reported() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  touch -t 200001010000 "$repo/locales/de.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  assert_lines "a translation dated in the past is still reported" \
    "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- 11. a newline in a file name is dropped, not split ----------------------
# The list is newline-separated by the time create-pull-request sees it, so
# such a path would arrive as two paths that match nothing - and one
# non-matching pathspec stages nothing at all.
t_newline_in_name_is_dropped() {
  local repo marker out nl
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  # $'\n', not "$(printf '\n')": command substitution strips trailing newlines,
  # so the latter would name the file "weird.json" and prove nothing.
  nl=$'\n'
  printf '{"a":1}\n' > "$repo/locales/de.json"
  # Some filesystems refuse this outright; skip rather than fail there.
  if printf 'x\n' > "$repo/locales/we${nl}ird.json" 2>/dev/null; then
    out="$(cd "$repo" && ptc_translation_paths "$marker" 2>/dev/null)"
    assert_lines "a file name containing a newline is dropped, not split" \
      "locales/de.json" "$out"
  else
    pass "a file name containing a newline is dropped (skipped: filesystem refused the name)"
  fi
  rm -rf "$repo" "$marker"
}

# create-pull-request splits add-paths on /[\n,]+/, so a comma is as fatal as
# a newline - and one non-matching pathspec stages nothing at all.
t_comma_in_name_is_dropped() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  printf '{"a":1}\n' > "$repo/locales/de.json"
  if printf 'x\n' > "$repo/locales/es,MX.json" 2>/dev/null; then
    out="$(cd "$repo" && ptc_translation_paths "$marker" 2>/dev/null)"
    assert_lines "a file name containing a comma is dropped, not split" \
      "locales/de.json" "$out"
  else
    pass "a file name containing a comma is dropped (skipped: filesystem refused the name)"
  fi
  rm -rf "$repo" "$marker"
}

# --- 12. every reported path can actually be staged --------------------------
# The list goes straight to `git add -- <paths>`, which dies on the first path
# that matches nothing and stages NOTHING at all - not even the paths that
# were fine. A reported path that git refuses is therefore not a cosmetic
# problem: it loses the whole pull request.
t_reported_paths_are_addable() {
  local repo marker out
  repo="$(new_repo)"
  mkdir -p "$repo/dist"; printf 'BUILD\n' > "$repo/dist/bundle.js"
  marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"
  mkdir -p "$repo/public/i18n"; printf '{"a":1}\n' > "$repo/public/i18n/fr.json"
  out="$(cd "$repo" && ptc_translation_paths "$marker")"

  local -a paths=()
  while IFS= read -r line; do
    [ -n "$line" ] && paths+=("$line")
  done <<< "$out"

  if (cd "$repo" && git add -- "${paths[@]}" 2>/dev/null); then
    local staged
    staged="$(cd "$repo" && git diff --cached --name-only)"
    assert_lines "every reported path stages cleanly, and only those stage" \
      "locales/de.json
public/i18n/fr.json" "$staged"
  else
    fail "every reported path stages cleanly (git add rejected the list)"
  fi
  rm -rf "$repo" "$marker"
}


# --- two files with identical content ----------------------------------------
# Locale files routinely share content, and when two hashes are equal the
# comparison falls back to the path - where a locale like en_US collates
# differently from C. With comm left in the ambient locale, GNU comm exits 1
# ("input is not in sorted order") and kills the step after the translation has
# been paid for, while BSD comm says nothing and reports the caller's file.
t_identical_content_is_handled() {
  local repo marker out
  repo="$(new_repo)"
  # Dirty BEFORE the snapshot and left alone: it has to be in both digests, or
  # the two identical hashes never meet and the comparison is never tested.
  printf '{"same":1}\n' > "$repo/locales/de_AT.json"
  marker="$(snapshot "$repo")"
  printf '{"same":1}\n' > "$repo/locales/de.json"
  out="$(cd "$repo" && LC_ALL=en_US.UTF-8 ptc_translation_paths "$marker")"
  assert_lines "two files with identical content do not confuse the comparison" \
    "locales/de.json" "$out"
  rm -rf "$repo" "$marker"
}

# --- a glob metacharacter in a written path ----------------------------------
# `git add -- <path>` takes a pathspec: `--` stops option parsing, not
# globbing. Without :(literal) the caller's messages1.json is staged and the
# translation is not - and git exits 0, so nothing notices.
t_glob_metacharacters_stage_literally() {
  local repo marker out staged
  repo="$(new_repo)"
  printf 'CALLER\n' > "$repo/locales/messages1.json"
  git -C "$repo" add -A && git -C "$repo" commit -qm caller
  # Dirty before the snapshot, the way a caller's earlier build step leaves it:
  # otherwise `git add` picking it up produces no diff against HEAD and the
  # mistake is invisible to this test.
  printf 'CALLER TOUCHED IT\n' > "$repo/locales/messages1.json"
  marker="$(snapshot "$repo")"
  printf 'TRANSLATION\n' > "$repo/locales/messages[1].json"

  out="$(cd "$repo" && ptc_translation_paths "$marker")"
  local -a paths=()
  while IFS= read -r line; do [ -n "$line" ] && paths+=("$line"); done <<< "$out"

  if (cd "$repo" && git add -- "${paths[@]}" 2>/dev/null); then
    staged="$(cd "$repo" && git diff --cached --name-only)"
    assert_lines "a bracketed name stages itself, not what it globs to" \
      "locales/messages[1].json" "$staged"
  else
    fail "a bracketed name stages itself (git add rejected the list)"
  fi
  rm -rf "$repo" "$marker"
}

# --- a name starting with a double quote -------------------------------------
# `git hash-object --stdin-paths` C-unquotes such a line and dies looking for
# the unquoted name, which would take the whole run down - before translating.
t_leading_quote_is_hashed() {
  local repo marker out
  repo="$(new_repo)"; marker="$(snapshot "$repo")"
  if printf 'x\n' > "$repo/locales/\"quoted\".json" 2>/dev/null; then
    out="$(cd "$repo" && ptc_translation_paths "$marker")"
    assert_lines 'a name starting with a double quote is reported, not fatal' \
      'locales/"quoted".json' "$out"
  else
    pass 'a name starting with a double quote is reported (skipped: filesystem refused the name)'
  fi
  rm -rf "$repo" "$marker"
}

# --- a snapshot that cannot be trusted ---------------------------------------
# The dangerous direction is not failing: it is deciding that everything dirty
# is ours, which puts the caller's build back into the pull request.
t_unusable_snapshot_refuses() {
  local repo marker rc out
  repo="$(new_repo)"
  mkdir -p "$repo/dist"; printf 'BUILD\n' > "$repo/dist/bundle.js"
  marker="$(snapshot "$repo")"
  printf '{"hello":"welt"}\n' > "$repo/locales/de.json"

  # Truncated: reads fine, sorts fine, and is missing its completion line.
  head -1 "$marker" > "$marker.cut" && mv "$marker.cut" "$marker"
  out="$(cd "$repo" && ptc_translation_paths "$marker" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "a truncated snapshot is refused rather than treated as empty"
  else
    fail "a truncated snapshot is refused (rc=$rc, reported: $out)"
  fi

  rm -f "$marker"
  out="$(cd "$repo" && ptc_translation_paths "$marker" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "a missing snapshot is refused"
  else
    fail "a missing snapshot is refused (rc=$rc, reported: $out)"
  fi
  rm -rf "$repo"
}

# --- outside a repository ----------------------------------------------------
t_outside_a_repository_refuses() {
  local dir snap rc
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-norepo-XXXXXX")"
  snap="$(mktemp "${TMPDIR:-/tmp}/ptc-snap-XXXXXX")"
  ( cd "$dir" && ptc_snapshot_worktree "$snap" ) 2>/dev/null; rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "snapshotting outside a git repository refuses"
  else
    fail "snapshotting outside a git repository refuses (rc=$rc)"
  fi
  rm -rf "$dir" "$snap"
}

# -----------------------------------------------------------------------------
if [ ! -f "$LIB" ]; then
  printf 'lib/translation-paths.sh does not exist yet\n'
  exit 1
fi
# shellcheck source=../lib/translation-paths.sh
. "$LIB"

printf 'translation-paths\n'
t_writes_are_reported
t_prior_dirt_is_excluded
t_rewritten_prior_dirt_is_included
t_new_directory_is_expanded
t_ignored_files_are_excluded
t_untouched_files_are_excluded
t_paths_are_root_relative
t_spaces_survive
t_deletions_are_excluded
t_files_dated_in_the_past_are_reported
t_newline_in_name_is_dropped
t_comma_in_name_is_dropped
t_identical_content_is_handled
t_glob_metacharacters_stage_literally
t_leading_quote_is_hashed
t_unusable_snapshot_refuses
t_outside_a_repository_refuses
t_reported_paths_are_addable

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
