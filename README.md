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

Home & browse:

- Sign in with Twitch (Device Code flow) with automatic token refresh.
- Followed channels on Home, auto-refreshed when stale.
- Browse tab for top categories and live streams.

Playback:

- Live playback on real Apple TV hardware.
- Side-by-side layout: video on the left, chat pane on the right.
- Quality picker with persistence (`Auto` + explicit qualities), ordered highest-to-lowest.
- Custom bottom overlay controls with tvOS focus navigation.

Chat:

- Anonymous read via Twitch IRC over WebSocket, with auto-reconnect.
- Send messages when signed in (`user:write:chat`).
- Twitch badges (global + channel-specific).
- Emotes: Twitch native (incl. channel/sub), 7TV, BTTV, and FFZ (global + channel).
- Incoming raid detection with a passive banner (no "follow" — you're already on the channel being raided).
- Experimental: merge a YouTube live chat into the Twitch chat pane.

## Tech Stack

- Swift / SwiftUI targeting tvOS.
- AVPlayer-backed playback with custom overlay controls.
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

## How Playback Works

Apple TV has no official Twitch playback SDK. Twizz resolves playback via Twitch GraphQL PlaybackAccessToken and Usher HLS playlists, similar in spirit to open-source clients like Streamlink and Frosty.

This project is non-commercial and ad-respecting.

## Not Supported: Auto-Redeeming Channel Points

Twizz won't auto-claim channel points (the way the 7TV/FFZ browser extensions do). Twitch's official login that Twizz uses isn't accepted by the private API that claims points — that API only trusts a real twitch.tv web-session login. Supporting it would mean adding a second login where you type your Twitch password into the app and storing a full-account session token, plus fighting Twitch's anti-bot checks. It's also against Twitch's Terms of Service. Not worth the security risk and fragility, so we're not doing it.

## Not Supported: Follow / Unfollow Actions

Twizz can show who you follow, but Twitch now blocks follow/unfollow mutations from this app context with integrity checks. Because of that Twitch-side restriction, Twizz does not expose follow/unfollow controls — use the official Twitch app or website to change follows.

## Roadmap

See [Twizz-plan.md](Twizz-plan.md) for detailed phased planning.

## Donate

Twizz is free and open source, and it always will be. There's no paywall, no ads, and no obligation to give anything.

If the app has been useful to you and you'd like to chip in toward its upkeep — things like the Apple Developer Program fee and time spent maintaining it — donations are welcome and genuinely appreciated. Anything is plenty, and not donating is completely fine too.

[![Donate](https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/thatcube)

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time or recurring, whatever suits you.

## License

[MIT](LICENSE) © 2026 thatcube

Not affiliated with or endorsed by Twitch Interactive, Inc.
