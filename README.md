<p align="center">
  <img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/twozz.svg" alt="Twozz logo" width="128" />
</p>

<h1 align="center">Twozz</h1>

<p align="center">
  Watch Twitch on your Apple TV, chat and all — a chat-first big-screen viewer with native 7TV, BTTV, and FFZ emotes.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple" alt="Platform: tvOS" /></a>
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

Twozz brings Twitch to the living room the way it should be: the stream and the
chat, side by side, on the big screen. It's built for the Apple TV remote and
the tvOS focus engine — not a stretched phone app — and it shows chat the way
your favorite streamers actually look, with the third-party emotes Twitch itself
doesn't render. It's free and open source.

## Features

### Watch

- **Chat beside the video.** Live streams play with the video on the left and a
  chat pane on the right, so you never have to choose between watching and
  reading along.
- **Low latency by default.** A low-latency mode closes most of the gap to the
  live edge, so you're not minutes behind the moment.
- **Rewind live.** Seek back within the live window (DVR) to catch what you
  missed without leaving the stream.
- **Pick your quality.** Choose Auto or an explicit resolution, ordered
  highest-to-lowest, and Twozz remembers your choice.
- **Audio-only mode.** Drop to audio with a reactive visualizer — handy for
  music streams, Just Chatting, or background listening.
- **Sleep timer.** Set a timer or "end of stream," with a gentle "still
  watching?" check, a starry sleeping screen, and one press to snap back to the
  live edge.
- **VODs and clips.** Watch past broadcasts and top clips from channel pages;
  VODs include synced chat replay and variable speed (0.5×–2×).
- **Multi-view.** Watch several live channels at once, picked from your follows
  and recommendations.
- **Live captions (beta).** Optional on-device captions for streams, with size,
  position, and styling controls.

### Chat

- **Third-party emotes, built in.** 7TV, BTTV, and FFZ emotes (global and
  channel, including animated ones) render right alongside Twitch's native, sub,
  and channel emotes.
- **Badges and bits.** Global and channel badges plus cheermotes are shown just
  like they are on the web.
- **Read anonymously, or chat when signed in.** Chat connects anonymously by
  default and auto-reconnects; sign in to send messages.
- **Make chat yours.** Adjust text and emote size, font (including
  OpenDyslexic), spacing, width, and layout — side, overlay, or glass.
- **Live moments surfaced.** Polls, predictions, hype trains, creator goals, and
  incoming/outgoing raids appear as calm, display-only overlays.
- **Simulcast chat merge (experimental).** When a streamer you're watching is
  also live on YouTube or Kick, their chats can be merged into a single pane.

### Discover

- **Home built around your follows.** See the channels you follow that are live
  now, plus recommendations.
- **Recommendations you control.** Optional personalized picks built from
  on-device watch history and your followed categories — or anonymous trending
  when you're signed out or have it turned off.
- **Browse and search.** Explore top categories and their live streams, and
  search channels and categories with live results.
- **Channel pages.** Top clips, past broadcasts, and similar channels for every
  channel.
- **Top Shelf.** Your live follows and recommendations surface on the tvOS home
  screen above the app icon.
- **YouTube, too.** Connect a YouTube account to see your subscribed streamers
  who are live and watch YouTube-only streams; streamers live on both platforms
  show up as one combined card.

### Make it comfortable

- **Themes.** System, Dark, OLED, and Light.
- **Night Shift.** An optional warm screen wash that eases in after sunset on a
  solar or manual schedule.
- **Tune the grid.** Adjustable stream-card sizes and a stream-language filter.

## Getting started

Twozz is an early, non-commercial project and isn't on the App Store. To run it
you'll build it yourself from source with Xcode and your own Twitch developer
`client_id`. See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full setup.

You'll want:

- An Apple TV running **tvOS 18 or newer** (live playback and Top Shelf need
  real hardware).
- A Twitch account, if you want to sign in — browsing and anonymous chat work
  without one.

## Reporting bugs & requesting features

Found a bug or have an idea? Please open a
[GitHub issue](https://github.com/thatcube/Twozz/issues). Including your Apple TV
model, tvOS version, and the stream where something went wrong helps a lot. See
**[CONTRIBUTING.md](CONTRIBUTING.md)** for details.

## Contributing & development

Build instructions, the Twitch auth setup, how playback is resolved, versioning,
and release steps all live in **[CONTRIBUTING.md](CONTRIBUTING.md)**. Notes on
the low-latency playback work are in
[`docs/low-latency.md`](docs/low-latency.md).

### Playback diagnostics

Twozz keeps a bounded, local JSONL playback log in its app cache so lag reports
can be examined after the fact. Logging samples playback state about every two
seconds and records noteworthy state changes, stalls, access/error-log updates,
seeks, and recovery actions. It is diagnostic observation only; enabling it does
not change playback tuning.

Pull the retained logs from the paired Apple TV and summarize the current or
most recent session:

```bash
python3 tools/playback-diagnostics.py pull --device <device-id>
```

Select a paired Apple TV with `--device` or the `TWOZZ_DEVICE_ID` environment
variable. The default bundle is `com.thatcube.Twozz`. Every pull goes into a new
UTC-stamped directory under the gitignored `playback-diagnostics/` directory:

```bash
python3 tools/playback-diagnostics.py pull \
  --device <device-id> --bundle com.thatcube.Twozz
python3 tools/playback-diagnostics.py pull --device <device-id> --session <session-uuid> --json
```

Previously pulled data can be analyzed without Xcode or a connected device:

```bash
python3 tools/playback-diagnostics.py analyze playback-diagnostics/<timestamp>
python3 tools/playback-diagnostics.py analyze <file.jsonl> --session <session-uuid>
python3 tools/playback-diagnostics.py analyze playback-diagnostics/<timestamp> --all --json
```

By default, analysis uses `latest-session.json`, or the session containing the
newest record when no manifest is available. `--all` reports retained sessions
separately; sessions are never silently combined. A copied, incomplete final
JSON line is warned about and ignored, while completed corrupt lines and unknown
schema versions fail analysis. Sequence gaps, dropped telemetry, reclaimed
rotation parts, bounded native access/error-log backlog skips, and sessions that
are still active are marked as partial evidence.

The cache retains at most eight 4 MiB files across all sessions (about 32 MiB)
and tvOS may reclaim it. It does not contain OAuth credentials, full URLs,
request headers, server IP addresses, AVPlayer session IDs, SDK localized error
prose, or error comments. Failures retain only structured evidence such as
error domain/code or AVPlayer error-log status code. Public channel names and
viewing timestamps do appear. The tool reads locally and never uploads logs.

Interpret summaries cautiously. Proxy timings cover playlist/master requests,
not media segment transfers; AVPlayer access-log throughput is a coarse
cumulative estimate, not an instantaneous network test. Low buffer, bitrate
differences, dropped frames, healthy-buffer waits, decode freezes, controller
interventions, and thermal state can support hypotheses but do not prove a root
cause. Rates cover the retained record window; initial cumulative values in a
partial tail are treated as baselines, so its counter deltas are lower bounds.
`recovery_completed` describes the recovery task returning
(`load_returned`, `load_failed`, or `offline`); later clock/frame progress is the
health evidence. `first_clock_progress` confirms clock movement.
`first_video_output_frame` is currently native-Twitch-only, may be up to one
watchdog interval late, and records an observed pixel buffer rather than proof
that a picture was rendered on screen. A seek callback arriving after the
15-second `seek_deadline_exceeded` event confirms only that the target callback
landed, not that a picture rendered. The proxy's last failure status, error code,
and monotonic uptime remain in samples after a later success so the failure is
not mistaken for the latest request.

## Donate

Twozz is free and open source, and it always will be. There's no paywall, no
ads, and no obligation to give anything.

If the app has been useful to you and you'd like to chip in toward its upkeep —
things like the Apple Developer Program fee and time spent maintaining it —
donations are welcome and genuinely appreciated. Anything is plenty, and not
donating is completely fine too.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time
or recurring, whatever suits you.

## Credits

Twozz is an unofficial, non-commercial Twitch client. It is **not affiliated
with, endorsed by, or sponsored by** Twitch Interactive, Inc. or Amazon. Twitch
is a trademark of its owner.

Third-party emote support is provided through the public [7TV](https://7tv.app),
[BetterTTV](https://betterttv.com), and [FrankerFaceZ](https://www.frankerfacez.com)
services, and belongs to them.

## License

[MIT](LICENSE) © 2026 thatcube

<!-- app-family:start -->
<!-- Generated by https://github.com/thatcube/brando — edit apps.json there, not this block. -->

---

<p align="center"><b>More open source</b></p>

<p align="center">
  <a href="https://github.com/thatcube/hozz" title="Hozz — Apple Health, exported to storage you own"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/hozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/hozz-light.svg" height="40" alt="Hozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Mozz" title="Mozz — Your music, wherever it lives"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/mozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/mozz-light.svg" height="40" alt="Mozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Plozz" title="Plozz — Movies &amp; TV on Apple TV, iPhone &amp; iPad"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/plozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/plozz-light.svg" height="40" alt="Plozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Twozz" title="Twozz — Twitch on Apple TV, with real emotes"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/twozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/twozz-light.svg" height="40" alt="Twozz" /></picture></a>
</p>

<p align="center">
  <a href="https://brando.page">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-white.svg" />
      <img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-black.svg" height="22" alt="Brandon Moore" />
    </picture>
  </a>
</p>
<!-- app-family:end -->
