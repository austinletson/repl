#!/usr/bin/env bash

set -euo pipefail

LEAN_REPO="https://github.com/leanprover/lean4.git"
MATHLIB_REPO="https://github.com/leanprover-community/mathlib4.git"
SINCE_VERSION="v4.8.0"
REPL_VERSION=""
SHOW_ALL=false
LOG_FILE=""

usage() {
  cat <<'USAGE'
Usage: ./list_missing_versions.sh [options]

Options:
  --repl-version VERSION   Check tags for a specific REPL version branch, e.g. v1.3.15.
                           Defaults to the current branch when it looks like v1.*,
                           otherwise to the newest local v1.* tag prefix.
  --since VERSION          Only consider Lean versions >= VERSION. Default: v4.8.0.
  --all                    Show supported and missing versions.
  --lean-repo URL          Lean repository URL.
  --mathlib-repo URL       Mathlib repository URL.
  --log-file PATH          Write a copy of the output to PATH. Default: logs/list_missing_versions-<timestamp>.log.
  -h, --help               Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repl-version)
      REPL_VERSION="${2:?missing value for --repl-version}"
      shift 2
      ;;
    --since)
      SINCE_VERSION="${2:?missing value for --since}"
      shift 2
      ;;
    --all)
      SHOW_ALL=true
      shift
      ;;
    --lean-repo)
      LEAN_REPO="${2:?missing value for --lean-repo}"
      shift 2
      ;;
    --mathlib-repo)
      MATHLIB_REPO="${2:?missing value for --mathlib-repo}"
      shift 2
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

if [[ -z "$LOG_FILE" ]]; then
  mkdir -p logs
  LOG_FILE="logs/list_missing_versions-$(date +%Y%m%d_%H%M%S).log"
else
  mkdir -p "$(dirname "$LOG_FILE")"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

version_ge() {
  local candidate="$1"
  local floor="$2"
  [[ "$(printf '%s\n%s\n' "$candidate" "$floor" | sort -V | head -n 1)" == "$floor" ]]
}

if [[ -z "$REPL_VERSION" ]]; then
  current_branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ "$current_branch" =~ ^v1\. ]]; then
    REPL_VERSION="$current_branch"
  else
    REPL_VERSION="$(git tag --list 'v1.*_lean-toolchain-v4.*' \
      | sed -E 's/^(v1\.[^_]+)_lean-toolchain-.*/\1/' \
      | sort -Vu \
      | tail -n 1)"
  fi
fi

if [[ -z "$REPL_VERSION" ]]; then
  echo "Could not infer a REPL version. Pass --repl-version v1.x.y." >&2
  exit 1
fi

echo "Log file: $LOG_FILE"
echo "REPL version: $REPL_VERSION"
echo "Lean repo: $LEAN_REPO"
echo "Mathlib repo: $MATHLIB_REPO"
echo "Minimum Lean version: $SINCE_VERSION"
echo

declare -A supported=()
while IFS= read -r version; do
  [[ -n "$version" ]] && supported["$version"]=1
done < <(git tag --list "${REPL_VERSION}_lean-toolchain-v4.*" \
  | sed -E 's/^v1\.[^_]+_lean-toolchain-(v4\..*)$/\1/' \
  | sort -u)

declare -A mathlib=()
while IFS= read -r version; do
  [[ -n "$version" ]] && mathlib["$version"]=1
done < <(git ls-remote --tags "$MATHLIB_REPO" 'refs/tags/v4.*' \
  | sed 's#.*refs/tags/##; s#\^{}##' \
  | grep '^v4\.' \
  | sort -u)

mapfile -t lean_versions < <(git ls-remote --tags "$LEAN_REPO" 'refs/tags/v4.*' \
  | sed 's#.*refs/tags/##; s#\^{}##' \
  | grep '^v4\.' \
  | sort -u \
  | sort -V)

missing_count=0
shown_count=0

printf '%-18s %-10s %-12s %s\n' "Lean version" "REPL tag" "Mathlib tag" "Action"
printf '%-18s %-10s %-12s %s\n' "------------" "--------" "-----------" "------"

for version in "${lean_versions[@]}"; do
  if ! version_ge "$version" "$SINCE_VERSION"; then
    continue
  fi

  repl_status="missing"
  action="add Lean-version patch"
  if [[ -n "${supported[$version]:-}" ]]; then
    repl_status="present"
    action="none"
  else
    missing_count=$((missing_count + 1))
  fi

  mathlib_status="missing"
  if [[ -n "${mathlib[$version]:-}" ]]; then
    mathlib_status="present"
    if [[ "$repl_status" == "missing" ]]; then
      action="add patch with Mathlib tests"
    fi
  elif [[ "$repl_status" == "missing" ]]; then
    action="add patch with Mathlib tests disabled"
  fi

  if [[ "$SHOW_ALL" == true || "$repl_status" == "missing" ]]; then
    printf '%-18s %-10s %-12s %s\n' "$version" "$repl_status" "$mathlib_status" "$action"
    shown_count=$((shown_count + 1))
  fi
done

echo
echo "Rows shown: $shown_count"
echo "Missing Lean versions for $REPL_VERSION: $missing_count"
