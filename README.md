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
- Sleep timer tucked inside the quality menu (timed or "end of stream") with a "still watching?" check, an animated starry "Sleeping" screen, and one-press resume that snaps back to the live edge.

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

## Ideas & Improvements

A running list of features we're considering, roughly ordered by effort.

### Quick wins (low effort, high delight)

| Feature | Why people want it | Why it's quick here |
|---|---|---|
| **"Go Live" button + latency indicator** | Web/mobile have it; viewers hate drifting behind | We already have `LowLatencyHLSProxy`; just expose seek-to-live edge + a delay badge in the overlay. |
| **"Just went live" toast for follows** | Discovery — catch a stream the moment it starts | We already run `EventSubService` (`stream.online`). Surface it as a banner like the raid banner. |
| **Chat keyword highlights + mention ping** | Chatterino's most-loved feature; makes big chats usable | Client-side string match in `RichChatLineView` + a settings list. |
| **Freeze-chat-on-focus** | Power users want to read without autoscroll fighting them | Pause the rolling buffer's autoscroll while the chat pane is focused. |
| **Audio-only / "screen off" mode** | Background-listening (music / just-chatting / podcasts), saves bandwidth | We already have `AudioOnlyLevelDecoder` + `AudioVisualizerView` — wrap it as a deliberate mode. |

### Bigger bets (features that make Twizz exceptional)

Researched against what Twitch power-users (the Chatterino / Frosty / Streamlink crowds) and Apple TV viewers consistently ask for — and what the official tvOS app does poorly:

- **Multi-view & Picture-in-Picture** — watch two streams at once, or shrink the player to a corner while you browse for the next channel. tvOS supports PiP via `AVPlayer`; the official app can't. Great for events, IRL, and GDQ-style marathons.
- **VOD & clip playback with synced chat replay** — build on `OnDemandPlayerView` to scrub VODs with the original chat replayed in time. Even Twitch's own TV experience handles this badly.
- **SharePlay watch-together** — sync playback (and a shared reaction layer) over FaceTime. A social differentiator unique to the Apple ecosystem.
- **Live polls / predictions / hype-train overlay** — passively surface active polls, predictions, and goals via `EventSubService` so couch viewers don't miss interactive moments (display-only — no channel-point redemption, see the section above).
- **Moderator mode** — timeout / ban / delete and a mod-action log from the couch for users who mod. Niche but beloved by the power-user crowd.
- **Chat ambience layer** — messages-per-minute, top-emotes-right-now, and raid / hype-train celebrations rendered as lightweight native moments. Leans into Twizz's chat-first identity.
- **Smarter discovery** — lean on `SimilarChannelsEngine` + `PersonalizedRecommendationsService` for "Because you watched" rails, a "live now from channels you watch" row, and richer category browsing.
- **Siri & universal search deep-linking** — "Play _channel_ on Twizz" and system-Search results that jump straight into playback, building on `DeepLinkRouter` and the existing Top Shelf.
- **Per-channel memory** — remember preferred quality, chat width, and audio-only state per channel.
- **Accessibility & readability** — VoiceOver labels for chat lines and cards, Dynamic Type chat scaling (via `ChatAppearance`), high-contrast / colorblind-friendly username and emote rendering, and a captions toggle where available.

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
