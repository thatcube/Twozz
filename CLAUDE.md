# CLAUDE.md

Repository instructions for Claude-style agents.

## Branch policy (single branch only)

All work must stay on the current branch (normally `main`).

Rules:
1. Do not create new branches.
2. Do not switch branches.
3. Do not suggest branch-based workflows unless the user explicitly asks for branches.
4. Commit and push only to the currently checked out branch.

If a branch change is required, ask the user first.

## Deploy-to-device rule (always)

After any code change that is successfully built, always deploy and launch the latest build on the paired Apple TV for immediate user testing.

Required sequence:

1. Build.
2. Install latest app bundle on Apple TV.
3. Launch app on Apple TV.
4. Report deployment outcome.

## Apple TV target

- Device ID: `DE913871-CC2D-5F75-B4F2-0D6F44AA30DE`

## Recommended install/launch command

```bash
DEVICE_ID='DE913871-CC2D-5F75-B4F2-0D6F44AA30DE' && \
APP_PATH=$(xcodebuild -project Twitcher.xcodeproj -scheme Twitcher -destination "platform=tvOS,id=$DEVICE_ID" -showBuildSettings | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2; exit}') && \
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist") && \
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" && \
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
```
