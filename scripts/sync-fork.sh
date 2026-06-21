#!/bin/sh

# Syncs this fork with upstream:
#   1. Fetch upstream
#   2. Fast-forward $main_branch to upstream/$main_branch (bails if it has diverged)
#   3. Push $main_branch to origin
#   4. Rebase the current branch onto $main_branch
#
# Run from any branch you want rebased (typically `local`).
# This script lives on the fork's `local` branch — a personal workflow helper.

set -e

main_branch="main"

current_branch=$(git rev-parse --abbrev-ref HEAD)

if [ "$current_branch" = "$main_branch" ]; then
    echo "Refusing to run from $main_branch — check out your work branch first."
    exit 1
fi

if ! git diff-index --quiet HEAD --; then
    echo "Working tree is dirty. Commit or stash first."
    exit 1
fi

echo "==> Fetching upstream"
git fetch upstream

echo "==> Fast-forwarding $main_branch to upstream/$main_branch"
git checkout "$main_branch"
git merge --ff-only "upstream/$main_branch"

echo "==> Pushing $main_branch to origin"
git push origin "$main_branch"

echo "==> Rebasing $current_branch onto $main_branch"
git checkout "$current_branch"
git rebase "$main_branch"

echo
echo "Done. If you want to update origin/$current_branch:"
echo "  git push --force-with-lease origin $current_branch"
