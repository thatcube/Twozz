# Twizz

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: tvOS](https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple)](https://www.apple.com/apple-tv-4k/)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/thatcube)

A free, open-source Apple TV app for watching Twitch with a fast, chat-first viewing experience and native external emote support.

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
- Raid detection with a "Follow Raid" banner to hop to the raid target.
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

## Roadmap

See [Twizz-plan.md](Twizz-plan.md) for detailed phased planning.

## Sponsor

Twizz is free and open source, built and maintained in spare time. If it's useful to you, consider supporting development — it helps cover Apple Developer Program fees and keeps the project moving.

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/thatcube)

👉 **[Become a sponsor on GitHub Sponsors](https://github.com/sponsors/thatcube)**

Every contribution, one-time or recurring, is appreciated. ❤️

## License

[MIT](LICENSE) © 2026 thatcube

Not affiliated with or endorsed by Twitch Interactive, Inc.
