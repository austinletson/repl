#!/usr/bin/env bash

# Update this patch to a Lean version.
#
# Usage:
#   ./update_lean_version.sh <new_version> [--skip-mathlib] [--allow-dirty]
#     [--log-file PATH]
#
# Examples:
#   ./update_lean_version.sh v4.30.0-rc2
#   ./update_lean_version.sh v4.30.0-rc2 --skip-mathlib
#
# If the Lean version has no matching Mathlib tag, Mathlib dependency updates
# and Mathlib tests are disabled automatically.

set -euo pipefail

MATHLIB_REPO="https://github.com/leanprover-community/mathlib4.git"
SKIP_MATHLIB=false
ALLOW_DIRTY=false
LOG_FILE=""

usage() {
  cat <<'USAGE'
Usage: ./update_lean_version.sh <new_version> [options]

Options:
  --skip-mathlib      Do not update Mathlib dependencies or run Mathlib tests.
                      This is also selected automatically when Mathlib has no tag.
  --allow-dirty       Allow tracked local changes before the script starts.
  --log-file PATH     Write command output to PATH. Default: logs/update_lean_version-<version>-<timestamp>.commands.log.
  -h, --help          Show this help.
USAGE
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

NEW_VERSION="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-mathlib)
      SKIP_MATHLIB=true
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    --log-file)
      LOG_FILE="${2:?missing value for --log-file}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$NEW_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-A-Za-z0-9.]+)?$ ]]; then
  echo "Expected a Lean version like v4.30.0 or v4.30.0-rc2, got: $NEW_VERSION" >&2
  exit 1
fi

safe_version="${NEW_VERSION//[^A-Za-z0-9._-]/_}"
timestamp="$(date +%Y%m%d_%H%M%S)"

if [[ -z "$LOG_FILE" ]]; then
  mkdir -p logs
  LOG_FILE="logs/update_lean_version-${safe_version}-${timestamp}.commands.log"
else
  mkdir -p "$(dirname "$LOG_FILE")"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

run() {
  log "RUN: $*"
  "$@"
}

write_if_changed() {
  local path="$1"
  local content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    log "unchanged: $path"
  else
    log "write: $path"
    printf '%s\n' "$content" > "$path"
  fi
}

mathlib_tag_exists() {
  git ls-remote --exit-code --tags "$MATHLIB_REPO" "refs/tags/$NEW_VERSION" >/dev/null 2>&1
}

update_mathlib_lakefile_lean() {
  local path="$1"
  if [[ -f "$path" ]]; then
    log "update Mathlib revision in $path"
    sed -i -E '/mathlib4/ s#@ "v[^"]+"#@ "'"$NEW_VERSION"'"#' "$path"
  fi
}

update_mathlib_lakefile_toml() {
  local path="$1"
  if [[ -f "$path" ]]; then
    log "update Mathlib revision in $path"
    sed -i -E 's#rev = "v[^"]+"#rev = "'"$NEW_VERSION"'"#' "$path"
  fi
}

log "Log file: $LOG_FILE"
log "Updating Lean version to $NEW_VERSION"
log "Current branch: $(git branch --show-current 2>/dev/null || echo unknown)"
log "Current HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [[ "$ALLOW_DIRTY" != true ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "Tracked local changes are present. Re-run with --allow-dirty only if this is intentional."
    git status --short
    exit 1
  fi
fi

MATHLIB_AVAILABLE=false
if [[ "$SKIP_MATHLIB" == true ]]; then
  log "Mathlib explicitly skipped."
elif mathlib_tag_exists; then
  MATHLIB_AVAILABLE=true
  log "Found Mathlib tag $NEW_VERSION."
else
  SKIP_MATHLIB=true
  log "No Mathlib tag found for $NEW_VERSION; Mathlib dependency update and tests will be skipped."
fi

write_if_changed "lean-toolchain" "leanprover/lean4:$NEW_VERSION"

if [[ "$MATHLIB_AVAILABLE" == true ]]; then
  if [[ -f "test/Mathlib/lean-toolchain" ]]; then
    write_if_changed "test/Mathlib/lean-toolchain" "leanprover/lean4:$NEW_VERSION"
  fi
  update_mathlib_lakefile_lean "test/Mathlib/lakefile.lean"
  update_mathlib_lakefile_toml "test/Mathlib/lakefile.toml"
else
  log "Leaving test/Mathlib dependency files unchanged because Mathlib is unavailable or skipped."
fi

log "Removing generated Lake build directories."
run rm -rf .lake test/Mathlib/.lake

if [[ "$MATHLIB_AVAILABLE" == true ]]; then
  log "Updating Mathlib Lake manifest."
  (cd test/Mathlib && run lake update)
fi

log "Building root project."
run lake build

if [[ "$MATHLIB_AVAILABLE" == true ]]; then
  log "Running root and Mathlib tests."
  export RUN_MATHLIB=1
  run lake exe test
else
  log "Running root tests with Mathlib disabled."
  export RUN_MATHLIB=0
  run lake exe test
fi

log "Update completed for $NEW_VERSION."
