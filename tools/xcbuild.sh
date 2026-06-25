#!/usr/bin/env bash
#
# xcbuild.sh — xcodebuild wrapper that neutralises a host-injected git setting
# so Swift Package Manager can resolve dependencies.
#
# WHY THIS EXISTS
# ---------------
# This project is developed inside the GitHub desktop/CLI app, which injects
# the following environment variables into every shell it spawns:
#
#     GIT_CONFIG_COUNT=1
#     GIT_CONFIG_KEY_0=safe.bareRepository
#     GIT_CONFIG_VALUE_0=explicit
#
# That forces `safe.bareRepository=explicit` onto *every* git invocation. Swift
# Package Manager stores its dependency checkouts (SDWebImage, etc.) as *bare*
# git repositories and operates on them by path, which that setting forbids. As
# a result `xcodebuild` fails during "Resolve Package Graph" with:
#
#     fatal: cannot use bare repository '…' (safe.bareRepository is 'explicit')
#
# These env vars are re-injected for each new shell, so they can't be unset
# permanently. This wrapper relaxes only that one value back to git's default
# ("all") for the build subprocess, which lets SPM resolve packages. Nothing is
# changed globally and no other injected config is touched.
#
# USAGE
# -----
#   ./tools/xcbuild.sh <any xcodebuild args>
#
#   e.g. ./tools/xcbuild.sh -project Twozz.xcodeproj -scheme Twozz \
#          -destination "platform=tvOS,id=$DEVICE_ID" build
#
set -euo pipefail

# Only override when the host injected exactly the key we know about, so we
# don't clobber any other GIT_CONFIG_* the environment may legitimately set.
if [[ "${GIT_CONFIG_KEY_0:-}" == "safe.bareRepository" ]]; then
  export GIT_CONFIG_VALUE_0=all
fi

_xcbuild_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Non-fatal secrets sanity check. The app's Config/App.xcconfig pulls local
# build secrets in via `#include? "<name>.xcconfig.local"` lines (gitignored,
# per-worktree). When one of those files is missing or empty the include
# silently no-ops, the keys resolve empty, and dependent features quietly
# disappear (e.g. YouTube sign-in vanishes from Settings) — with a green build
# and no error. Surface that here so a build "without the correct keys" is
# visible instead of silent. Warnings only; external contributors can build
# without secrets on purpose, so this never fails the build. All output goes to
# stderr so stdout (parsed by callers, e.g. -showBuildSettings) stays clean.
if [[ "$*" != *"-showBuildSettings"* ]]; then
  _xcbuild_app_xcconfig="$_xcbuild_root/Config/App.xcconfig"
  if [[ -f "$_xcbuild_app_xcconfig" ]]; then
    while IFS= read -r _inc; do
      _f="$_xcbuild_root/Config/$_inc"
      if [[ ! -f "$_f" ]]; then
        echo "xcbuild.sh: WARNING: Config/$_inc is missing; the secrets it provides will be empty and dependent features may be hidden (e.g. YouTube sign-in). Run ./tools/bootstrap-worktree.sh" >&2
      elif ! grep -Eq '^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*[^[:space:]]' "$_f"; then
        echo "xcbuild.sh: WARNING: Config/$_inc has no non-empty values; dependent features may be hidden (e.g. YouTube sign-in)." >&2
      fi
    done < <(grep -oE '#include\? +"[^"]+\.xcconfig\.local"' "$_xcbuild_app_xcconfig" | sed -E 's/.*"([^"]+)".*/\1/')
  fi
fi

# Derive the build number from the git commit count and pass it as a build
# setting, so CFBundleVersion is the real monotonic count for BOTH the app and
# its Top Shelf extension. Doing it as a setting (rather than patching the built
# Info.plist afterwards) means the value is baked in during normal plist
# processing and can't be silently reverted to the project default of "1".
_xcbuild_build_number="$(git -C "$_xcbuild_root" rev-list --count HEAD 2>/dev/null || true)"
_xcbuild_extra=()
if [[ -n "$_xcbuild_build_number" && "$*" != *"CURRENT_PROJECT_VERSION="* ]]; then
  _xcbuild_extra+=("CURRENT_PROJECT_VERSION=$_xcbuild_build_number")
fi

exec xcodebuild "$@" ${_xcbuild_extra[@]+"${_xcbuild_extra[@]}"}
