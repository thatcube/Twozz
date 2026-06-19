import AVFoundation
import Foundation

/// Experimental low-latency shim for Twitch HLS playback.
///
/// AVPlayer's HLS parser only understands RFC 8216 (+ Apple LL-HLS) tags, so it
/// silently ignores Twitch's proprietary `#EXT-X-TWITCH-PREFETCH:` lines — the
/// very segments that make Twitch "low latency" mode low latency. As a result a
/// plain AVPlayer client sits ~1-2 segments behind the true live edge no matter
/// how aggressively buffering is tuned.
///
/// This proxy fixes that the same way the open-source Streamlink plugin does:
/// it rewrites the media playlist on the fly, promoting each advertised
/// `#EXT-X-TWITCH-PREFETCH` URL into a normal `#EXTINF` segment so AVPlayer will
/// actually fetch it. Twitch only advertises prefetch URLs that are ready (or
/// near-ready) on its CDN, and each prefetch URL becomes the regular segment URL
/// on the next playlist refresh, so segment/media-sequence identity stays stable
/// across reloads (which is what keeps AVPlayer from stalling).
///
/// Implementation notes:
/// - Uses an `AVAssetResourceLoaderDelegate` with a custom URL scheme rather than
///   a localhost socket server. On tvOS this avoids App Transport Security
///   exceptions and the local-network privacy prompt entirely, and keeps
///   everything in-process.
/// - Only playlist requests (master + media) flow through the delegate. Media
///   segments keep their absolute `https` URLs, so AVPlayer fetches them
///   directly using the asset's `AVURLAssetHTTPHeaderFieldsKey` identity.
/// - This is intentionally ad-respecting: prefetch ad segments are promoted just
///   like any other segment. We do not strip or skip ad content.
final class LowLatencyHLSProxy: NSObject, AVAssetResourceLoaderDelegate {
    /// Custom scheme AVPlayer cannot handle natively, which forces every playlist
    /// request onto this delegate.
    static let scheme = "twizz-ll"

    /// `@AppStorage`/`UserDefaults` key for the experimental toggle.
    static let settingsKey = "lowLatencyProxyEnabled"

    /// `@AppStorage`/`UserDefaults` key for the Stream Rewind (DVR) toggle.
    static let rewindSettingsKey = "streamRewindEnabled"

    /// `@AppStorage`/`UserDefaults` key for the **experimental** Apple LL-HLS
    /// synthesis mode (off by default). See `rewriteMediaPlaylistAsLLHLS`.
    static let llhlsSettingsKey = "llhlsExperimentEnabled"

    private static let prefetchTag = "#EXT-X-TWITCH-PREFETCH:"
    private static let streamInfTag = "#EXT-X-STREAM-INF"
    private static let extinfTag = "#EXTINF:"
    private static let targetDurationTag = "#EXT-X-TARGETDURATION:"
    private static let mediaSequenceTag = "#EXT-X-MEDIA-SEQUENCE:"
    private static let discontinuitySequenceTag = "#EXT-X-DISCONTINUITY-SEQUENCE:"
    private static let discontinuityTag = "#EXT-X-DISCONTINUITY"
    /// Tags whose appearance marks the end of the playlist header and the start
    /// of the segment list. `#EXT-X-DISCONTINUITY-SEQUENCE` is intentionally NOT
    /// here (it is a header tag even though it shares a prefix with the
    /// per-segment `#EXT-X-DISCONTINUITY`).
    private static let segmentStartTags = [
        extinfTag,
        "#EXT-X-PROGRAM-DATE-TIME",
        discontinuityTag,
        "#EXT-X-BYTERANGE",
        "#EXT-X-KEY",
        "#EXT-X-MAP",
        "#EXT-X-DATERANGE",
        prefetchTag,
    ]

    /// UTI for an HLS playlist on Apple platforms (both `.m3u8` and the Apple
    /// mpegurl MIME type resolve to this). Required on the content-information
    /// request or AVPlayer rejects the synthesized response.
    private static let playlistContentType = "public.m3u-playlist"

    private let upstreamHeaders: [String: String]
    private let delegateQueue = DispatchQueue(label: "com.twizz.lowlatencyhls.proxy")

    /// No-cache session: live media playlists must never be served stale.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    // MARK: - DVR (Stream Rewind) configuration & state

    /// When true, promote Twitch `#EXT-X-TWITCH-PREFETCH` segments at the live
    /// tail (the low-latency win). Independent of `retainHistory`.
    private var promotePrefetch = true
    /// When true, retain every real segment seen so AVPlayer's seekable window
    /// grows to match watch time — the Stream Rewind DVR.
    private var retainHistory = true
    /// Cap on retained history, in seconds. Twitch's segment URLs eventually age
    /// off its CDN, so retaining past this just risks 404s on a deep rewind.
    private var dvrWindowSeconds: Double = 1800
    /// Per-media-playlist retained-segment buffers, keyed by the real (https)
    /// media-playlist URL. Mutated only on `delegateQueue`.
    private var dvrBuffers: [String: DVRBuffer] = [:]

    // MARK: - Apple LL-HLS experiment (off by default)

    /// When true, synthesize an Apple Low-Latency-HLS media playlist
    /// (`EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD`, `EXT-X-PART-INF`, `EXT-X-PART`,
    /// `EXT-X-PRELOAD-HINT`) instead of the prefetch-promotion / DVR rewrite, and
    /// honor AVPlayer's blocking playlist reloads. Mutually exclusive with
    /// `promotePrefetch` / `retainHistory` (the caller gates this). Experimental.
    private var synthesizeLLHLS = false

    /// How many of the most recent real segments get `#EXT-X-PART` lines. AVPlayer
    /// only needs parts near the live edge; emitting them for the whole window
    /// would bloat the playlist for no benefit.
    private let llhlsPartSegmentWindow = 3
    /// Max wall-time to hold a blocking playlist reload before returning whatever
    /// we have, so a request can never hang AVPlayer (must stay under the
    /// URLSession timeouts above).
    private let llhlsBlockingTimeout: TimeInterval = 5
    /// How often to re-poll Twitch upstream while holding a blocking reload.
    private let llhlsPollInterval: TimeInterval = 0.25
    /// Last successfully synthesized LL-HLS manifest per upstream URL. Lets a
    /// blocking reload that hits its deadline return real content instead of
    /// hanging or erroring. Mutated only on `delegateQueue`; cleared on channel
    /// switch (`resetDVR`).
    private var lastLLHLSManifest: [String: Data] = [:]

    /// One parsed HLS segment (a real `#EXTINF` segment or a promoted prefetch),
    /// kept as its full text block so per-segment tags (PROGRAM-DATE-TIME,
    /// DISCONTINUITY, …) survive into the rewritten playlist verbatim.
    private struct MediaSegment {
        let url: String
        let lines: [String]
        let duration: Double
        let isDiscontinuity: Bool
    }

    private struct ParsedMediaPlaylist {
        var header: [String]
        var mediaSequence: Int
        var discontinuitySequence: Int
        var segments: [MediaSegment]
        var prefetch: [MediaSegment]
    }

    /// Growing, deduplicated history of real segments for one media playlist.
    private final class DVRBuffer {
        var segments: [MediaSegment] = []
        var seenURLs: Set<String> = []
        var firstSequence = 0
        var discontinuitySequence = 0
        var initialized = false
    }

    init(headers: [String: String]) {
        self.upstreamHeaders = headers
        super.init()
    }

    /// Serial queue AVFoundation should deliver resource-loader callbacks on.
    var callbackQueue: DispatchQueue { delegateQueue }

    /// Updates the proxy's behavior. Dispatched onto the delegate queue so the
    /// flags are always read consistently with playlist rewriting. Switching
    /// `retainHistory` clears any accumulated DVR history.
    func configure(
        promotePrefetch: Bool,
        retainHistory: Bool,
        windowSeconds: Double,
        synthesizeLLHLS: Bool = false
    ) {
        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.promotePrefetch = promotePrefetch
            if self.retainHistory != retainHistory {
                self.dvrBuffers.removeAll()
            }
            self.retainHistory = retainHistory
            self.dvrWindowSeconds = windowSeconds
            self.synthesizeLLHLS = synthesizeLLHLS
        }
    }

    /// Drops all retained DVR history (e.g. on a channel switch / raid) so the
    /// rewind window starts fresh for the new stream.
    func resetDVR() {
        delegateQueue.async { [weak self] in
            self?.dvrBuffers.removeAll()
            self?.lastLLHLSManifest.removeAll()
        }
    }

    /// Rewrites an `https` master-playlist URL onto the custom scheme so AVPlayer
    /// routes it (and, after rewriting, its child media playlists) through this
    /// delegate. Returns the original URL unchanged if the scheme swap fails.
    func proxyURL(for masterURL: URL) -> URL {
        guard var comps = URLComponents(url: masterURL, resolvingAgainstBaseURL: false) else {
            return masterURL
        }
        comps.scheme = Self.scheme
        return comps.url ?? masterURL
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme == Self.scheme,
              let realURL = httpsURL(from: requestURL) else {
            return false
        }

        // Twitch upstream never understands Apple's blocking-reload query params, so
        // strip them before fetching. In LL-HLS mode a request that carries them is
        // a blocking playlist reload: hold it open and poll upstream until the asked
        // media-sequence/part is available (the crux of the experiment).
        let upstream = upstreamURLStrippingBlockingParams(realURL)
        let key = ObjectIdentifier(loadingRequest)

        if synthesizeLLHLS, let target = blockingReloadTarget(from: requestURL) {
            serveBlockingReload(loadingRequest, upstream: upstream, target: target, key: key)
            return true
        }

        var req = URLRequest(url: upstream)
        for (key, value) in upstreamHeaders { req.setValue(value, forHTTPHeaderField: key) }

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.delegateQueue.async {
                self.tasks[key] = nil
                if loadingRequest.isFinished || loadingRequest.isCancelled { return }

                guard let data, error == nil else {
                    loadingRequest.finishLoading(with: error)
                    return
                }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200...299).contains(status) else {
                    loadingRequest.finishLoading(with: PlaybackError.http(status))
                    return
                }

                let text = String(decoding: data, as: UTF8.self)
                let rewritten = self.rewrite(playlist: text, sourceURL: upstream)
                self.fulfill(loadingRequest, with: rewritten)
            }
        }
        delegateQueue.async { [weak self] in
            self?.tasks[key] = task
        }
        task.resume()
        return true
    }

    // MARK: - LL-HLS blocking playlist reload

    /// Serves a blocking playlist reload with a hard safety guarantee: an absolute
    /// `llhlsBlockingTimeout` watchdog resolves the request even if the network
    /// stalls, returning the last good manifest instead of ever hanging AVPlayer.
    /// A hung resource loader freezes the player, so this is the critical failsafe.
    private func serveBlockingReload(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        upstream: URL,
        target: (msn: Int, part: Int),
        key: ObjectIdentifier
    ) {
        let deadline = Date().addingTimeInterval(llhlsBlockingTimeout)
        delegateQueue.asyncAfter(deadline: .now() + llhlsBlockingTimeout) { [weak self] in
            guard let self else { return }
            if loadingRequest.isFinished || loadingRequest.isCancelled { return }
            // Network is still in flight at the deadline: cancel it and resolve now.
            self.tasks[key]?.cancel()
            self.tasks[key] = nil
            if let cached = self.lastLLHLSManifest[upstream.absoluteString] {
                self.fulfill(loadingRequest, with: cached)
            } else {
                // Nothing cached yet — finish with a retriable error rather than
                // empty data so AVPlayer simply reissues the reload.
                loadingRequest.finishLoading(with: PlaybackError.badResponse)
            }
        }
        pollBlockingReload(loadingRequest, upstream: upstream, target: target, key: key, deadline: deadline)
    }

    /// Holds a blocking playlist reload open, re-polling Twitch upstream every
    /// `llhlsPollInterval` until the synthesized LL-HLS playlist advertises the
    /// requested media-sequence (or `deadline` passes), then returns it. This is
    /// what lets AVPlayer fetch the bleeding edge the instant Twitch publishes it
    /// instead of waiting out a normal poll interval. Runs on `delegateQueue`.
    private func pollBlockingReload(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        upstream: URL,
        target: (msn: Int, part: Int),
        key: ObjectIdentifier,
        deadline: Date
    ) {
        if loadingRequest.isFinished || loadingRequest.isCancelled {
            tasks[key] = nil
            return
        }

        var req = URLRequest(url: upstream)
        for (k, value) in upstreamHeaders { req.setValue(value, forHTTPHeaderField: k) }

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.delegateQueue.async {
                self.tasks[key] = nil
                if loadingRequest.isFinished || loadingRequest.isCancelled { return }

                guard let data, error == nil else {
                    loadingRequest.finishLoading(with: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200...299).contains(status) else {
                    loadingRequest.finishLoading(with: PlaybackError.http(status))
                    return
                }

                let text = String(decoding: data, as: UTF8.self)
                let synthesis = self.llhlsSynthesis(from: text)
                self.lastLLHLSManifest[upstream.absoluteString] = synthesis.data
                if synthesis.availableMSN >= target.msn || Date() >= deadline {
                    self.fulfill(loadingRequest, with: synthesis.data)
                } else {
                    self.delegateQueue.asyncAfter(deadline: .now() + self.llhlsPollInterval) { [weak self] in
                        self?.pollBlockingReload(
                            loadingRequest, upstream: upstream, target: target, key: key, deadline: deadline)
                    }
                }
            }
        }
        tasks[key] = task
        task.resume()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        delegateQueue.async { [weak self] in
            self?.tasks[key]?.cancel()
            self?.tasks[key] = nil
        }
    }

    // MARK: - Playlist rewriting

    /// Dispatches to the master- or media-playlist rewriter based on content.
    private func rewrite(playlist text: String, sourceURL: URL) -> Data {
        if text.contains(Self.streamInfTag) {
            return rewriteMasterPlaylist(text)
        }
        if synthesizeLLHLS {
            let data = llhlsSynthesis(from: text).data
            lastLLHLSManifest[sourceURL.absoluteString] = data
            return data
        }
        return rewriteMediaPlaylist(text, sourceURL: sourceURL)
    }

    /// Reroutes variant + alternate-media (`URI="..."`) playlist URLs onto the
    /// custom scheme so child media playlists are also proxied. Segment lines do
    /// not appear in a master playlist, so nothing else changes.
    private func rewriteMasterPlaylist(_ text: String) -> Data {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(raw)
            } else if trimmed.hasPrefix("#") {
                out.append(rewriteURIAttribute(in: raw))
            } else {
                out.append(disguiseScheme(of: trimmed))
            }
        }
        return Data(out.joined(separator: "\n").utf8)
    }

    /// Rewrites a Twitch live media playlist.
    ///
    /// Two independent behaviors, combined:
    /// - **Prefetch promotion** (`promotePrefetch`): each
    ///   `#EXT-X-TWITCH-PREFETCH:<url>` is turned into a real `#EXTINF` segment at
    ///   the live tail so AVPlayer fetches it (the low-latency win). Duration is
    ///   the average of the real `#EXTINF` segments (falling back to
    ///   `#EXT-X-TARGETDURATION`, then 2s) — Streamlink's heuristic.
    /// - **DVR retention** (`retainHistory`): every real segment ever seen for
    ///   this media playlist is retained (deduplicated by URL) and re-emitted, so
    ///   the playlist — and therefore AVPlayer's seekable window — grows to match
    ///   watch time. This is the Stream Rewind window. History is capped at
    ///   `dvrWindowSeconds`; the `#EXT-X-MEDIA-SEQUENCE` /
    ///   `#EXT-X-DISCONTINUITY-SEQUENCE` headers are rewritten to stay consistent
    ///   as the window slides.
    private func rewriteMediaPlaylist(_ text: String, sourceURL: URL) -> Data {
        let parsed = parseMediaPlaylist(text)

        guard retainHistory else {
            var out = parsed.header
            for seg in parsed.segments { out.append(contentsOf: seg.lines) }
            if promotePrefetch {
                for seg in parsed.prefetch { out.append(contentsOf: seg.lines) }
            }
            return Data(out.joined(separator: "\n").utf8)
        }

        let key = sourceURL.absoluteString
        let buf = dvrBuffers[key] ?? DVRBuffer()
        if !buf.initialized {
            buf.firstSequence = parsed.mediaSequence
            buf.discontinuitySequence = parsed.discontinuitySequence
            buf.initialized = true
        }

        for seg in parsed.segments where !buf.seenURLs.contains(seg.url) {
            buf.seenURLs.insert(seg.url)
            buf.segments.append(seg)
        }

        // Slide the retained window: drop oldest segments past the cap, advancing
        // the media/discontinuity sequence counters so AVPlayer's accounting stays
        // monotonic and correct.
        var total = buf.segments.reduce(0.0) { $0 + $1.duration }
        while total > dvrWindowSeconds, buf.segments.count > 1 {
            let dropped = buf.segments.removeFirst()
            buf.seenURLs.remove(dropped.url)
            total -= dropped.duration
            buf.firstSequence += 1
            if dropped.isDiscontinuity { buf.discontinuitySequence += 1 }
        }
        dvrBuffers[key] = buf

        var out = rebuildHeader(
            parsed.header,
            mediaSequence: buf.firstSequence,
            discontinuitySequence: buf.discontinuitySequence
        )
        for seg in buf.segments { out.append(contentsOf: seg.lines) }
        if promotePrefetch {
            for seg in parsed.prefetch where !buf.seenURLs.contains(seg.url) {
                out.append(contentsOf: seg.lines)
            }
        }
        return Data(out.joined(separator: "\n").utf8)
    }

    /// Splits a media playlist into its header, sequence numbers, real segments
    /// and (promoted) prefetch segments. Each segment keeps its full text block so
    /// per-segment tags survive verbatim.
    private func parseMediaPlaylist(_ text: String) -> ParsedMediaPlaylist {
        let lines = text.components(separatedBy: "\n")
        var header: [String] = []
        var mediaSequence = 0
        var discontinuitySequence = 0
        var segments: [MediaSegment] = []
        var prefetch: [MediaSegment] = []
        var pending: [String] = []
        var pendingHasDiscontinuity = false
        var lastDuration = Double(fallbackSegmentDuration(in: lines)) ?? 2.0
        var headerDone = false

        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)

            if !headerDone {
                if t.isEmpty {
                    header.append(raw)
                    continue
                }
                if t.hasPrefix("#"), !isSegmentStart(t) {
                    if t.hasPrefix(Self.mediaSequenceTag) {
                        mediaSequence =
                            Int(t.dropFirst(Self.mediaSequenceTag.count)
                                .trimmingCharacters(in: .whitespaces)) ?? 0
                    } else if t.hasPrefix(Self.discontinuitySequenceTag) {
                        discontinuitySequence =
                            Int(t.dropFirst(Self.discontinuitySequenceTag.count)
                                .trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                    header.append(raw)
                    continue
                }
                headerDone = true
            }

            if t.isEmpty { continue }

            if t.hasPrefix(Self.prefetchTag) {
                let urlString = String(t.dropFirst(Self.prefetchTag.count))
                    .trimmingCharacters(in: .whitespaces)
                guard !urlString.isEmpty else { continue }
                // Twitch prefetch tags carry no #EXTINF. Streamlink estimates their
                // length from the average of the real segments rather than the last
                // one, which is steadier when durations vary near a boundary. Fall
                // back to the last seen duration when no real segment exists yet.
                let prefetchDuration: Double
                if segments.isEmpty {
                    prefetchDuration = lastDuration
                } else {
                    prefetchDuration =
                        segments.reduce(0.0) { $0 + $1.duration } / Double(segments.count)
                }
                var block = pending
                block.append("\(Self.extinfTag)\(String(format: "%.3f", prefetchDuration)),")
                block.append(urlString)
                prefetch.append(
                    MediaSegment(
                        url: urlString,
                        lines: block,
                        duration: prefetchDuration,
                        isDiscontinuity: pendingHasDiscontinuity
                    )
                )
                pending = []
                pendingHasDiscontinuity = false
            } else if t.hasPrefix("#") {
                if t.hasPrefix(Self.extinfTag), let dur = duration(fromExtinf: t),
                    let value = Double(dur)
                {
                    lastDuration = value
                }
                if t.hasPrefix(Self.discontinuityTag),
                    !t.hasPrefix(Self.discontinuitySequenceTag)
                {
                    pendingHasDiscontinuity = true
                }
                pending.append(raw)
            } else {
                var block = pending
                block.append(raw)
                segments.append(
                    MediaSegment(
                        url: t,
                        lines: block,
                        duration: lastDuration,
                        isDiscontinuity: pendingHasDiscontinuity
                    )
                )
                pending = []
                pendingHasDiscontinuity = false
            }
        }

        return ParsedMediaPlaylist(
            header: header,
            mediaSequence: mediaSequence,
            discontinuitySequence: discontinuitySequence,
            segments: segments,
            prefetch: prefetch
        )
    }

    private func isSegmentStart(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix(Self.discontinuitySequenceTag) { return false }
        return Self.segmentStartTags.contains { trimmed.hasPrefix($0) }
    }

    // MARK: - Apple LL-HLS synthesis

    /// Synthesizes an Apple Low-Latency-HLS media playlist from a Twitch live
    /// media playlist, and reports the highest media sequence whose content is
    /// actually available (used to satisfy blocking reloads).
    ///
    /// Mapping (coarse-part model — see docs/low-latency.md "Findings"):
    /// - We have no transmuxer, so each whole ~2s Twitch segment becomes ONE
    ///   independent `#EXT-X-PART` (`PART-TARGET` = the segment duration). We
    ///   cannot produce true sub-second parts.
    /// - Real segments stay as `#EXTINF` segments; the most recent
    ///   `llhlsPartSegmentWindow` of them additionally get an `#EXT-X-PART` line so
    ///   AVPlayer has parts near the live edge.
    /// - Twitch advertises 1-2 `#EXT-X-TWITCH-PREFETCH` URLs (near-ready upcoming
    ///   segments). All but the freshest are emitted as available parts +
    ///   `#EXTINF` segments; the FRESHEST becomes the trailing
    ///   `#EXT-X-PRELOAD-HINT:TYPE=PART` — the part AVPlayer pre-requests and that
    ///   our blocking reload holds until Twitch publishes it.
    /// - `CAN-BLOCK-RELOAD=YES` + `PART-HOLD-BACK` (>= 3x PART-TARGET per
    ///   RFC 8216bis) advertise LL-HLS so AVPlayer issues blocking reloads.
    func llhlsSynthesis(from text: String) -> (data: Data, availableMSN: Int) {
        let parsed = parseMediaPlaylist(text)
        let partTarget = representativePartDuration(parsed)
        // RFC 8216bis 4.4.4.7: PART-HOLD-BACK MUST be >= 3x PART-TARGET.
        let holdBack = partTarget * 3

        // The freshest prefetch is held back as the preload-hint (the part still
        // being produced); earlier prefetches are already-available parts.
        let availableParts = parsed.prefetch.dropLast()
        let preloadHint = parsed.prefetch.last

        var out = llhlsHeader(parsed.header, partTarget: partTarget, holdBack: holdBack)

        let partWindowStart = max(0, parsed.segments.count - llhlsPartSegmentWindow)
        for (i, seg) in parsed.segments.enumerated() {
            if i >= partWindowStart {
                out.append(llhlsPartLine(uri: seg.url, duration: seg.duration))
            }
            out.append(contentsOf: seg.lines)
        }
        for seg in availableParts {
            out.append(llhlsPartLine(uri: seg.url, duration: seg.duration))
            out.append(contentsOf: seg.lines)
        }
        if let hint = preloadHint {
            out.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(hint.url)\"")
        }

        // Highest media sequence whose content is in the playlist: the last real
        // segment, plus each already-available prefetch part (the preload-hint one
        // is intentionally excluded — it is not yet available).
        let availableMSN =
            parsed.mediaSequence + parsed.segments.count - 1 + availableParts.count
        return (Data(out.joined(separator: "\n").utf8), availableMSN)
    }

    private func llhlsPartLine(uri: String, duration: Double) -> String {
        "#EXT-X-PART:DURATION=\(String(format: "%.3f", duration)),URI=\"\(uri)\",INDEPENDENT=YES"
    }

    /// PART-TARGET / hold-back basis: the average real-segment duration (steady
    /// near boundaries), falling back to `#EXT-X-TARGETDURATION` then 2s.
    private func representativePartDuration(_ parsed: ParsedMediaPlaylist) -> Double {
        if !parsed.segments.isEmpty {
            return parsed.segments.reduce(0.0) { $0 + $1.duration } / Double(parsed.segments.count)
        }
        return 2.0
    }

    /// Rebuilds the media-playlist header for LL-HLS: bumps `#EXT-X-VERSION` to 9
    /// (LL-HLS needs >= 6), drops any stale server-control / part-inf tags, and
    /// inserts `#EXT-X-SERVER-CONTROL` + `#EXT-X-PART-INF` right after `#EXTM3U`.
    private func llhlsHeader(_ header: [String], partTarget: Double, holdBack: Double) -> [String] {
        var out: [String] = []
        var sawVersion = false
        for raw in header {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#EXT-X-VERSION") {
                out.append("#EXT-X-VERSION:9")
                sawVersion = true
            } else if t.hasPrefix("#EXT-X-SERVER-CONTROL") || t.hasPrefix("#EXT-X-PART-INF") {
                continue
            } else {
                out.append(raw)
            }
        }
        var control = [
            "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=\(String(format: "%.3f", holdBack))",
            "#EXT-X-PART-INF:PART-TARGET=\(String(format: "%.3f", partTarget))",
        ]
        if !sawVersion { control.insert("#EXT-X-VERSION:9", at: 0) }

        if let idx = out.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U")
        }) {
            out.insert(contentsOf: control, at: idx + 1)
        } else {
            out.insert(contentsOf: control, at: 0)
        }
        return out
    }

    // MARK: - Blocking-reload query parsing

    /// Parses Apple's blocking-reload params (`_HLS_msn`, optional `_HLS_part`)
    /// from a playlist request. Returns nil when absent (a non-blocking request).
    func blockingReloadTarget(from url: URL) -> (msn: Int, part: Int)? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let msnItem = items.first(where: { $0.name == "_HLS_msn" }),
              let msn = msnItem.value.flatMap({ Int($0) })
        else { return nil }
        let part = items.first(where: { $0.name == "_HLS_part" })?.value.flatMap { Int($0) } ?? 0
        return (msn, part)
    }

    /// Strips Apple's blocking-reload params before fetching Twitch upstream
    /// (which would reject the unknown query items).
    private func upstreamURLStrippingBlockingParams(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return url }
        let filtered = items.filter { !$0.name.hasPrefix("_HLS_") }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.url ?? url
    }

    // MARK: - Test seams

    /// Synchronously rewrites a master playlist on the delegate queue. Test-only
    /// entry point so the private rewrite path can be exercised deterministically.
    func rewriteMasterPlaylistForTesting(_ text: String) -> String {
        delegateQueue.sync { String(decoding: rewriteMasterPlaylist(text), as: UTF8.self) }
    }

    /// Synchronously sets the behavior flags and rewrites a media playlist on the
    /// delegate queue, matching production threading so unit tests are
    /// deterministic. Test-only entry point.
    func rewriteMediaPlaylistForTesting(
        _ text: String,
        sourceURL: URL,
        promotePrefetch: Bool,
        retainHistory: Bool,
        windowSeconds: Double = 1800
    ) -> String {
        delegateQueue.sync {
            self.promotePrefetch = promotePrefetch
            self.retainHistory = retainHistory
            self.dvrWindowSeconds = windowSeconds
            return String(decoding: rewriteMediaPlaylist(text, sourceURL: sourceURL), as: UTF8.self)
        }
    }

    /// Synchronously synthesizes an LL-HLS playlist on the delegate queue, with
    /// the highest-available media sequence. Test-only entry point.
    func llhlsSynthesisForTesting(_ text: String) -> (playlist: String, availableMSN: Int) {
        delegateQueue.sync {
            let result = llhlsSynthesis(from: text)
            return (String(decoding: result.data, as: UTF8.self), result.availableMSN)
        }
    }

    /// Rewrites the `#EXT-X-MEDIA-SEQUENCE` / `#EXT-X-DISCONTINUITY-SEQUENCE`
    /// header values to match the retained window, inserting them if absent.
    private func rebuildHeader(
        _ header: [String],
        mediaSequence: Int,
        discontinuitySequence: Int
    ) -> [String] {
        var out: [String] = []
        out.reserveCapacity(header.count + 2)
        var replacedMedia = false
        var replacedDisc = false

        for raw in header {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(Self.mediaSequenceTag) {
                out.append("\(Self.mediaSequenceTag)\(mediaSequence)")
                replacedMedia = true
            } else if t.hasPrefix(Self.discontinuitySequenceTag) {
                out.append("\(Self.discontinuitySequenceTag)\(discontinuitySequence)")
                replacedDisc = true
            } else {
                out.append(raw)
            }
        }

        if !replacedMedia {
            insertHeaderTag(&out, "\(Self.mediaSequenceTag)\(mediaSequence)")
        }
        if !replacedDisc, discontinuitySequence > 0 {
            insertHeaderTag(&out, "\(Self.discontinuitySequenceTag)\(discontinuitySequence)")
        }
        return out
    }

    private func insertHeaderTag(_ out: inout [String], _ tag: String) {
        if let idx = out.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U")
        }) {
            out.insert(tag, at: idx + 1)
        } else {
            out.insert(tag, at: 0)
        }
    }

    // MARK: - Helpers

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest, with data: Data) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.playlistContentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let offset = Int(dataRequest.requestedOffset)
        guard offset <= data.count else {
            loadingRequest.finishLoading(with: PlaybackError.badResponse)
            return
        }

        let end: Int
        if dataRequest.requestsAllDataToEndOfResource {
            end = data.count
        } else {
            end = min(data.count, offset + dataRequest.requestedLength)
        }
        dataRequest.respond(with: data.subdata(in: offset..<end))
        loadingRequest.finishLoading()
    }

    private func httpsURL(from url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "https"
        return comps.url
    }

    private func disguiseScheme(of urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { return urlString }
        return proxyURL(for: url).absoluteString
    }

    /// Rewrites the `URI="..."` value of an HLS tag (e.g. `#EXT-X-MEDIA`) onto the
    /// custom scheme, leaving the rest of the line untouched.
    private func rewriteURIAttribute(in line: String) -> String {
        let marker = "URI=\""
        guard let start = line.range(of: marker) else { return line }
        let afterQuote = start.upperBound
        guard let closing = line[afterQuote...].firstIndex(of: "\"") else { return line }
        let value = String(line[afterQuote..<closing])
        let replacement = disguiseScheme(of: value)
        return line.replacingCharacters(in: afterQuote..<closing, with: replacement)
    }

    private func duration(fromExtinf line: String) -> String? {
        let rest = line.dropFirst(Self.extinfTag.count)
        let durPart = rest.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        return durPart.isEmpty ? nil : durPart
    }

    private func fallbackSegmentDuration(in lines: [String]) -> String {
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(Self.targetDurationTag) {
                let value = trimmed.dropFirst(Self.targetDurationTag.count)
                    .trimmingCharacters(in: .whitespaces)
                if let seconds = Double(value) {
                    return String(format: "%.3f", seconds)
                }
            }
        }
        return "2.000"
    }
}
