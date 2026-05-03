#!/bin/bash

set -e  # Exit on error

# Function to display usage
show_usage() {
  echo "Usage: $0 <remote-name> <tag-prefix>"
  echo "Example: $0 origin v1.0.0_lean-toolchain"
  echo "This will delete and re-push all tags starting with v1.0.0_lean-toolchain to trigger CI"
  exit 1
}

# Check that we have all required arguments
if [ $# -lt 2 ]; then
  show_usage
fi

REMOTE="$1"
TAG_PREFIX="$2"

# Get all tags matching the prefix
echo "Looking for tags with prefix: $TAG_PREFIX"
TAGS=$(git tag -l "${TAG_PREFIX}*")

if [ -z "$TAGS" ]; then
  echo "No tags found with prefix $TAG_PREFIX"
  exit 1
fi

# Count tags to process
TAG_COUNT=$(echo "$TAGS" | wc -w)
echo "Found $TAG_COUNT tags to retrigger CI."

# Display all tags
echo -e "\nPreparing to delete and re-push the following tags:"
echo "-------------------------------------------"
COUNTER=1
for TAG in $TAGS; do
  COMMIT=$(git rev-list -n 1 "$TAG")
  COMMIT_MSG=$(git log --format=%B -n 1 "$COMMIT" | head -n 1)

  echo "[$COUNTER/$TAG_COUNT] Tag: $TAG"
  echo "                Commit: ${COMMIT:0:8} - $COMMIT_MSG"
  echo ""

  COUNTER=$((COUNTER+1))
done

# Ask for confirmation
read -p "Do you want to delete and re-push these tags to trigger CI? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Operation cancelled."
  exit 0
fi

# Process each tag
echo -e "\nProcessing tags one by one to trigger CI..."

for TAG in $TAGS; do
  echo "Processing tag $TAG..."

  # Get the commit that the tag is pointing to
  COMMIT=$(git rev-list -n 1 "$TAG")

  # Delete only the remote tag
  echo "Deleting tag $TAG from $REMOTE..."
  git push --delete "$REMOTE" "$TAG" || {
    echo "Warning: Could not delete tag $TAG from remote. It might not exist remotely."
    echo "Continuing anyway..."
  }

  # Wait briefly to ensure GitHub registers the deletion
  echo "Waiting for GitHub to process deletion..."
  sleep 2

  # Push the existing local tag to the remote
  echo "Pushing tag $TAG to $REMOTE pointing to commit ${COMMIT:0:8}..."
  # Push the local tag to remote
  git push "$REMOTE" "$TAG"

  # Wait between tag operations to ensure GitHub registers each one separately
  echo "Waiting for GitHub to process new tag..."
  sleep 3

  echo "Completed processing tag $TAG"
  echo "-------------------------------------------"
done

echo -e "\nDone! All tags have been deleted from remote and re-pushed to trigger CI for each."
