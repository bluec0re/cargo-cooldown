#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${ROOT_DIR}/.." && pwd)
FIXTURE_DIR="${ROOT_DIR}/fixtures/deterministic"
WORKSPACE_TEMPLATE="${FIXTURE_DIR}/workspace"
FIXED_NOW="2026-04-03T00:00:00Z"
FIXED_COOLDOWN_MINUTES=86400
FIXED_TTL_SECONDS=9999999999
CARGO_SUBCOMMAND=${CARGO_SUBCOMMAND:-check}
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ -n ${CMD:-} ]]; then
  CMD_BIN="${CMD}"
  CMD_ARGS=()
else
  cargo build --quiet --manifest-path "${REPO_DIR}/Cargo.toml" --bin cargo-cooldown
  CMD_BIN="${REPO_DIR}/target/debug/cargo-cooldown"
  CMD_ARGS=()
fi

prepare_workspace() {
  local target_dir=$1
  local lockfile_name=$2

  mkdir -p "${target_dir}"
  cp -a "${WORKSPACE_TEMPLATE}/." "${target_dir}"
  cp "${FIXTURE_DIR}/${lockfile_name}" "${target_dir}/Cargo.lock"
}

assert_lockfile() {
  local expected_lock=$1
  local workspace_dir=$2

  diff -u "${FIXTURE_DIR}/${expected_lock}" "${workspace_dir}/Cargo.lock"
}

run_case() {
  local name=$1
  local start_lock=$2
  local expected_lock=$3
  shift 3

  local workspace_dir="${TMP_ROOT}/${name}"

  echo
  echo "=== ${name} ==="
  prepare_workspace "${workspace_dir}" "${start_lock}"

  (
    cd "${workspace_dir}" >&2
    env \
      CARGO_TERM_PROGRESS_WHEN=never \
      COOLDOWN_NOW="${FIXED_NOW}" \
      COOLDOWN_MINUTES="${FIXED_COOLDOWN_MINUTES}" \
      COOLDOWN_CACHE_DIR="${FIXTURE_DIR}/cache" \
      COOLDOWN_TTL_SECONDS="${FIXED_TTL_SECONDS}" \
      COOLDOWN_HTTP_RETRIES=0 \
      COOLDOWN_REGISTRY_API="http://127.0.0.1:9/" \
      "$@" \
      "${CMD_BIN}" "${CMD_ARGS[@]}" "${CARGO_SUBCOMMAND}"
  )

  assert_lockfile "${expected_lock}" "${workspace_dir}"
  echo "ok: ${name}"
}

usage() {
  cat <<'USAGE'
Usage: ./test.sh [CASE ...]

Run a deterministic regression suite for cargo-cooldown. The suite freezes
time, uses a tiny fixture workspace with committed lockfiles, and reads crate
publication metadata from a local on-disk cache snapshot instead of crates.io.

By default this script builds the local checkout once and then exercises the
resulting binary, so uncommitted changes are covered too. Override CMD to try a
different binary, or CARGO_SUBCOMMAND to swap `check` for `build` or `run`.

The suite intentionally points `COOLDOWN_REGISTRY_API` at `127.0.0.1:9`. No
registry server is started there; the dead endpoint is used to guarantee that
publication metadata comes from `${FIXTURE_DIR}/cache`. If a required cache
entry is missing, the test fails immediately instead of silently falling back to
live crates.io data.

Available CASE values:
  downgrade   Start from a hot lockfile and verify the expected downgrades.
  allowlist   Keep one exact version exempt and verify the selective downgrade.
  idempotent  Start from the cooled lockfile and verify a second run is stable.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ ${CARGO_SUBCOMMAND} == "update" ]]; then
  echo "This suite validates build/check/run style flows. Using 'cargo update' would replace the fixture lockfile directly." >&2
  exit 1
fi

if [[ ! -d "${WORKSPACE_TEMPLATE}" ]]; then
  echo "Expected fixture workspace at ${WORKSPACE_TEMPLATE}" >&2
  exit 1
fi

SELECTED=("downgrade" "allowlist" "idempotent")
if [[ $# -gt 0 ]]; then
  SELECTED=("$@")
fi

for case_name in "${SELECTED[@]}"; do
  case "${case_name}" in
    downgrade)
      run_case "downgrade" \
        "Cargo.lock.hot" \
        "Cargo.lock.expected"
      ;;
    allowlist)
      run_case "allowlist" \
        "Cargo.lock.hot" \
        "Cargo.lock.allowlist" \
        COOLDOWN_ALLOWLIST_PATH="${FIXTURE_DIR}/cooldown-allowlist.toml"
      ;;
    idempotent)
      run_case "idempotent" \
        "Cargo.lock.expected" \
        "Cargo.lock.expected"
      ;;
    *)
      echo "Unknown case: ${case_name}" >&2
      usage
      exit 1
      ;;
  esac
done
