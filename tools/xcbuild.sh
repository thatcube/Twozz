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
#   e.g. ./tools/xcbuild.sh -project Twizz.xcodeproj -scheme Twizz \
#          -destination "platform=tvOS,id=$DEVICE_ID" build
#
set -euo pipefail

# Only override when the host injected exactly the key we know about, so we
# don't clobber any other GIT_CONFIG_* the environment may legitimately set.
if [[ "${GIT_CONFIG_KEY_0:-}" == "safe.bareRepository" ]]; then
  export GIT_CONFIG_VALUE_0=all
fi

exec xcodebuild "$@"
