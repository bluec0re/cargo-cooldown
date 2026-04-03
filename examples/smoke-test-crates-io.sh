#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${ROOT_DIR}/.." && pwd)
WORKSPACE_DIR="${ROOT_DIR}/demo"
CONFIG_FILE="${WORKSPACE_DIR}/cooldown.toml"
CARGO_SUBCOMMAND=${CARGO_SUBCOMMAND:-build}
CACHE_BASE="${ROOT_DIR}/.cooldown-cache"
mkdir -p "${CACHE_BASE}"

if [[ -n ${CMD:-} ]]; then
  CMD_BIN="${CMD}"
  CMD_ARGS=()
else
  CMD_BIN="cargo"
  CMD_ARGS=(run --quiet --manifest-path "${REPO_DIR}/Cargo.toml" --)
fi

run_case() {
  local name=$1
  local reset_lock=$2
  shift 2
  echo
  echo "=== ${name} ==="
  (
    cd "${WORKSPACE_DIR}" >&2
    if [[ ${reset_lock} == yes ]]; then
      rm -f Cargo.lock
    fi
    env "$@" "${CMD_BIN}" "${CMD_ARGS[@]}" "${CARGO_SUBCOMMAND}"
  )
}

usage() {
  cat <<'USAGE'
Usage: ./smoke-test-crates-io.sh [CASE ...]

Run smoke-test scenarios for cargo-cooldown against the current crates.io
state. Unlike `test.sh`, this script is intentionally non-deterministic and is
meant to catch obvious breakage while exercising the live registry flow.

Available CASE values:
  allowlist            Run with a 3 month cooldown and the sample allowlist.
  warn-mode            Log violations without blocking the build.
  offline-cache        Reuse cached metadata to simulate offline runs.
  aggressive-ttl       Short cache TTL and dedicated cache directory.
  custom-registry      Override registry API and index values (mirrors).
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ ${CARGO_SUBCOMMAND} == "update" ]]; then
  echo "This demo is intended for build/check/run style commands. Running cargo-cooldown with 'cargo update' would overwrite the cooled-down Cargo.lock." >&2
  exit 1
fi

if [[ ! -d "${WORKSPACE_DIR}" ]]; then
  echo "Expected workspace at ${WORKSPACE_DIR}" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Expected demo configuration at ${CONFIG_FILE}" >&2
  exit 1
fi

SELECTED=("allowlist" "warn-mode" "offline-cache" "aggressive-ttl" "custom-registry")
if [[ $# -gt 0 ]]; then
  SELECTED=("$@")
fi

for case_name in "${SELECTED[@]}"; do
  case "${case_name}" in
    allowlist)
      run_case "allowlist" yes \
        COOLDOWN_MINUTES=131401 \
        COOLDOWN_ALLOWLIST_PATH="${ROOT_DIR}/cooldown-allowlist.toml"
      ;;
    warn-mode)
      run_case "warn-mode" yes \
        COOLDOWN_MODE=warn
      ;;
    offline-cache)
      mkdir -p "${CACHE_BASE}/offline"
      run_case "offline-cache" no \
        COOLDOWN_MINUTES=720 \
        COOLDOWN_CACHE_DIR="${CACHE_BASE}/offline" \
        COOLDOWN_TTL_SECONDS=604800 \
        COOLDOWN_OFFLINE_OK=1
      ;;
    aggressive-ttl)
      mkdir -p "${CACHE_BASE}/short-ttl"
      run_case "aggressive-ttl" yes \
        COOLDOWN_MINUTES=180 \
        COOLDOWN_CACHE_DIR="${CACHE_BASE}/short-ttl" \
        COOLDOWN_TTL_SECONDS=300 \
        COOLDOWN_HTTP_RETRIES=4 \
        COOLDOWN_VERBOSE=1
      ;;
    custom-registry)
      run_case "custom-registry" yes \
        COOLDOWN_REGISTRY_API="https://mirror.example/api/v1/" \
        COOLDOWN_REGISTRY_INDEX="registry+https://mirror.example/index"
      ;;
    *)
      echo "Unknown case: ${case_name}" >&2
      usage
      exit 1
      ;;
  esac
done
