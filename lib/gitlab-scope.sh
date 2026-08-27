#!/bin/sh
# The merge-request half of the GitLab component: commit what the translation
# run wrote, and nothing else.
#
# POSIX sh on purpose. The component runs on alpine, which is busybox ash until
# `before_script` installs bash - no arrays, no process substitution, no
# `local`, no `[[`. Tested under both sh and bash.
#
# The component ships YAML only: `include: component:` cannot vendor a sibling
# file the way the GitHub composite action does. So this file is the source of
# truth and templates/translate/template.yml INLINES it; a test fails if the
# two drift apart.
#
# Two defects this replaces:
#
#   * `! git diff --quiet` as the guard, evaluated BEFORE staging. `git diff`
#     looks only at tracked files, so on a first run - when every translation
#     is a new file - it reported "nothing changed", the push was skipped, and
#     the job went green having produced nothing. The second run worked, which
#     is why it survived so long.
#   * `git add -A`, which committed the whole working directory. Anything the
#     caller's job dirtied before us - an install rewriting a lockfile, a
#     build, a codegen - shipped inside a merge request titled "Update
#     translations from PTC".

# ptc_snapshot
#   Prints "<blob-hash> <path>" for every file git can see as changed or
#   untracked. Call it BEFORE the CLI runs and keep the output; what differs
#   afterwards is what the run wrote.
#
#   Hashes, not timestamps: the CLI unpacks translations from a ZIP, ZIP stores
#   mtimes at two-second granularity, and unzip restores them from the archive,
#   so a translation written moments ago can carry a timestamp from before the
#   run began.
ptc_snapshot() {
  # -uall so an untracked directory is listed file by file rather than
  # abbreviated to "dir/", which is neither hashable nor stageable as one path.
  # -z then `tr` because git quotes unusual paths otherwise; a path containing
  # a newline survives neither, and is dropped by the -f test below.
  git status --porcelain=v1 -uall -z 2>/dev/null | tr '\0' '\n' | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    path=$(printf '%s' "$entry" | cut -c4-)
    # Skips deletions, submodule entries, and the stray fragments a path
    # containing a newline would leave behind.
    [ -f "$path" ] || continue
    printf '%s %s\n' "$(git hash-object -- "$path" 2>/dev/null)" "$path"
  done | LC_ALL=C sort
}

# ptc_commit_scoped <snapshot-file> <commit-message>
#   Stages every file whose content differs from the snapshot, commits, and
#   returns 0. Returns 1 when the run wrote nothing, so the caller can skip the
#   push instead of pushing an empty branch.
ptc_commit_scoped() {
  snapshot="$1"
  message="$2"

  if [ ! -f "$snapshot" ]; then
    echo "ptc: no snapshot at '$snapshot'; refusing to guess what this run wrote" >&2
    return 1
  fi

  after=$(mktemp)
  changed=$(mktemp)
  ptc_snapshot > "$after"
  # LC_ALL=C on comm as well as on the sorts: comm compares with strcoll, and
  # two files with identical content - normal for locale files - tie-break on
  # the path, where a locale like en_US disagrees with C about the order.
  LC_ALL=C comm -13 "$snapshot" "$after" | cut -d' ' -f2- > "$changed"
  rm -f "$after"

  if [ ! -s "$changed" ]; then
    rm -f "$changed"
    echo "ptc: this run wrote nothing git can commit; not opening a merge request."
    return 1
  fi

  echo "ptc: committing what this run wrote:"
  sed 's/^/  /' "$changed"

  # One at a time, and literally: `git add -- <path>` takes a PATHSPEC, so a
  # translation written to messages[1].json would otherwise stage the caller's
  # messages1.json instead - and exit 0 while doing it.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    GIT_LITERAL_PATHSPECS=1 git add -- "$path"
  done < "$changed"
  rm -f "$changed"

  # The index, not the working tree: `git diff --quiet` here would repeat the
  # first-run bug this function exists to remove.
  if git diff --cached --quiet; then
    echo "ptc: nothing staged after all; not opening a merge request."
    return 1
  fi

  git commit -m "$message"
}
