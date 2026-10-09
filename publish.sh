#!/usr/bin/env bash
# Publishes the registry artifacts a push changed. For each changed file it
# walks up to the nearest manifest.yaml and publishes that directory with
# `lace registry register`: a module is validated and registered with its
# tree, any other axis is registered by its manifest alone. Re-publishing
# unchanged content reports `unchanged`, so a re-run is safe.
#
# Inputs, from the action's env (action.yml maps them):
#   LACE_TOKEN      the Lace service token; read by the lace CLI
#   LACE_AUTH_URL   the Lace API to publish to; read by the lace CLI
#   LACE_VERSION    the lace release to publish with; empty = the pin
#   INPUT_PATH      one manifest directory to publish, instead of the changed ones
#   EVENT_NAME, CREATED, BEFORE, GITHUB_SHA   the triggering event
#
# Every manifest is tried: a refusal is recorded, the loop goes on, and the
# step fails at the end naming each refused manifest.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/manifests.sh
source "${HERE}/lib/manifests.sh"
# shellcheck source=SCRIPTDIR/../lib/install-lace.sh
source "${HERE}/lib/install-lace.sh"

ZERO_SHA=0000000000000000000000000000000000000000

fail() {
  echo "::error::registry-publish: $*" >&2
  exit 1
}

if [ -z "${LACE_TOKEN:-}" ]; then
  fail "no token. Pass a Lace service token: with: token: \${{ secrets.LACE_TOKEN }}. Mint one in the Lace portal and store it as the LACE_TOKEN repository secret."
fi

# A pull_request token is refused at publish by design: that workflow can
# run a contributor's code, and its token must not be able to publish.
case "${EVENT_NAME:-}" in
  push | workflow_dispatch) ;;
  *) fail "this action runs on push or workflow_dispatch, not ${EVENT_NAME:-an unknown event}. A pull_request token cannot publish by design; use lace-cloud/registry-check on pull requests." ;;
esac

# The OIDC token a module publish carries names GITHUB_SHA, so the tree
# published has to be that commit's: a checkout with `ref:` would publish
# a tree the token does not describe.
HEAD_SHA="$(git rev-parse HEAD)"
if [ "$HEAD_SHA" != "${GITHUB_SHA:-}" ]; then
  fail "the checked-out commit ${HEAD_SHA} is not the commit that triggered this run (${GITHUB_SHA:-unset}). Remove the ref: input from actions/checkout so the tree published is the tree the run's identity names."
fi

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT INT TERM

if [ -n "${INPUT_PATH:-}" ]; then
  dir="$(manifest_path_guard "$INPUT_PATH")" || exit 1
  printf '%s\0' "$dir" > "$LIST"
else
  if [ "$EVENT_NAME" != push ]; then
    fail "a ${EVENT_NAME} run publishes one directory: set path."
  fi
  # Only a push that has no earlier commit lists every manifest. Any other
  # failure to reach the commit the push started from is an error: reading
  # it as "everything changed" would republish the world, and as "nothing
  # changed" would publish nothing.
  if [ "${CREATED:-}" = true ] || [ "${BEFORE:-}" = "$ZERO_SHA" ]; then
    manifest_paths_all | manifest_dirs_of_paths > "$LIST"
  else
    [ -n "${BEFORE:-}" ] || fail "the push event names no before commit."
    manifest_ensure_commit "$BEFORE" "the commit this push started from" || exit 1
    manifest_paths_changed "$BEFORE" "$GITHUB_SHA" | manifest_dirs_of_paths > "$LIST"
  fi
fi

manifest_summary_start "Lace registry publish"

if [ ! -s "$LIST" ]; then
  echo "registry-publish: the push changed no manifest directory; nothing to publish."
  exit 0
fi

install_lace

REFUSED=""

# refuse <manifest> <axis> <why> — records a refusal and lets the loop go on.
refuse() {
  echo "::error file=${1}::${1} was not published: ${3}" >&2
  manifest_summary_row "$1" "$2" "refused: $3"
  REFUSED="${REFUSED}${1}"$'\n'
}

publish_one() {
  local d="$1" manifest axis readme rc
  manifest="${d}/manifest.yaml"
  axis="$(manifest_top_level axis < "$manifest")"
  readme=""
  if [ -f "${d}/README.md" ]; then
    readme="${d}/README.md"
  fi

  # A module publishes its tree, so it is validated first and sent with
  # --path; every other axis sends the manifest alone, and the CLI refuses
  # an axis Lace does not have. Each invocation stands on its own line so
  # its argv is checked against the command tree.
  if [ "$axis" = module ]; then
    set +e
    lace module validate --path "$d"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      refuse "$manifest" "$axis" "lace module validate exited ${rc}"
      return 0
    fi
    set +e
    lace registry register --axis module --manifest "$manifest" --path "$d" --readme "$readme"
    rc=$?
    set -e
  else
    set +e
    lace registry register --axis "$axis" --manifest "$manifest" --readme "$readme"
    rc=$?
    set -e
  fi
  if [ "$rc" -ne 0 ]; then
    refuse "$manifest" "$axis" "lace registry register exited ${rc}"
    return 0
  fi
  manifest_summary_row "$manifest" "$axis" "registered"
}

manifest_for_each "$LIST" publish_one

if [ -n "$REFUSED" ]; then
  fail "these manifests were refused: $(printf '%s' "$REFUSED" | tr '\n' ' ')"
fi
