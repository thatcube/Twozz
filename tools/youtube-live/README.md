# YouTube live snapshot

Publishes two files to the `data` branch so the tvOS app can show a streamer's
**YouTube** presence next to their Twitch stream — one combined card per
streamer with a Twitch logo + viewers and a YouTube logo + viewers.

- `youtube-live.json` — which tracked YouTube channels are live right now and
  their concurrent viewers. Downloaded by `YouTubeLiveSnapshotService`.
- `twitch-youtube-aliases.json` — Twitch login → YouTube channel ID. Downloaded
  by `TwitchYouTubeAliasService`.

## Why a backend (not per-device API calls)

YouTube Data API quota is **per Google Cloud project** — shared by every user of
the app, not per device or per IP. So if each Apple TV called the API directly,
thousands of users would exhaust the daily quota instantly. Instead, this one job
checks a shared catalog once and publishes static JSON; the app only ever does a
parameter-free GET (no viewer data leaves the device — "Data Not Collected").

This is also **ToS-compliant**: it uses only the official API (no scraping).

## How it works (quota-cheap)

For each catalogued channel:
1. Resolve `@handle` → channel ID (`channels.list`, when an ID isn't given).
2. Read recent uploads from the deterministic uploads playlist
   (`UU` + channelId.slice(2)) via `playlistItems.list` — **1 unit/channel**.
3. Confirm live + read `concurrentViewers` with batched
   `videos.list(part=snippet,liveStreamingDetails)` — **1 unit / 50 videos**.

Cost ≈ a few hundred units per run for ~150 channels (10k/day default). Tune the
cron in `.github/workflows/youtube-live.yml` to your catalog size.

## Setup

1. Create a Google Cloud project, enable **YouTube Data API v3**, make an **API
   key** (no OAuth needed — this reads only public live data).
2. Add it as a repo secret named **`YOUTUBE_API_KEY`**.
3. Populate `channels.json` with dual-platform streamers (see the `_comment`).
4. The workflow runs on a schedule and on manual dispatch. Without the secret it
   still writes valid empty files, so the app degrades gracefully.

## Catalog format

```json
{
  "channels": [
    { "twitchLogin": "somestreamer", "youtubeHandle": "@SomeStreamer" },
    { "twitchLogin": "another", "youtubeChannelId": "UCxxxxxxxxxxxxxxxxxxxxxx" }
  ]
}
```

Verify each row maps to the **same person** on both platforms before adding it.
