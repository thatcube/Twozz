#!/usr/bin/env bash
#
# bump-version.sh — bump the app's marketing version (CFBundleShortVersionString).
#
# Twizz uses an industry-standard two-number scheme:
#   * MARKETING_VERSION (CFBundleShortVersionString) — the semver marketing
#     version shown to users, e.g. 0.2.0. Bumped one MINOR per merged feature.
#   * CURRENT_PROJECT_VERSION / CFBundleVersion — a monotonic build number
#     derived from `git rev-list --count HEAD` at build time (see project.yml
#     postBuildScripts). This script never touches the build number.
#
# project.yml (XcodeGen source of truth) holds MARKETING_VERSION under
# settings.base. This script reads it, increments the MINOR component, resets
# PATCH to 0, and writes it back. The next `xcodegen generate` propagates the
# value into the app and TopShelf extension Info.plists (both reference
# $(MARKETING_VERSION)).
#
# It resolves project.yml relative to its own location, so it runs correctly
# from any worktree or working directory.
#
# USAGE
#   tools/bump-version.sh            # bump minor: 0.1.0 -> 0.2.0
#   tools/bump-version.sh --dry-run  # print what would change, write nothing
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_yml="$script_dir/../project.yml"

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
elif [[ -n "${1:-}" ]]; then
  echo "bump-version.sh: unknown argument '$1' (only --dry-run is supported)" >&2
  exit 2
fi

if [[ ! -f "$project_yml" ]]; then
  echo "bump-version.sh: cannot find project.yml at $project_yml" >&2
  exit 1
fi

# Pull the current value from the single MARKETING_VERSION line under
# settings.base. project.yml defines it exactly once.
current="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?[[:space:]]*$/\1/p' "$project_yml" | head -n1)"

if [[ -z "$current" ]]; then
  echo "bump-version.sh: could not read a semver MARKETING_VERSION (X.Y.Z) from project.yml" >&2
  exit 1
fi

IFS='.' read -r major minor _patch <<<"$current"
new="${major}.$((minor + 1)).0"

if [[ "$new" == "$current" ]]; then
  echo "bump-version.sh: no change ($current)"
  exit 0
fi

if [[ "$dry_run" == "1" ]]; then
  echo "bump-version.sh: would bump MARKETING_VERSION $current -> $new (dry run)"
  exit 0
fi

# Replace only the first MARKETING_VERSION line, preserving the quoted style.
tmp="$(mktemp)"
awk -v new="$new" '
  !done && $0 ~ /^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?[0-9]+\.[0-9]+\.[0-9]+"?[[:space:]]*$/ {
    sub(/"?[0-9]+\.[0-9]+\.[0-9]+"?[[:space:]]*$/, "\"" new "\"")
    done = 1
  }
  { print }
' "$project_yml" >"$tmp"
mv "$tmp" "$project_yml"

echo "bump-version.sh: bumped MARKETING_VERSION $current -> $new"
