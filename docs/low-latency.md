# Low-Latency Playback — what we know

Notes on the experimental **Low-Latency Mode** (the local playlist-rewriting
proxy) and the stream latency work around it. This file deliberately separates
**verified facts** from **open questions**. Only add something to "Established
facts" once it is actually confirmed (by Apple docs, the HLS spec, the code
itself, or a reproducible on-device observation). Hypotheses go under "Open
questions" until proven.

## TL;DR

- Twitch's own low-latency relies on a proprietary HLS tag AVPlayer ignores.
- We close most of that gap with an in-process proxy that promotes those
  segments. It is the real, stable latency win.
- AVPlayer on tvOS cannot match the Twitch app's sub-second player; ~2–6s
  behind the freshest segment is the realistic floor here.
- Sharpness, freezes, and "jumps" are governed by buffering and ABR behavior,
  not by playback speed. Those are still being tuned; use the Diagnostics
  overlay to gather real data.

## How playback is wired

1. `PlaybackService` resolves a channel to Twitch's HLS **master** playlist
   (via the GraphQL access token + Usher), and parses the per-rendition
   variants into `StreamQuality` values (each with a direct media-playlist URL).
2. `PlayerView` plays it with `AVPlayer`.
3. When **Low-Latency Mode** is on, `LowLatencyHLSProxy` sits in front of the
   playlists via an `AVAssetResourceLoaderDelegate` on a custom URL scheme
   (`twizz-ll://`).
4. For new installs (no prior saved preference), **Low-Latency Mode defaults to
   on**. Users can toggle it in in-player chat settings → Playback.

## Established facts (verified)

### The core latency problem
- **AVPlayer ignores `#EXT-X-TWITCH-PREFETCH:` tags.** AVPlayer's HLS parser
  implements RFC 8216 (+ Apple Low-Latency HLS) only; Twitch's prefetch tag is
  proprietary and is silently dropped. Those prefetch segments are exactly what
  makes Twitch "low latency" low latency, so a plain AVPlayer client trails the
  true edge by ~1–2 segments no matter how buffers are tuned.
- **tvOS has no `WKWebView`.** Frosty (iOS) reaches low latency by hosting
  Twitch's JS web player in a web view. That escape hatch does not exist on
  tvOS, so it is not an option for Twizz.

### The proxy
- The proxy rewrites the **master** playlist (variant + `URI="..."` lines onto
  the custom scheme) and the **media** playlist (promotes each
  `#EXT-X-TWITCH-PREFETCH:<url>` into a real `#EXTINF:<dur>,` + `<url>`
  segment). Segment URLs stay absolute `https`, so AVPlayer fetches them on its
  normal fast path.
- A **custom URL scheme** (not a localhost socket) is used on purpose: it avoids
  App Transport Security exceptions and the tvOS local-network privacy prompt,
  and keeps everything in-process.
- The HLS playlist UTI on this toolchain is **`public.m3u-playlist`** (there is
  no `public.m3u8-playlist`). It must be set on the content-information request
  or AVPlayer rejects the synthesized response. (Verified with a
  UniformTypeIdentifiers script.)
- **`AVURLAsset` retains its resource-loader delegate weakly.** The proxy must
  therefore be owned for the player's lifetime — it is held as `@State` on
  `PlayerView`.

### Quality / sharpness
- **`preferredPeakBitRate` is a ceiling, not a pin.** On the adaptive master
  playlist, ABR is free to serve a rendition *below* the ceiling. So selecting
  "1080p60" while staying on the master did **not** guarantee 1080p60 — ABR
  often sat lower, which looked soft.
- **An explicit quality pick now hard-pins that rendition's media playlist**
  (it stops using the adaptive master). ABR can no longer downshift it. "Auto"
  stays on the adaptive master.
- **A pinned rendition has no ABR fallback.** If its bitrate exceeds the
  connection, it rebuffers instead of stepping down — so "Auto" is the safe
  choice when a pin is unstable.
- **Playback speed never affects resolution.** Catch-up rate changes (≤1.05x)
  cannot blur the picture; blur is always an ABR/rendition issue.

### The latency readout
- There are two different "latency" numbers, and they mean different things:
  - **Encoder delay** = `Date()` − `PROGRAM-DATE-TIME` of the current frame.
    For a standard-latency Twitch stream this is ~18–20s. The Twitch phone app
    sits this far behind too. So this number reading "~20s" while you are
    visually in sync with your phone is expected — it is distance from the
    *encoder*, not from what any viewer can actually reach.
  - **Edge gap** = how far the playhead trails the freshest segment we can
    fetch (the seekable-window end). This is ~2–6s and is the number that
    tracks "am I near the freshest available content / in sync with my phone."
- The on-screen badge now **leads with the edge gap**, with encoder delay kept
  only as a fallback when the edge gap is unavailable.

### Recovery behavior
- The playback watchdog, on a detected freeze, calls `recoverFromPlaybackStall`,
  which does a **full reload** (`load(...)`) and restarts playback near the live
  edge. A reload therefore looks like a large forward "jump" on screen — this is
  one known, code-level source of jumps (counted separately as "Reloads" in the
  Diagnostics overlay).

## Realistic floor

Twitch's app renders sub-second LL-HLS *parts* in a custom player. We can only
hand AVPlayer whole ~2s prefetch segments plus AVPlayer's own buffering. So
matching the Twitch app's ~5–7s is unlikely on AVPlayer/tvOS. Being a few
seconds behind the freshest segment is the realistic target. This is the same
wall Frosty's native (non-web-view) path hits.

## Open questions (NOT yet confirmed — under investigation)

These are hypotheses. Do not treat them as fact until the Diagnostics overlay
(or another reproducible measurement) confirms them.

- **Remaining freezes.** Still observed occasionally. Exact trigger not yet
  pinned down. Candidate factors: forward buffer depth, a pinned rendition
  whose bitrate the connection can't sustain, or proxy refresh timing.
- **"Jumps."** Candidate causes, not yet separated:
  1. AVPlayer's own skip-to-live after the buffer dips (native behavior).
  2. The watchdog reload (confirmed mechanism; magnitude/frequency TBD).
  3. A pinned rendition stalling then re-snapping.
  4. The proxy's `#EXTINF` duration heuristic: prefetch segment durations are
     guessed from the previous real segment. If those guesses drift from real
     durations, the media timeline can accumulate error and AVPlayer may resync
     with a jump. Plausible, unproven.
- **Are streams actually delivered at the selected resolution?** The Diagnostics
  overlay now shows the real rendered size (`presentationSize`) and the
  indicated bitrate, so this can finally be checked per stream instead of
  guessed.

## Diagnostics overlay (how to gather data)

Player → open chat settings (`slider.horizontal.3`) → **Playback**. The same
section contains both **Low-Latency Mode** and **Diagnostics Overlay** toggles.
With Diagnostics on, the player shows a panel (while controls are visible)
reporting, all measured live from the current item:

- **Mode** — proxy on/off and whether quality is Auto/adaptive or pinned.
- **Render** — actual decoded video size (`presentationSize`) and playback rate.
  This is the ground truth for "is it really 1080p".
- **Bitrate** — indicated (the rendition ABR chose) vs observed (measured
  throughput), from the access log.
- **Dropped frames / AVStalls** — AVPlayer's own access-log counters.
- **Buffer ahead** — seconds buffered past the playhead.
- **Edge gap / Encoder** — the two latency numbers described above.
- **Stalls / Jumps / Reloads** — running counts for this viewing session.
- **Event log** — the most recent stalls/jumps/reloads with "Ns ago" timing.

Counters reset when a new channel session starts (initial load or following a
raid). They intentionally persist across a watchdog reload so the reload is
visible.

How jumps are detected: each second we compare actual playhead advance against
wall-clock × rate. Unexplained forward movement ≥ 2.0s is logged as a forward
jump; backward movement ≥ 1.0s as a back jump. Normal catch-up (≤1.05x) stays
well under these thresholds.

### When reporting a freeze or jump

Note the **event log line** (e.g. `jump +6.4s forward (3s ago)`), plus the
**Render size**, **indicated bitrate**, **buffer ahead**, and whether you were
on **Auto** or a **pinned** quality at the time. That combination is what lets
us tell these causes apart and move them from "Open questions" to "Established
facts."
