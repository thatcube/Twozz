#!/usr/bin/env bash
#
# bootstrap-worktree.sh
#
# Copies gitignored local config (e.g. TwitchSecrets.xcconfig.local) from the
# primary git worktree into the current worktree, then generates the Xcode
# project. Run this once right after creating a new worktree.
#
#   ./tools/bootstrap-worktree.sh
#
set -euo pipefail

# Files that are gitignored but wanted in every worktree (build secrets plus
# maintainer-local agent instructions).
LOCAL_FILES=(
  "Config/TwitchSecrets.xcconfig.local"
  "AGENTS.local.md"
)

repo_root="$(git rev-parse --show-toplevel)"

# The first entry from `git worktree list` is always the primary worktree.
main_worktree="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"

if [[ "$main_worktree" == "$repo_root" ]]; then
  echo "You are in the primary worktree ($repo_root); nothing to copy."
else
  for rel in "${LOCAL_FILES[@]}"; do
    src="$main_worktree/$rel"
    dst="$repo_root/$rel"
    if [[ -f "$dst" ]]; then
      echo "skip   $rel (already present)"
    elif [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      echo "copied $rel  <-  $main_worktree"
    else
      echo "WARN   $rel missing in primary worktree ($src); set it up there first"
    fi
  done
fi

# Regenerate the (gitignored) Xcode project for this worktree.
if command -v xcodegen >/dev/null 2>&1; then
  ( cd "$repo_root" && xcodegen generate )
else
  echo "WARN   xcodegen not found; run 'brew install xcodegen' then 'xcodegen generate'"
fi

echo "Bootstrap complete."
