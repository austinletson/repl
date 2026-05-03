#!/usr/bin/env bash
set -euo pipefail

# Automate the stacked-git workflow described in versioning.md
# Usage:
#   ./automate_versioning.sh <base_version> <new_version> <new_lean_version>
#
# Example:
#   ./automate_versioning.sh v1.3.8 1.3.9 v4.26.0

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <base_version> <new_version> <new_lean_version>" >&2
  exit 1
fi

BASE_VERSION=$1
NEW_VERSION=$2
NEW_LEAN_VERSION=$3
# BASE_BRANCH="master"
BASE_BRANCH="nightly"

confirm() {
  local prompt=${1:-"Continue?"}
  read -r -p "$prompt [y/N] " ans
  case "$ans" in
    [Yy]*) return 0 ;;
    *) echo "Aborted."; return 1 ;;
  esac
}

require_cmd() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "Error: required command '$c' not found in PATH" >&2
      exit 1
    fi
  done
}

require_cmd git stg lake

echo "Base version     : $BASE_VERSION"
echo "New version      : $NEW_VERSION"
confirm "Proceed with automated stacked-git workflow?" || exit 1

# 1. Duplicate last version branch

echo "\n==> Checking out base branch '$BASE_VERSION' and creating stacked-git branch '$NEW_VERSION'..."
git checkout "$BASE_VERSION"
stg branch -C "$NEW_VERSION"

# 2. Use stacked git to add a new (empty) commit

echo "\n==> Creating new stacked-git patch '$NEW_VERSION'..."
stg pop -a || true
stg new "$NEW_LEAN_VERSION" -m "$NEW_LEAN_VERSION"

# 3. Rebase the new branch on ${BASE_BRANCH}

echo "\n==> Rebasing stacked-git series on '$BASE_BRANCH'..."
stg rebase "$BASE_BRANCH"

# 4. Update the previous commit by reverting Lean-version specific changes in master

echo "\n==> Pushing current patch to git to prepare revert..."
stg push

echo "Current HEAD is:"
git log -1 --oneline

echo
read -r -p "Enter the commit id in master that introduced the Lean-version change to revert (empty to skip): " REVERT_COMMIT

if [[ -n "${REVERT_COMMIT}" ]]; then
  echo "\n==> Reverting commit $REVERT_COMMIT without committing..."
  git revert --no-commit "$REVERT_COMMIT"
else
  echo "Skipping git revert step (no commit id provided)."
fi

# 5. Let user inspect changes then run tests

echo "\n==> Showing status of working tree (please keep only version-change related edits):"
git status

echo
confirm "Run tests?" || exit 1

echo "\n==> Running tests with 'lake exe test'..."
lake exe test

echo "\nTests completed successfully."

# 6. If the tests pass, add the changes

echo "\n==> Refreshing current stacked-git patch with new changes..."
stg refresh

if [[ -n "${REVERT_COMMIT:-}" ]]; then
  echo "Aborting git revert sequence (cleanup)..."
  git revert --abort || true
fi

echo "\nDone."
