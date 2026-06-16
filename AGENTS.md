# AGENTS.md

Persistent workflow instructions for coding agents working in this repository.

## Branch policy (single branch only)

All work must stay on the current branch (normally `main`).

Rules:
1. Do not create new branches.
2. Do not switch branches.
3. Do not suggest branch-based workflows unless the user explicitly asks for branches.
4. Commit and push only to the currently checked out branch.

If a branch change is required, ask the user first.

## Always deploy after successful local build

When code changes are made and a build succeeds, always deploy the newest build to the paired Apple TV so the user can test immediately.

Required workflow after any code change:

1. Build the app (simulator or device build as appropriate).
2. If build succeeds, deploy latest app bundle to Apple TV.
3. Launch app on Apple TV.
4. Report deployment result (success/failure) in the response.

## Apple TV deployment command pattern

Use this reliable pattern to avoid stale DerivedData paths:

```bash
DEVICE_ID='DE913871-CC2D-5F75-B4F2-0D6F44AA30DE' && \
APP_PATH=$(xcodebuild -project Twitcher.xcodeproj -scheme Twitcher -destination "platform=tvOS,id=$DEVICE_ID" -showBuildSettings | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2; exit}') && \
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist") && \
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" && \
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
```

## Git workflow

When user asks to push, include all requested modified files in one commit, push to the current branch, then deploy to Apple TV and report commit hash.
