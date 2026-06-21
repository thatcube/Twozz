<p align="center">
  <img src="Branding/twizz_logo.svg" alt="Twizz logo" width="128" />
</p>

<h1 align="center">Twizz</h1>

<p align="center">
  A free, open-source Apple TV app for watching Twitch with a fast, chat-first viewing experience and native external emote support.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple" alt="Platform: tvOS" /></a>
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

## Features

Sign in & navigation:

- Sign in with Twitch using the Device Code flow (approve on your phone or browser); tokens are stored securely and refresh automatically.
- Four tabs: Home, Browse, Search, and Settings.

Home & discovery:

- Home shows the channels you follow that are live now, plus recommendations.
- Optional personalized recommendations built from on-device watch history and your followed categories — or anonymous trending when you're signed out or have it turned off.
- Browse top categories and the live streams within them.
- Search channels and categories with live results.
- Channel pages with top clips, past broadcasts (VODs), and similar channels.
- Apple TV Top Shelf surfaces your live follows and recommendations on the tvOS home screen.

Playback:

- Live playback on real Apple TV hardware, with a side-by-side layout: video on the left, chat pane on the right.
- Quality picker with persistence (`Auto` + explicit qualities), ordered highest-to-lowest.
- Low-latency mode (on by default) that closes most of the gap to the live edge.
- Stream rewind (DVR): seek back within the live window.
- Audio-only mode with a reactive audio visualizer — handy for music, just-chatting, or background listening.
- Custom bottom overlay controls built for the tvOS focus engine.
- Sleep timer tucked inside the quality menu (timed or "end of stream") with a "still watching?" check, an animated starry "Sleeping" screen, and one-press resume that snaps back to the live edge.
- VOD and clip playback from channel pages; VODs include synced chat replay and variable speed (0.5×–2×).
- Optional diagnostics overlay for latency and buffer stats.

Chat:

- Anonymous read via Twitch IRC over WebSocket, with auto-reconnect.
- Send messages when signed in.
- Twitch badges (global + channel-specific) and cheermotes (bits).
- Emotes: Twitch native (incl. channel/sub), 7TV, BTTV, and FFZ (global + channel), including animated emotes.
- Extensive chat appearance controls: text and emote size, font (including OpenDyslexic), spacing, width, and layout (side / overlay / glass).
- Incoming and outgoing raid banners.
- Live polls, predictions, hype trains, and creator goals surfaced as passive, display-only overlays.
- "Just went live" toast for followed channels, with one tap to switch over.
- Experimental: merge a YouTube live chat into the Twitch chat pane.

Appearance:

- Themes: System, Dark, OLED, and Light.
- Adjustable stream-card sizes and a stream-language filter.

## Tech Stack

- Swift / SwiftUI targeting tvOS.
- AVPlayer-backed playback with custom overlay controls and an in-process low-latency HLS proxy.
- Twitch EventSub / Hermes for real-time raids, polls, predictions, and live events.
- A Top Shelf app extension for the tvOS home screen.
- XcodeGen project generation (`project.yml` is source of truth).

## Build & Run

Prerequisites:

- macOS with Xcode installed.
- Homebrew tools:

```bash
brew install xcodegen xcbeautify xcode-build-server
```

Generate the project:

```bash
xcodegen generate
```

Build:

```bash
xcodebuild \
	-project Twizz.xcodeproj \
	-scheme Twizz \
	-configuration Debug \
	-destination 'generic/platform=tvOS Simulator' \
	build | xcbeautify
```

For real Apple TV deployment, use a valid signing team and a device destination.

## Twitch Auth Setup (No Committed Secrets)

Twitch device auth still needs a Twitch app `client_id`, but you do not need to commit it to this repo.

1. Copy [Config/TwitchSecrets.xcconfig.local.example](Config/TwitchSecrets.xcconfig.local.example) to `Config/TwitchSecrets.xcconfig.local`.
2. Set your value:

```xcconfig
TWITCH_CLIENT_ID = your_real_client_id
```

Important:

- Do not use Twitch's public web client ID (for example `kimne78kx3ncx6brgo4mv6wki5h1ko`).
- If you do, the consent page will show "Twilight" and followed-channel APIs may fail.
- Create your own Twitch app in the Twitch Developer Console and use that Client ID.

`Config/TwitchSecrets.xcconfig.local` is gitignored (`*.xcconfig.local`), so your ID stays local.

### Working in git worktrees

Because the secrets file is gitignored, it does **not** exist in freshly created
worktrees. After making a new worktree, run the bootstrap helper from inside it:

```bash
./tools/bootstrap-worktree.sh
```

This copies `Config/TwitchSecrets.xcconfig.local` from your primary checkout and
regenerates the Xcode project. Without it, builds fail with
"Missing Twitch client ID".

On Apple TV, sign-in uses Twitch Device Code flow: start sign-in on TV, then complete approval on your phone/browser (including the Twitch mobile app browser flow) using the shown code/link.

## Versioning & Releases

Twizz follows the standard Apple two-number scheme, and both numbers update
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

## How Playback Works

Apple TV has no official Twitch playback SDK. Twizz resolves playback via Twitch GraphQL PlaybackAccessToken and Usher HLS playlists, similar in spirit to open-source clients like Streamlink and Frosty.

This project is non-commercial and ad-respecting.

## Not Supported: Auto-Redeeming Channel Points

Twizz won't auto-claim channel points (the way the 7TV/FFZ browser extensions do). Twitch's official login that Twizz uses isn't accepted by the private API that claims points — that API only trusts a real twitch.tv web-session login. Supporting it would mean adding a second login where you type your Twitch password into the app and storing a full-account session token, plus fighting Twitch's anti-bot checks. It's also against Twitch's Terms of Service. Not worth the security risk and fragility, so we're not doing it.

## Not Supported: Follow / Unfollow Actions

Twizz can show who you follow, but Twitch now blocks follow/unfollow mutations from this app context with integrity checks. Because of that Twitch-side restriction, Twizz does not expose follow/unfollow controls — use the official Twitch app or website to change follows.

## Ideas & Improvements

A running list of things we're considering but haven't built yet:

- **Multi-view & Picture-in-Picture** — watch two streams at once, or shrink the player to a corner while you browse for the next channel.
- **SharePlay watch-together** — sync playback (and a shared reaction layer) over FaceTime; a social differentiator unique to the Apple ecosystem.
- **Moderator mode** — timeout / ban / delete and a mod-action log from the couch for users who mod.
- **Chat keyword highlights + mention ping** — client-side highlighting for keywords and your username in busy chats.
- **Freeze-chat-on-focus** — pause autoscroll while you're reading so it doesn't fight you.
- **Siri & deep search** — "Play _channel_ on Twizz" and system-Search results that jump straight into playback.
- **Per-channel memory** — remember preferred quality, chat width, and audio-only state per channel.
- **Deeper accessibility** — VoiceOver labels for chat lines and cards, and a captions toggle where available.

## Donate

Twizz is free and open source, and it always will be. There's no paywall, no ads, and no obligation to give anything.

If the app has been useful to you and you'd like to chip in toward its upkeep — things like the Apple Developer Program fee and time spent maintaining it — donations are welcome and genuinely appreciated. Anything is plenty, and not donating is completely fine too.

[![Donate](https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/thatcube)

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time or recurring, whatever suits you.

## License

[MIT](LICENSE) © 2026 thatcube

Not affiliated with or endorsed by Twitch Interactive, Inc.
