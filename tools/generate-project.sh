#!/usr/bin/env bash
#
# Generate Twozz.xcodeproj while holding the machine-wide Apple build lease.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "twozz/generate-project"
install_apple_build_lease_traps

xcodegen generate "$@"
