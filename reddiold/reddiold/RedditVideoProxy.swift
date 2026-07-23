import Foundation
import Darwin

// MARK: - RedditVideoProxy
//
// Local loopback HTTP server that serves Reddit's fMP4/CMAF HLS video as a classic
// byte-range/.ts-segmented HLS VOD stream MPMoviePlayerController can actually play.
//
// Why this exists: v.redd.it always serves separate video-only + audio-only fragmented MP4
// (CMAF) streams addressed via HLS #EXT-X-MAP/#EXT-X-BYTERANGE — a format MPMoviePlayerController
// (this project's legacy iOS 6/7/8 video player) cannot parse at all (fMP4-in-HLS support only
// arrived with iOS 10's AVFoundation), and the old progressive DASH_{res}.mp4 fallback now
// returns HTTP 403 (confirmed via curl, 2026-07-23). This proxy fetches the exact byte ranges
// Reddit's own playlists already publish (see M3U8Parser), muxes each video+audio fragment pair
// into one MPEG-TS segment on the fly (RedditVideoMux), and serves a generated classic HLS VOD
// playlist + those .ts segments over plain loopback HTTP (no TLS/App Transport Security issue —
// pre-iOS9 has no ATS at all, and this project's iOS 8/9 target never exceeds that).
//
// Architecture ported from oldpipe's StreamProxy.swift (built for the structurally identical
// problem with YouTube's DASH streams), with the following DROPPED as unnecessary here:
//   - sidx-box parsing / time-window audio trimming (Reddit's playlists give exact ranges
//     directly, and video/audio segment counts are confirmed aligned 1:1 — see M3U8Parser).
//   - The generic HTTPS reverse-proxy passthrough route (Reddit always separates audio/video,
//     never offers a single muxed file to passthrough).
//   - The feed-turnstile pause/resume + progress-callback generation-abort machinery (built for
//     an always-mounted player where rapid video switching had to abort in-flight fetches).
//     reddiold only ever plays one video at a time via a modal MPMoviePlayerViewController, so a
//     stale session is simply dropped (closeSession) once the player is dismissed — nothing else
//     can be concurrently requesting it.
final class RedditVideoProxy: NSObject {

    static let shared = RedditVideoProxy()

    struct Seg {
        let videoRange: M3U8Parser.ByteRange
        let audioRange: M3U8Parser.ByteRange
        let duration: Double
    }

    private final class Session {
        let videoURL: URL
        let audioURL: URL
        let videoInitRange: M3U8Parser.ByteRange
        let audioInitRange: M3U8Parser.ByteRange
        let segs: [Seg]
        var info: RedditHLSStreamInfo?
        var playlistText: String?
        let parseLock = NSLock()
        init(videoURL: URL, audioURL: URL, videoInitRange: M3U8Parser.ByteRange,
             audioInitRange: M3U8Parser.ByteRange, segs: [Seg]) {
            self.videoURL = videoURL
            self.audioURL = audioURL
            self.videoInitRange = videoInitRange
            self.audioInitRange = audioInitRange
            self.segs = segs
        }
    }

    private var listenFd: Int32 = -1
    private var port: UInt16 = 0
    private var started = false
    private var sessions: [String: Session] = [:]
    private var nextId: UInt64 = 0
    private let lock = NSLock()

    /// Registers a new video for playback and returns the local playlist URL to hand to
    /// MPMoviePlayerViewController. Starts the loopback listener on first use.
    func registerSession(videoURL: URL, audioURL: URL,
                          videoInitRange: M3U8Parser.ByteRange, audioInitRange: M3U8Parser.ByteRange,
                          segments: [Seg]) -> URL? {
        guard !segments.isEmpty, start() else { return nil }
        lock.lock()
        nextId += 1
        let id = "\(nextId)"
        sessions[id] = Session(videoURL: videoURL, audioURL: audioURL,
                                videoInitRange: videoInitRange, audioInitRange: audioInitRange, segs: segments)
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/hls/\(id)/index.m3u8")
    }

    /// Drops a session once its player has been dismissed/finished — see class doc for why no
    /// generation/cancellation bookkeeping (unlike oldpipe's StreamProxy) is needed here.
    func closeSession(url: URL?) {
        guard let url = url else { return }
        let comps = url.path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let hlsIndex = comps.firstIndex(of: "hls"), hlsIndex + 1 < comps.count else { return }
        let id = comps[hlsIndex + 1]
        lock.lock(); sessions.removeValue(forKey: id); lock.unlock()
    }

    // MARK: - Listener (ported from oldpipe's StreamProxy, minus the generic passthrough /
    // feed-turnstile / Chromecast machinery this app doesn't need)

    @discardableResult
    private func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }

        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only
        addr.sin_port = 0                                 // ephemeral port assigned by the kernel

        let bindOk = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0, listen(fd, 8) == 0 else { close(fd); return false }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOk = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameOk == 0 else { close(fd); return false }
        port = UInt16(bigEndian: bound.sin_port)

        listenFd = fd
        started = true
        // Raw Thread (not GCD): the accept loop blocks forever, and per-connection threads
        // block in synchronous curl_easy_perform calls for the whole segment fetch.
        let t = Thread(target: self, selector: #selector(acceptLoop), object: nil)
        t.stackSize = 512 * 1024
        t.start()
        return true
    }

    @objc private func acceptLoop() {
        while true {
            let client = accept(listenFd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread(target: self, selector: #selector(handleConnection(_:)), object: NSNumber(value: client))
            t.stackSize = 512 * 1024
            t.start()
        }
    }

    // MARK: - Per-connection handling

    @objc private func handleConnection(_ obj: Any) {
        guard let num = obj as? NSNumber else { return }
        let clientFd = num.int32Value
        defer { close(clientFd) }

        guard let request = readRequestHead(clientFd) else { return }
        guard let requestLine = request.components(separatedBy: "\r\n").first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        var path = parts[1]
        if path.hasPrefix("/") { path.removeFirst() }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

        // "hls/<id>/index.m3u8" or "hls/<id>/segN.ts"
        let comps = path.components(separatedBy: "/")
        guard comps.count == 3, comps[0] == "hls" else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        lock.lock(); let session = sessions[comps[1]]; lock.unlock()
        guard let session = session else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        serve(session, file: comps[2], clientFd: clientFd)
    }

    // Serve one HLS request: the generated VOD playlist (parsing the stream init segments
    // lazily on first hit) or one transmuxed TS segment (two bounded ranged GETs + mux).
    // Runs on the per-connection thread — blocking here is fine, MPMoviePlayerController waits.
    private func serve(_ session: Session, file: String, clientFd: Int32) {
        guard let info = ensureParsed(session) else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        if file == "index.m3u8" {
            session.parseLock.lock(); let text = session.playlistText ?? ""; session.parseLock.unlock()
            sendResponse(clientFd, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
            return
        }

        guard file.hasPrefix("seg"), file.hasSuffix(".ts"),
              let segIndex = Int(String(file.dropFirst(3).dropLast(3))),
              segIndex >= 0, segIndex < session.segs.count else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let seg = session.segs[segIndex]
        guard let vBlob = fetchRange(url: session.videoURL, range: seg.videoRange),
              let aBlob = fetchRange(url: session.audioURL, range: seg.audioRange) else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard let ts = RedditHLSTransmuxer.muxSegment(info, videoBlob: vBlob, audioBlob: aBlob) else {
            RedditVideoProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        sendResponse(clientFd, contentType: "video/MP2T", body: ts)
    }

    // Fetch + parse both streams' init segments once per session; cache info + playlist.
    // parseLock serializes MPMoviePlayerController's parallel connections so this happens once.
    private func ensureParsed(_ session: Session) -> RedditHLSStreamInfo? {
        session.parseLock.lock()
        defer { session.parseLock.unlock() }
        if let info = session.info { return info }
        guard let vInitData = fetchRange(url: session.videoURL, range: session.videoInitRange),
              let aInitData = fetchRange(url: session.audioURL, range: session.audioInitRange),
              let info = RedditHLSTransmuxer.parse(videoInitData: vInitData, audioInitData: aInitData) else { return nil }
        session.info = info
        session.playlistText = RedditVideoProxy.buildPlaylist(durations: session.segs.map { $0.duration })
        return info
    }

    private static func buildPlaylist(durations: [Double]) -> String {
        let target = max(1, Int((durations.max() ?? 6).rounded(.up)))
        var m3u8 = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        m3u8 += "#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for (i, dur) in durations.enumerated() {
            m3u8 += String(format: "#EXTINF:%.5f,\n", dur)
            m3u8 += "seg\(i).ts\n"
        }
        m3u8 += "#EXT-X-ENDLIST\n"
        return m3u8
    }

    // Bounded ranged GET through the curl bridge — reuses CurlFetcher's synchronous path (own
    // CurlHandle per call) so this runs directly on the connection's own Thread, serialized
    // app-wide against other libcurl transfers via CurlFetcher.performLock (see its doc comment).
    private func fetchRange(url: URL, range: M3U8Parser.ByteRange) -> Data? {
        guard range.end >= range.start else { return nil }
        let (data, error) = CurlFetcher.syncFetchRange(url: url, userAgent: RedditAPI.userAgent,
                                                        rangeHeader: "Range: bytes=\(range.start)-\(range.end)")
        guard error == nil, let data = data else { return nil }
        return data
    }

    private func sendResponse(_ clientFd: Int32, contentType: String, body: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard RedditVideoProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.baseAddress {
                _ = RedditVideoProxy.sendAll(clientFd, base.assumingMemoryBound(to: UInt8.self), body.count)
            }
        }
    }

    private func readRequestHead(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .isoLatin1) }
            data.append(buf, count: n)
            if data.count > 16 * 1024 { break }   // guard against a runaway/malformed head
        }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Socket write helpers (called from the accept/connection threads)

    @discardableResult
    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        return bytes.withUnsafeBufferPointer { sendAll(fd, $0.baseAddress!, $0.count) }
    }

    @discardableResult
    static func sendAll(_ fd: Int32, _ ptr: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let n = send(fd, ptr + sent, count - sent, 0)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }
}
