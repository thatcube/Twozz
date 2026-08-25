# Contributing to Twozz

Thanks for your interest in Twozz. This document covers everything you need to
build, run, and develop the app. For what Twozz is and does, see the
[README](README.md).

Twozz is a solo, non-commercial hobby project. Bug reports, feature ideas, and
pull requests are welcome, but please keep in mind that reviews and merges may
take a while.

## Reporting bugs & requesting features

Please open a [GitHub issue](https://github.com/thatcube/Twozz/issues). For
bugs, include your Apple TV model and tvOS version, the channel or stream where
it happened, and steps to reproduce. For feature ideas, a short description of
what you want and why is plenty.

## Requirements

- macOS with Xcode installed (targets **tvOS 18+**).
- Homebrew tools:

  ```bash
  brew install xcodegen xcbeautify xcode-build-server
  ```

## Building and running

`Twozz.xcodeproj` is generated from `project.yml` (the source of truth), so
generate it first:

```bash
xcodegen generate
```

Build for the tvOS simulator:

```bash
xcodebuild \
	-project Twozz.xcodeproj \
	-scheme Twozz \
	-configuration Debug \
	-destination 'generic/platform=tvOS Simulator' \
	build | xcbeautify
```

For real Apple TV deployment, use a valid signing team and a device destination.
Several features (live playback, Top Shelf) only work on real hardware.

## Twitch auth setup (no committed secrets)

Twitch device auth needs a Twitch app `client_id`, but you don't commit it to
this repo.

1. Copy [`Config/TwitchSecrets.xcconfig.local.example`](Config/TwitchSecrets.xcconfig.local.example)
   to `Config/TwitchSecrets.xcconfig.local`.
2. Set your value:

   ```xcconfig
   TWITCH_CLIENT_ID = your_real_client_id
   ```

Important:

- Do not use Twitch's public web client ID (for example
  `kimne78kx3ncx6brgo4mv6wki5h1ko`). If you do, the consent page will show
  "Twilight" and followed-channel APIs may fail.
- Create your own Twitch app in the Twitch Developer Console and use that Client
  ID.

`Config/TwitchSecrets.xcconfig.local` is gitignored (`*.xcconfig.local`), so
your ID stays local.

On Apple TV, sign-in uses the Twitch Device Code flow: start sign-in on the TV,
then complete approval on your phone or browser using the shown code/link.

### Working in git worktrees

Because the secrets file is gitignored, it does **not** exist in freshly created
worktrees. After making a new worktree, run the bootstrap helper from inside it:

```bash
./tools/bootstrap-worktree.sh
```

This copies `Config/TwitchSecrets.xcconfig.local` from your primary checkout and
regenerates the Xcode project. Without it, builds fail with
"Missing Twitch client ID".

## Versioning & releases

Twozz follows the standard Apple two-number scheme, and both numbers update
automatically — you should not normally edit version numbers by hand:

- **Marketing version** — `CFBundleShortVersionString`, a semver like `0.2.0`,
  defined by `MARKETING_VERSION` in `project.yml`. It bumps one **minor** per
  feature merged into `main`. The [`version-bump`](.github/workflows/version-bump.yml)
  GitHub Actions workflow runs on every push to `main`, runs
  [`tools/bump-version.sh`](tools/bump-version.sh) (minor +1, patch → 0), and
  commits the change back to `main` with a `[skip ci]` marker. Bot pushes don't
  retrigger Actions, so the bump can't loop.
- **Build number** — `CFBundleVersion`, a monotonic integer derived from
  `git rev-list --count HEAD` by the `postBuildScripts` in `project.yml` (the app
  and the Top Shelf extension are kept in lockstep). It is set at build time and
  never hand-edited.

Manual bump (e.g. a major release): run `tools/bump-version.sh` or edit
`MARKETING_VERSION` in `project.yml`, then `xcodegen generate`.

Releases ship to TestFlight with fastlane using an App Store Connect API key:

```bash
cp .env.fastlane.example .env.fastlane   # fill in ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
fastlane beta --env fastlane             # archive a Release build + upload to TestFlight
```

`.env.fastlane` and the `.p8` key are gitignored — never commit them. Other
lanes: `fastlane build` (archive only, no upload), `fastlane release`,
`fastlane metadata`.

## How playback works

Apple TV has no official Twitch playback SDK. Twozz resolves playback via the
Twitch GraphQL PlaybackAccessToken and Usher HLS playlists, similar in spirit to
open-source clients like Streamlink and Frosty. Playback is AVPlayer-backed with
custom overlay controls and an in-process low-latency HLS proxy — see
[`docs/low-latency.md`](docs/low-latency.md) for the details of that work.

This project is non-commercial and ad-respecting.

## Tech stack

- Swift / SwiftUI targeting tvOS.
- AVPlayer-backed playback with custom overlay controls and an in-process
  low-latency HLS proxy.
- Twitch EventSub / Hermes for real-time raids, polls, predictions, and live
  events.
- A Top Shelf app extension for the tvOS home screen.
- XcodeGen project generation (`project.yml` is the source of truth).

## Things Twozz intentionally does not do

- **Auto-redeem channel points.** Twozz won't auto-claim channel points (the way
  the 7TV/FFZ browser extensions do). Twitch's official login that Twozz uses
  isn't accepted by the private API that claims points — that API only trusts a
  real twitch.tv web-session login. Supporting it would mean adding a second
  login where you type your Twitch password into the app and storing a
  full-account session token, plus fighting Twitch's anti-bot checks. It's also
  against Twitch's Terms of Service.
- **Follow / unfollow.** Twozz can show who you follow, but Twitch now blocks
  follow/unfollow mutations from this app context with integrity checks. Use the
  official Twitch app or website to change follows.
