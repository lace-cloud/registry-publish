# shellcheck shell=bash
# Installs a signed lace CLI release for the registry actions: fetches
# install.sh and its minisign signature from releases.lace.cloud, refuses
# to run the installer unless the signature verifies under the embedded
# release-signing key and its trusted comment names exactly these bytes,
# then runs it for one pinned version and puts the install directory on
# this shell's PATH.
#
# Sourced, not executed — no shebang. publish.sh and check.sh source it and
# call install_lace in-process, so the PATH it exports is the PATH the rest
# of the script runs `lace` under; nothing is handed to a later step.
#
# install_lace installs the release this copy of the action was published
# with (PINNED_VERSION) into $RUNNER_TEMP/lace-bin. No caller input names
# another: the scripts that call lace were checked against that release's
# command tree before it was published, and a release nothing checked is
# not one they may run.
# LACE_BASE_URL overrides the release origin, for the fixture tests only.
#
# Fail-closed throughout: every failure exits non-zero with the reason.
#
# The mirror renders two placeholders before this file is published:
# PINNED_VERSION below, and MINISIGN_PUBKEY, which scripts/release-signing.pub
# in the Lace monorepo declares (tools/release/render-install-artifact.sh writes
# both). install.sh embeds the same key for the same reason: this runs on a
# machine with no checkout of the monorepo to read it from. The guards in
# install_lace refuse an unrendered copy rather than treating a placeholder
# as a version or a key.

PINNED_VERSION="v2.55.0"
MINISIGN_PUBKEY="RWQ1lQVwyfRwZoE5kuVWWrqbg7FTBd6GS4O7VOFp2i8CDpSwvFMIRR/H"

install_lace() {
  local base_url version runner_temp install_dir workdir sudo_cmd digest expected actual installed

  base_url="${LACE_BASE_URL:-https://releases.lace.cloud}"
  workdir=""

  die() {
    rm -rf "$workdir"
    echo "::error::install-lace: $*" >&2
    exit 1
  }

  [ "$MINISIGN_PUBKEY" != "@LACE_RELEASE_SIGNING_PUBKEY@" ] \
    || die "this install-lace.sh is an unrendered template (MINISIGN_PUBKEY is still the placeholder) — use a published release of the action"
  [ "$PINNED_VERSION" != "@LACE_CLI_VERSION@" ] \
    || die "this install-lace.sh is an unrendered template (PINNED_VERSION is still the placeholder) — use a published release of the action"

  version="$PINNED_VERSION"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '${version}' is not a plain vX.Y.Z"

  runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  install_dir="${runner_temp}/lace-bin"

  command -v curl >/dev/null 2>&1 \
    || die "curl is required — in a container job, install curl before this step"

  # install.sh verifies every release object with minisign and refuses
  # without it, so a runner that lacks it gets it here. A job running as
  # root, as a container job usually does, has no sudo to call.
  if ! command -v minisign >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 \
      || die "minisign is not installed and apt-get is not available to install it — put minisign (https://github.com/jedisct1/minisign) on PATH before this step"
    sudo_cmd=""
    if [ "$(id -u)" -ne 0 ]; then
      sudo_cmd="sudo"
    fi
    $sudo_cmd apt-get update
    $sudo_cmd apt-get install -y minisign
  fi

  # scripts/ci/sha256.sh holds this same helper for the scripts that run from a
  # checkout of the monorepo. This file ships under its own licence with
  # nothing of the monorepo's beside it, so it carries its own copy; a
  # missing tool is the caller's `|| die`.
  sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" | cut -d' ' -f1
    else
      return 1
    fi
  }

  install_lace_fetch() {
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --max-time 180 \
      -H 'Cache-Control: no-cache' "$1" -o "$2"
  }

  workdir="$(mktemp -d)"

  install_lace_fetch "${base_url}/install.sh" "${workdir}/install.sh" \
    || die "could not download ${base_url}/install.sh"
  install_lace_fetch "${base_url}/install.sh.minisig" "${workdir}/install.sh.minisig" \
    || die "could not download ${base_url}/install.sh.minisig — refusing to run an installer with no signature"

  # The trusted comment is "install.sh <sha256 of the signed bytes>": minisign
  # binds content only, so without comparing it a validly-signed object for
  # something else could be served at this URL. Full equality, never a prefix —
  # the same rule tools/release/install.sh holds every release object to.
  digest="$(sha256_of "${workdir}/install.sh")" \
    || die "could not compute the sha256 of install.sh — neither sha256sum nor shasum is available"
  expected="install.sh ${digest}"
  actual="$(minisign -V -Q -m "${workdir}/install.sh" -x "${workdir}/install.sh.minisig" -P "$MINISIGN_PUBKEY" 2>"${workdir}/minisign.err")" \
    || die "the signature on ${base_url}/install.sh does not verify under the release-signing key — refusing to run it. ($(cat "${workdir}/minisign.err"))"
  [ "$actual" = "$expected" ] \
    || die "the signature on ${base_url}/install.sh is valid but its trusted comment reads '${actual}', not '${expected}' — a genuinely-signed object for something else is being served at this URL. Refusing to run it."

  # The install directory is on PATH before install.sh runs: install.sh
  # warns about a directory that is not. Assigning PATH clears bash's
  # command hash, so the first `lace` below is found afresh. The check runs
  # the lace on PATH — the one every later step runs — and first requires
  # it to be the one just installed.
  export PATH="${install_dir}:${PATH}"
  LACE_BASE_URL="$base_url" sh "${workdir}/install.sh" --version "$version" --install-dir "$install_dir"
  [ "$(command -v lace)" = "${install_dir}/lace" ] \
    || die "lace on PATH is $(command -v lace), not ${install_dir}/lace"
  installed="$(lace version)"
  [ "$installed" = "lace ${version}" ] \
    || die "lace on PATH reports '${installed}', expected 'lace ${version}'"

  rm -rf "$workdir"
  # Every `lace module validate` in the job shares one provider cache, so a
  # push of many modules downloads each provider once.
  mkdir -p "${runner_temp}/lace-tf-plugins"
  export TF_PLUGIN_CACHE_DIR="${runner_temp}/lace-tf-plugins"
  echo "install-lace: lace ${version} installed in ${install_dir}"
}
