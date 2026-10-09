# shellcheck shell=bash
# The manifest-directory primitives both registry actions share: which
# manifest directories a set of changed paths belongs to, how a top-level
# scalar of a manifest is read, how a compared commit is made present in a
# shallow checkout, how the directory list is looped over, and the step
# summary table. Sourced, not executed — no shebang; inherits the caller's
# `set -euo pipefail`.
#
# Invariants every caller relies on:
#   - Paths are NUL-delimited end to end, and git runs with
#     core.quotePath=false, so a directory name with spaces or non-ASCII
#     characters is one path, not several.
#   - A changed file belongs to the nearest manifest.yaml at or above its
#     directory; a file under no manifest belongs to nothing, and a deleted
#     directory belongs to nothing.
#   - The directory list is read from fd 3, so `lace` never consumes the
#     remaining directories from the loop's stdin.
#
# The monorepo keeps this file once, in apps/actions/lib/; the mirror copies
# it into each published action beside its script (scripts/render-actions.sh).

# manifest_top_level <key> — the top-level scalar <key> of the YAML on
# stdin, without quotes or a trailing comment.
manifest_top_level() {
  local line
  line="$(grep -m 1 "^$1:" || true)"
  line="${line%%#*}"
  line="${line#"$1":}"
  printf '%s' "$line" | tr -d "[:space:]\"'"
}

# manifest_paths_all — every tracked path, NUL-delimited.
manifest_paths_all() {
  git ls-files -z
}

# manifest_paths_changed <from> <to> — the paths that differ between two
# commits, NUL-delimited.
manifest_paths_changed() {
  git -c core.quotePath=false diff -z --name-only "$1" "$2"
}

# manifest_dirs_of_paths — NUL-delimited paths on stdin, the sorted unique
# manifest directories they belong to on stdout, NUL-delimited.
manifest_dirs_of_paths() {
  local f d
  while IFS= read -r -d '' f; do
    d="$(dirname -- "$f")"
    while [ "$d" != "." ] && [ ! -f "$d/manifest.yaml" ]; do
      d="$(dirname -- "$d")"
    done
    if [ -f "$d/manifest.yaml" ]; then
      printf '%s\0' "$d"
    fi
  done | sort -z -u
}

# manifest_path_guard <path> — prints the manifest directory <path> names,
# without a trailing slash. Refuses an absolute path, a `..` component, and
# a directory with no manifest.yaml.
manifest_path_guard() {
  local p="$1"
  case "/${p}/" in
    //* | */../*)
      echo "::error::path '${p}' must be a path inside the repository." >&2
      return 1
      ;;
  esac
  p="${p%/}"
  if [ ! -f "${p}/manifest.yaml" ]; then
    echo "::error::path '${p}' has no manifest.yaml." >&2
    return 1
  fi
  printf '%s\n' "$p"
}

# manifest_ensure_commit <sha> <what> — the commit is in the clone, fetched
# from origin when the checkout is shallow. A commit that cannot be had is a
# hard error with its cause: a comparison against a missing commit must
# never read as "everything changed" or "nothing changed".
manifest_ensure_commit() {
  local sha="$1" what="$2" err
  if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  if ! err="$(git fetch --no-tags --depth=1 origin "$sha" 2>&1)"; then
    echo "::error::cannot fetch ${what} (${sha}) from origin: ${err//$'\n'/ } — the default checkout is shallow and the action fetches this commit itself; a checkout with persist-credentials: false has no credential to do that with, so leave persist-credentials at its default." >&2
    return 1
  fi
  if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    echo "::error::fetched ${what} (${sha}) from origin but the commit is still absent." >&2
    return 1
  fi
}

# manifest_for_each <list-file> <function> — calls <function> with each
# NUL-delimited directory of <list-file>, in this shell. The list is on fd
# 3, so a command inside <function> cannot consume it from stdin.
manifest_for_each() {
  local list="$1" fn="$2" d
  while IFS= read -r -d '' d <&3; do
    "$fn" "$d"
  done 3< "$list"
}

# manifest_summary_start <title> / manifest_summary_row <manifest> <axis>
# <result> — a markdown table on the job summary, when the runner offers one.
manifest_summary_start() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### %s\n\n' "$1"
    printf '| Manifest | Axis | Result |\n|---|---|---|\n'
  } >> "$GITHUB_STEP_SUMMARY"
}

manifest_summary_row() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  local manifest="${1//|/\\|}" axis="${2//|/\\|}" result="${3//|/\\|}"
  printf '| %s | %s | %s |\n' "\`${manifest}\`" "$axis" "$result" >> "$GITHUB_STEP_SUMMARY"
}
