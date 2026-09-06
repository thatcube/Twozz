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

repo_root="$(git rev-parse --show-toplevel)"

# The first entry from `git worktree list` is always the primary worktree.
# NB: do not let awk `exit` early here — closing the pipe makes `git` take a
# SIGPIPE, which under `set -o pipefail` fails the command and (with `set -e`)
# kills this script silently before any secret is copied. That only bites when
# the worktree list is large (many worktrees), so print just the first match
# without exiting and let git finish writing.
main_worktree="$(git worktree list --porcelain | awk '/^worktree / && !seen { print $2; seen = 1 }')"

# Files that are gitignored but wanted in every worktree: maintainer-local agent
# instructions, plus EVERY local build-secrets xcconfig. The secrets list is
# discovered dynamically (not hardcoded) so adding a new Config/*.xcconfig.local
# in the primary worktree — e.g. YouTubeSecrets — is picked up automatically and
# can never be silently dropped, which previously hid YouTube sign-in.
LOCAL_FILES=(
  "AGENTS.local.md"
)
if [[ -d "$main_worktree/Config" ]]; then
  while IFS= read -r secret; do
    LOCAL_FILES+=("Config/$(basename "$secret")")
  done < <(find "$main_worktree/Config" -maxdepth 1 -name '*.xcconfig.local' -type f | sort)
fi

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
  ( cd "$repo_root" && ./tools/generate-project.sh )
else
  echo "WARN   xcodegen not found; run 'brew install xcodegen' then './tools/generate-project.sh'"
fi

echo "Bootstrap complete."
