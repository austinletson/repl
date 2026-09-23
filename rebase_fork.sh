# List of branches to rebase (space-separated, assumed stacked in order)
branches="fix-sorry-ctx incremental_processing auto-prefix-optimization declaration-extraction add-set-option"

# Check for command line arguments
if [ $# -ne 2 ]; then
  echo "Usage: $0 <old_base> <new_base>"
  exit 1
fi

# Old base (commit/branch/ref they diverge from)
old_base=$1

# New base (target to rebase onto)
new_base=$2

for branch in $branches; do
  # Check if branch is already rebased (resumable)
  if git merge-base --is-ancestor $new_base $branch 2>/dev/null; then
    echo "Branch $branch is already rebased onto $new_base, skipping."
    continue
  fi

  echo "Rebasing $branch onto $new_base..."
  git checkout $branch
  git rebase --onto $new_base $old_base $branch
  if [ $? -ne 0 ]; then
    echo "Rebase failed for $branch. Resolve conflicts and run 'git rebase --continue', then rerun the script."
    break
  fi

  # Run tests after successful rebase
  echo "Running lake exe repl for $branch..."
  lake exe repl
  if [ $? -ne 0 ]; then
    echo "lake exe repl failed for $branch. Fix issues and rerun the script."
    break
  fi

  echo "Running lake exe test for $branch..."
  lake exe test
  if [ $? -ne 0 ]; then
    echo "lake exe test failed for $branch. Fix issues and rerun the script."
    break
  fi

  echo "Branch $branch rebased and tested successfully."
done
