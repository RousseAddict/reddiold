import Foundation

/// Manual (no NSRegularExpression, matches this project's plain-string-parsing convention —
/// see HTMLUtil/RedditAPI.GalleryHTMLParser) parser for the subset of the HLS spec Reddit's
/// v.redd.it CDN actually uses:
///   - A master playlist (HLSPlaylist.m3u8) listing #EXT-X-MEDIA audio groups and
///     #EXT-X-STREAM-INF video variants (each referencing an AUDIO group by id).
///   - Per-variant playlists using #EXT-X-MAP (init segment byte range) followed by a run of
///     #EXTINF/#EXT-X-BYTERANGE/URI triples — one per media segment, all pointing at byte
///     ranges within the SAME single fragmented-mp4 file (confirmed via curl on SERV2).
/// Per RFC 8216 §4.3.2.5, an #EXT-X-BYTERANGE with no "@offset" means "immediately follows the
/// previous byte range for the same URI" — tracked here via a running `cursor`.
///
/// Confirmed via curl (2026-07-23): for a given Reddit video, the video and audio variant
/// playlists always have the SAME segment count (e.g. 64/64), so RedditVideoProxy pairs
/// video segment i with audio segment i by plain array index — no sidx-box parsing or
/// time-window audio trimming needed (unlike oldpipe's YouTube HLSTransmuxer, which has no
/// equivalent of Reddit's own byte-range-annotated playlists and must derive ranges from
/// binary sidx boxes instead).
enum M3U8Parser {

    struct ByteRange { let start: Int64; let end: Int64 } // end inclusive

    struct Variant {
        let bandwidth: Int
        let playlistURL: URL
        let audioGroupID: String?
    }

    struct Segment { let range: ByteRange; let duration: Double }

    struct VariantPlaylist {
        let mediaURL: URL         // absolute URL of the single underlying fragmented mp4
        let initRange: ByteRange
        let segments: [Segment]   // in playback order
    }

    // MARK: - Attribute-list parsing ("KEY=VALUE,KEY=\"VALUE\",..." — commas inside quotes
    // don't split attributes; Reddit's playlists never need that here, but CODECS="a,b" appears
    // in #EXT-X-STREAM-INF so it must still be handled correctly).

    private static func parseAttributes(_ s: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingKey = true
        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty { attrs[trimmedKey] = value }
            key = ""; value = ""; readingKey = true
        }
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && ch == "," { commit(); continue }
            if !inQuotes && readingKey && ch == "=" { readingKey = false; continue }
            if readingKey { key.append(ch) } else { value.append(ch) }
        }
        commit()
        return attrs
    }

    private static func lines(_ text: String) -> [String] {
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Master playlist

    /// Video variants — each entry pairs a resolved playlist URL with the BANDWIDTH and
    /// referenced AUDIO group id (resolved separately via audioGroupURLs(_:baseURL:)).
    static func masterVariants(_ text: String, baseURL: URL) -> [Variant] {
        var variants: [Variant] = []
        var pendingBandwidth: Int?
        var pendingAudioGroup: String?
        for line in lines(text) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                pendingBandwidth = attrs["BANDWIDTH"].flatMap { Int($0) }
                pendingAudioGroup = attrs["AUDIO"]
            } else if !line.isEmpty && !line.hasPrefix("#") {
                if let bw = pendingBandwidth, let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    variants.append(Variant(bandwidth: bw, playlistURL: url, audioGroupID: pendingAudioGroup))
                }
                pendingBandwidth = nil
                pendingAudioGroup = nil
            }
        }
        return variants
    }

    /// [GROUP-ID: absolute audio playlist URL] from #EXT-X-MEDIA:TYPE=AUDIO lines.
    static func audioGroupURLs(_ text: String, baseURL: URL) -> [String: URL] {
        var groups: [String: URL] = [:]
        for line in lines(text) {
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attrs["TYPE"] == "AUDIO",
                  let groupID = attrs["GROUP-ID"],
                  let uri = attrs["URI"],
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            groups[groupID] = url
        }
        return groups
    }

    // MARK: - Byte-range variant playlist

    static func variantPlaylist(_ text: String, baseURL: URL) -> VariantPlaylist? {
        var mediaURL: URL?
        var initRange: ByteRange?
        var segments: [Segment] = []
        var cursor: Int64 = 0
        var pendingRange: (length: Int64, offset: Int64?)?
        var pendingDuration: Double?

        for line in lines(text) {
            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attrs["URI"], let br = attrs["BYTERANGE"],
                      let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
                mediaURL = url
                let (len, off) = byteRangeValue(br)
                let start = off ?? 0
                initRange = ByteRange(start: start, end: start + len - 1)
                cursor = start + len
            } else if line.hasPrefix("#EXTINF:") {
                let rest = line.dropFirst("#EXTINF:".count)
                let durText = rest.split(separator: ",").first.map(String.init) ?? String(rest)
                pendingDuration = Double(durText)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRangeValue(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let (len, off) = pendingRange, let dur = pendingDuration else { continue }
                let start = off ?? cursor
                segments.append(Segment(range: ByteRange(start: start, end: start + len - 1), duration: dur))
                cursor = start + len
                pendingRange = nil
                pendingDuration = nil
            }
        }
        guard let mediaURL = mediaURL, let initRange = initRange, !segments.isEmpty else { return nil }
        return VariantPlaylist(mediaURL: mediaURL, initRange: initRange, segments: segments)
    }

    // "length@offset" or "length" -> (length, offset?)
    private static func byteRangeValue(_ s: String) -> (Int64, Int64?) {
        let parts = s.components(separatedBy: "@")
        let len = Int64(parts[0]) ?? 0
        let off = parts.count > 1 ? Int64(parts[1]) : nil
        return (len, off)
    }
}
