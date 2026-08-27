#!/usr/bin/env bash
# The files a translation run wrote, as repository-root-relative paths.
#
# This list becomes `add-paths` for the pull request, so that the PR carries
# translation output and nothing else. The action does not run in a clean room:
# whatever the caller's job did before it - an install that rewrites a
# lockfile, a build, a codegen - is sitting in the same working directory, and
# committing all of it under a "translations" title is how this started.
#
# The list is OBSERVED, not derived from the config. `output:` looks like the
# right source and is not: the CLI sends it to the API as `output_file_path`
# and unpacks the returned archive next to the SOURCE file, by basename
# (ptc-cli.sh, download_translations). A config whose `output:` points anywhere
# else - `file: locales/en.json` with `output: public/i18n/{{lang}}.json` -
# yields a path list that matches nothing, and then:
#
#   * every path missing  -> nothing is dirty, no pull request, translations
#     die with the runner; or
#   * one path missing among several -> `git add` dies on the first
#     non-matching pathspec and stages NOTHING, including the paths that were
#     fine. create-pull-request ignores that exit code, commits an empty index,
#     and fails with the literal message "Unexpected error: " - stderr is
#     empty, because git wrote the reason to stdout a hundred log lines up.
#
# Observation also covers what no config-derived list could: the `path:`
# entries of `additional_translation_files:` (compiled .mo companions), a
# monorepo where the CLI finds sources at any depth, and a first-ever locale.
#
# TWO SNAPSHOTS, NOT A TIMESTAMP. The obvious implementation - drop a marker
# file, keep everything newer - is wrong here, and the act fixture caught it:
# the CLI unpacks translations from a ZIP, ZIP stores mtimes at two-second
# granularity, and unzip restores them from the archive. A freshly written
# translation can therefore carry a timestamp a second or two BEFORE the run
# began, and a marker comparison silently drops it. Comparing the content of
# the working tree before and against after depends on neither the clock nor on
# what an archiver decided a file's date should be.
#
# Deliberately not reported:
#   * ignored files - `git add` treats an ignored pathspec as fatal, and one
#     fatal takes the whole staging call with it;
#   * deletions - there is no file to hash, and a translation run does not
#     produce them;
#   * anything whose content is byte-for-byte what it was before the run -
#     that is the caller's dirt, not ours;
#   * symlinks to directories and dangling symlinks, which `[ -f ]` rejects; a
#     symlink to a file is hashed as its target's content rather than as the
#     link blob git would store, so retargeting a link between two identical
#     files is invisible here.

# Marks a snapshot as written in full. 'z' keeps it last under LC_ALL=C sort,
# after every hexadecimal hash line.
PTC_SNAPSHOT_COMPLETE='zzzz-ptc-snapshot-complete'

# ptc__dirty_digest
#   Internal. Prints "<blob-hash> <path>" for every file git can see as changed
#   or untracked, from the repository root. Hashes, not timestamps: content is
#   the only thing that says whether this run touched a file.
ptc__dirty_digest() {
  local root
  if ! root="$(git rev-parse --show-toplevel)"; then
    # git has already said why on stderr - not inside a repository, or a
    # dubious-ownership refusal, which is what a container job hits when the
    # workspace belongs to another uid. Name the consequence too, because this
    # runs before the CLI and would otherwise look like a translation failure.
    echo "ptc_translation_paths: cannot inspect the working tree, so the pull request cannot be scoped to what this run wrote" >&2
    return 2
  fi

  ( cd "$root" || exit 2

    # -uall, not the default -unormal: an untracked directory is otherwise
    # abbreviated to "dir/", and a directory is neither hashable nor a path
    # that stages predictably. A locale written into a directory that did not
    # exist before - the common first run - arrives exactly that way.
    local -a paths=()
    while IFS= read -r -d '' entry; do
      # "XY PATH", NUL-terminated. A rename or copy is followed by a second
      # NUL-terminated field holding the original path; consume it so it is not
      # read as the next entry.
      case "${entry:0:2}" in
        R?|C?) IFS= read -r -d '' _origin || true ;;
      esac

      local path="${entry:3}"

      # A regular file that is still here. Excludes deletions, and excludes the
      # directory entries git reports for submodules.
      [ -f "$path" ] || continue

      # An unreadable file is somebody else's problem - typically root-owned
      # output from an earlier `docker run` step. Hashing it would fail and
      # take the whole run with it, over a file that has nothing to do with
      # translation.
      if [ ! -r "$path" ]; then
        echo "ptc_translation_paths: skipping '$path' - not readable" >&2
        continue
      fi

      # create-pull-request splits add-paths on /[\n,]+/ and trims each piece
      # (src/utils.ts, getStringAsArray). A file name carrying a newline or a
      # comma therefore arrives as two pathspecs that match nothing, and one
      # non-matching pathspec makes `git add` stage NOTHING at all - the whole
      # pull request is lost, not just that file. Leading or trailing
      # whitespace is trimmed off for the same reason. Drop such a path loudly:
      # one file missing from the pull request beats no pull request.
      #
      # $'\n', not "$(printf '\n')": command substitution strips trailing
      # newlines, so the latter is the empty string and the pattern matches
      # every path.
      case "$path" in
        *$'\n'*|*,*|' '*|*' '|*$'\t'*)
          echo "ptc_translation_paths: skipping '$path' - a newline, comma or edge whitespace in a file name cannot survive the add-paths list" >&2
          continue ;;
      esac

      paths+=("$path")
    done < <(git status --porcelain=v1 -z -uall 2>/dev/null)

    [ "${#paths[@]}" -eq 0 ] && exit 0

    # `--stdin-paths` C-unquotes any line that begins with a double quote, so a
    # file literally named "quoted".json would be looked up as quoted.json and
    # git would die - taking the whole run down before the translation, over a
    # file that has nothing to do with it. Those few go one at a time.
    local -a batch=() batch_index=()
    local -a hashes=()
    local i
    for ((i = 0; i < ${#paths[@]}; i++)); do
      hashes[i]=""
      case "${paths[$i]}" in
        '"'*) hashes[i]="$(git hash-object -- "${paths[$i]}" 2>/dev/null)" ;;
        *)    batch+=("${paths[$i]}"); batch_index+=("$i") ;;
      esac
    done

    # One batched call for the rest: a monorepo can have hundreds of locales
    # dirty at once. --stdin-paths keeps input order, so the hashes line up
    # with the paths that produced them.
    if [ "${#batch[@]}" -gt 0 ]; then
      local -a batch_hashes=()
      while IFS= read -r hash; do
        batch_hashes+=("$hash")
      done < <(printf '%s\n' "${batch[@]}" | git hash-object --stdin-paths 2>/dev/null)

      if [ "${#batch_hashes[@]}" -ne "${#batch[@]}" ]; then
        echo "ptc_translation_paths: git could not hash every changed file, so the list would be incomplete; refusing to guess" >&2
        exit 2
      fi
      for ((i = 0; i < ${#batch[@]}; i++)); do
        hashes[batch_index[i]]="${batch_hashes[$i]}"
      done
    fi

    for ((i = 0; i < ${#paths[@]}; i++)); do
      if [ -z "${hashes[$i]}" ]; then
        echo "ptc_translation_paths: could not hash '${paths[$i]}'; refusing to report an incomplete list" >&2
        exit 2
      fi
    done

    local i out
    for ((i = 0; i < ${#paths[@]}; i++)); do
      out="${paths[$i]}"
      # `git add -- <path>` takes a PATHSPEC, not a literal name: `--` stops
      # option parsing, it does not stop globbing. A translation written to
      # `messages[1].json` - ordinary in Next.js/Nuxt/SvelteKit layouts, where
      # `[locale]` is a real directory name - would stage `messages1.json`
      # instead, so the caller's file goes into the pull request and the
      # translation does not. A leading colon would be read as magic for the
      # same reason. Both are spelled out with :(literal), and only when
      # needed, so an ordinary path still reads as itself in the log.
      case "$out" in
        *'*'*|*'?'*|*'['*|:*) out=":(literal)$out" ;;
      esac
      printf '%s %s\n' "${hashes[$i]}" "$out"
    done )
}

# ptc_snapshot_worktree <file>
#   Records the state of the working tree before the run. Call this before the
#   CLI - including before `ptc init`, so that a config it writes counts as
#   something this run produced and reaches the pull request, as it did when
#   the whole workspace was committed.
ptc_snapshot_worktree() {
  local out="${1:-}"
  if [ -z "$out" ]; then
    echo "ptc_snapshot_worktree: no output file given" >&2
    return 2
  fi
  ptc__dirty_digest > "$out" || return 2
  # Written last, so its presence means the whole snapshot got there. Sorts
  # after any hash line, so it cannot break the comparison.
  echo "$PTC_SNAPSHOT_COMPLETE" >> "$out"
}

# ptc_translation_paths <snapshot-file>
#   Prints one path per line, relative to the repository root - the paths whose
#   content differs from the snapshot, plus everything that appeared since.
#   Prints nothing and returns 0 when the run wrote nothing; the caller decides
#   what that means. Returns non-zero only when it cannot answer at all.
ptc_translation_paths() {
  local snapshot="${1:-}"

  # Without the "before" half every dirty file in the workspace would look like
  # ours, and the pull request would carry the caller's build again - the exact
  # bug this exists to prevent. Refuse rather than guess.
  if [ -z "$snapshot" ] || [ ! -e "$snapshot" ]; then
    echo "ptc_translation_paths: snapshot '$snapshot' is missing; call ptc_snapshot_worktree before the run" >&2
    return 2
  fi

  # A snapshot that exists is not yet a snapshot that can be trusted. Read it
  # here, where a failure is visible: inside the process substitution below a
  # failing `sort` is invisible to both `set -e` and `pipefail`, and an empty
  # "before" side makes every dirty file in the workspace look like ours - the
  # caller's build back in the pull request, silently, with exit 0.
  local before
  if ! before="$(LC_ALL=C sort "$snapshot")"; then
    echo "ptc_translation_paths: cannot read the snapshot at '$snapshot'" >&2
    return 2
  fi

  # The completion line is the other half: a truncated snapshot reads fine and
  # sorts fine, and would just look like a shorter "before".
  case "$before" in
    *"$PTC_SNAPSHOT_COMPLETE"*) ;;
    *)
      echo "ptc_translation_paths: the snapshot at '$snapshot' is incomplete; it was not written in full" >&2
      return 2 ;;
  esac

  local after
  after="$(ptc__dirty_digest)" || return 2
  [ -z "$after" ] && return 0

  # A line present after but not before means either a new file or a changed
  # one; either way this run produced it.
  #
  # LC_ALL=C on comm as well as on the sorts, not only on the sorts: comm
  # compares with strcoll, so under a locale like en_US it disagrees with
  # C-sorted input about which line comes first - and it only takes two files
  # with identical content, which for locale files is the normal case, for the
  # tie-break to land on the path where the collations diverge. GNU comm then
  # exits 1 ("input is not in sorted order"), killing the step under
  # `set -euo pipefail` after the translation has been paid for; BSD comm says
  # nothing and reports the caller's file as translation output.
  LC_ALL=C comm -13 \
    <(printf '%s\n' "$before") \
    <(printf '%s\n' "$after" | LC_ALL=C sort) |
    grep -v "^$PTC_SNAPSHOT_COMPLETE\$" |
    cut -d' ' -f2-
}
