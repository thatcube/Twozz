# Low-Latency Playback — what we know

Notes on the live-playback latency work: the local playlist-rewriting **proxy**
(prefetch promotion) and the two **Auto profiles** that trade latency against
quality on top of it. This file deliberately separates **verified facts** from
**open questions**. Only add something to "Established facts" once it is actually
confirmed (by Apple docs, the HLS spec, the code itself, or a reproducible
on-device observation). Hypotheses go under "Open questions" until proven.

## TL;DR

- Twitch's own low-latency relies on a proprietary HLS tag AVPlayer ignores.
- We close most of that gap with an in-process proxy that promotes those
  segments. It is always on for live and is the real, stable latency win.
- The quality picker exposes two Auto profiles — **Auto · Low Latency** and
  **Auto · High Quality** — that differ only in buffer depth and gentle
  catch-up (see `LivePlaybackPolicy`). An explicit rendition pick is a third,
  fixed-quality case.
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
3. `LowLatencyHLSProxy` sits in front of the playlists via an
   `AVAssetResourceLoaderDelegate` on a custom URL scheme (`twizz-ll://`). It is
   attached whenever prefetch promotion **or** Stream Rewind is on.
4. Prefetch promotion is **on by default** and powers both Auto profiles. It is
   no longer a user-facing toggle; an advanced **Prefetch Proxy** kill-switch
   lives under the Diagnostics overlay for troubleshooting only.

## The two Auto profiles (`LivePlaybackPolicy`)

Both Auto rows stay on the adaptive master (ABR active) and keep prefetch
promotion on; they differ only in how they trade quality for latency. The
concrete tuning lives in `Twizz/Models/LivePlaybackProfile.swift`:

- **Auto · Low Latency** (default) — shallow forward buffer (~3s) to sit near
  the edge (and resume fast after a dip rather than waiting to refill a deep
  buffer), plus a **bidirectional adaptive playback-rate controller** (see
  `desiredLivePlaybackRate`) that runs on its own **sub-second loop**
  (`rateControlIntervalSeconds`, ~4 Hz) — far faster than the 1 Hz latency
  monitor — so it can react to a draining buffer before it empties. As the
  forward buffer drains under ~1.5s it eases the rate down toward **0.90×**
  (anti-stall: playing slightly slow lets the buffer refill so a transient dip is
  absorbed instead of a hard stall); once the buffer clears ~2.0s *and* the edge
  gap exceeds the **~2s target** — deliberately *tighter* than the 3.5s seek
  landing point so catch-up always has slack to chase — it nudges the rate up
  **proportionally** (the further behind the edge, the faster it chases, capped
  at **1.12×**) and eases back toward 1.0× as it closes on the target. The two
  arms settle at an equilibrium of ~2s from the edge with a safe buffer. ABR is
  also free to drop resolution to avoid a stall; degraded quality is acceptable,
  stutter is not.
- **Auto · High Quality** — deeper forward buffer (~8s) so ABR has the runway to
  settle on and hold the best stable resolution, accepting a little more
  latency. No rate games (always 1.0×); it never sacrifices quality on its own.
- **Pinned rendition** — a stable buffer (~8s) with no rate games; ABR is off, so
  it holds exactly that rendition (and rebuffers rather than downshifting).
- **Stability fallback** (automatic, all profiles) — a runtime override, not a
  user-selectable row. A **stream-stability watchdog** counts destabilizing
  events — stalls plus involuntary backward playhead jumps (an AVPlayer rewind we
  never request) — in a rolling window (`unstableEventWindowSeconds`). Reaching
  the threshold flags the stream *chronically unstable* — almost always a
  struggling **broadcaster** encoder (lots of stalls/rewinds despite ample
  observed bandwidth), not the viewer's connection. To stabilize a bad stream as
  soon as you arrive, the trip is **aggressive and front-loaded**: during the
  first `unstableStartupGraceSeconds` of playback a **single** event trips it;
  after that any **two** events in the window do (so "2 stalls", "2 jumps", or "1
  stall + 1 jump" all qualify). Stalls feed the watchdog from both the
  `AVPlayerItemPlaybackStalled` notification and the frozen-playhead heuristic;
  backward jumps feed it from the playback-health sampler. All of this runs with
  the diagnostics overlay **off**.

  Once flagged, the normal low-latency strategy is actively harmful: the
  **low-latency prefetch proxy** keeps promoting `#EXT-X-TWITCH-PREFETCH` segments
  and shoving the playhead at a live edge the source can't sustain, so it stalls,
  rewinds, and loops. The fallback inverts the trade-off:
  - **Drops the prefetch proxy.** `makeItem` suppresses promotion while unstable
    (`promotePrefetch = lowLatencyProxyEnabled && !isStreamUnstable`) and, when
    Stream Rewind isn't separately holding the proxy on for DVR, detaches it
    entirely so AVPlayer plays the plain Twitch playlist — exactly what a manual
    "LL proxy off" does. Entering stability triggers a lightweight reload so the
    pipeline rebuilds without the proxy.
  - **Deep forward buffer (~12s), no catch-up, edge-resync suppressed.** The
    anti-stall slow-down stays on as the last line of defence.
  This is the single biggest win for a bad stream in practice: with the proxy off
  the deep buffer actually *fills* and playback goes rock-solid (riding ~15-20s
  behind) instead of stuttering near the edge. The flag **latches for the whole
  channel session** — a stream that has proven it can't hold the edge keeps the
  safe strategy until the viewer changes channel (there is no auto-recovery; we
  never flap the proxy back on and risk re-destabilizing it). Surfaced in the
  Diagnostics overlay as "LL proxy auto-off (unstable)" + "⚠︎ STABILITY MODE".
  Resets on every new channel session (`resetDiagnostics`).

The adaptive-rate technique mirrors low-latency DASH/HLS players (e.g. dash.js
`liveCatchup`): keep latency near a target by trimming a few percent off the
playback rate either side of 1.0 rather than hard seeks/pauses. Time-domain
pitch correction (`audioTimePitchAlgorithm = .timeDomain`) keeps the audio
natural through those changes.

Stutter-resistance in both Auto modes comes from ABR headroom plus the
anti-stall slow-down, not from a hard pin: ABR lets the stream step down instead
of stalling, and the slow-down rides out short buffer dips.

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
- **Playback speed never affects resolution.** Adaptive-rate changes (~0.90×–
  1.12×) cannot blur the picture; blur is always an ABR/rendition issue.

### The latency readout
- There are two different "latency" numbers, and they mean different things:
  - **Wall-clock behind-live** = `Date()` − `PROGRAM-DATE-TIME` of the current
    frame. This is how far behind the real broadcast the on-screen picture is —
    the metric a viewer actually experiences (and the one used for chat sync).
    For Twitch low-latency this is typically ~5–15s.
  - **Edge gap** = how far the playhead trails the freshest segment we can fetch
    (the seekable-window end). This is ~2–6s; it collapses to ~0 at the edge and
    is *not* a reliable "behind live" figure on its own.
- The on-screen badge **leads with wall-clock behind-live**, with the edge gap
  kept only as a fallback when wall-clock (`currentDate()`) is unavailable. The
  badge is **hidden by default** (`showLatencyBadge`).
- `PROGRAM-DATE-TIME` is approximate and occasionally stale (especially right
  after a stall/reload), so the raw wall-clock value can momentarily spike; the
  smoother applies outlier rejection, but transient jumps in the diagnostic
  readout do not reflect a real change in playback position.

### Recovery behavior
- **Involuntary live-edge drift is detected independently of the frozen-playhead
  heuristic.** With a large DVR window and `automaticallyWaitsToMinimizeStalling`
  on, AVPlayer can rewind the playhead far back inside the seekable window to
  refill its buffer and then play *forward* from there — so the old "playhead
  isn't advancing" stall check never fired, and the player could sit 120s+ behind
  live indefinitely. `samplePlaybackHealth` now also watches the edge gap while
  pinned to live and, past a threshold (~15s — far above the normal sub-second
  edge gap and ordinary rebuffer jitter, but low enough to rescue the viewer long
  before they're a minute behind), runs a **resync ladder**: a throttled
  lightweight seek back toward the edge (instant recovery the gentle rate
  catch-up can't achieve for a large hole), escalating to a full reload only after
  repeated failures.
- The playback watchdog, on a detected hard freeze, calls
  `recoverFromPlaybackStall`, which does a **full reload** (`load(...)`) and
  restarts playback near the live edge. A reload therefore looks like a large
  forward "jump" on screen — this is one known, code-level source of jumps
  (counted separately as "Reloads" in the Diagnostics overlay).
- **Snap to true live on return.** After scrubbing through the DVR window and
  returning to the live edge, AVPlayer's seekable window can itself trail the
  true broadcast tail (its cached media playlist is stale), so a same-window seek
  leaves the viewer ~10s+ behind. On scrub commit, when pinned to live and that
  staleness (wall-clock behind-live minus the in-window edge gap) exceeds a
  threshold, `snapToTrueLiveIfStale` forces a fresh load that lands at the real
  edge. The proxy only clears its DVR buffers when `retainHistory` actually
  changes, so the rewind window survives the reload.
- **Soft-stall deadlock recovery (the "Playing/waiting · evaluatingBufferingRate"
  freeze with a healthy buffer).** AVPlayer can park in
  `.waitingToPlayAtSpecifiedRate` (reason `.evaluatingBufferingRate` or
  `.toMinimizeStalls`) *even while it holds a perfectly healthy forward buffer*
  (`isPlaybackLikelyToKeepUp == true`, buffer not empty). It decided the network
  might not sustain the rate and then never re-evaluates on its own — because our
  adaptive-rate controller (`applyLiveLatencyCorrection`) only issues a play
  command when the **target rate changes**, and here it stays 1.0×. The playhead
  creeps (not a hard freeze, so "Stalls" stays 0 and the buffer-empty hard-stall /
  offline paths never fire) while behind-live grows without bound — the classic
  "9k viewers, ~24s → ~52s behind live, buffer ahead stuck at 4.3s" report.
  `samplePlaybackHealth` now detects "waiting despite a healthy buffer"
  (`isSoftStallSignal`, mutually exclusive with the buffer-empty `isHardStallSignal`
  by construction) and, after a short grace (`softStallNudgeSeconds`, 3s), kicks it
  with `player.playImmediately(atRate:)` — which explicitly *bypasses* AVPlayer's
  buffering-rate evaluation and plays the buffered media at once. If repeated
  nudges can't break it within `softStallReloadSeconds` (12s), it escalates to a
  reload (which also re-lands near live, recovering the latency that grew while
  stuck). On-device this surfaces a "soft-stall nudge (buf …s)" line in the
  Diagnostics event log. This also helps slow stream starts.

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
  4. The proxy's `#EXTINF` duration heuristic: prefetch tags carry no duration,
     so the proxy synthesizes one. It now uses the **average** of the real
     segment durations (matching Streamlink) rather than just the previous
     segment, which is steadier near boundaries. Residual timeline drift from
     this estimate is still possible but less likely; unproven.
- **Are streams actually delivered at the selected resolution?** The Diagnostics
  overlay now shows the real rendered size (`presentationSize`) and the
  indicated bitrate, so this can finally be checked per stream instead of
  guessed.

## Diagnostics overlay (how to gather data)

Player → open chat settings (`slider.horizontal.3`) → **Playback**. Turn on the
**Diagnostics Overlay** toggle; doing so also reveals the advanced **Prefetch
Proxy** kill-switch and the simulate-event buttons. With Diagnostics on, the
player shows a panel (while controls are visible) reporting, all measured live
from the current item:

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
jump; backward movement ≥ 1.0s as a back jump. Normal catch-up (≤1.12x) stays
well under these thresholds.

### When reporting a freeze or jump

Note the **event log line** (e.g. `jump +6.4s forward (3s ago)`), plus the
**Render size**, **indicated bitrate**, **buffer ahead**, and whether you were
on **Auto** or a **pinned** quality at the time. That combination is what lets
us tell these causes apart and move them from "Open questions" to "Established
facts."
