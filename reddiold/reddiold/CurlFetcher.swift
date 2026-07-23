import Foundation

// MARK: - C-compatible callback (file scope, no captures allowed)

private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let buf = Unmanaged<NSMutableData>.fromOpaque(userdata).takeUnretainedValue()
    buf.append(ptr, length: bytes)
    return bytes
}

/// libcurl + OpenSSL fetcher for iOS 6 — Reddit's edge (Fastly/Akamai) requires GCM
/// cipher suites that iOS 6's CBC-only Secure Transport cannot negotiate, so
/// NSURLConnection can't be used there. Same architecture as oldpipe/podcold's
/// CurlFetcher: a serial background queue feeding a thin C bridge around libcurl.
///
/// NOTE: the statically-linked libcurl here has no bundled CA cert file, so
/// certificate verification is disabled (mirrors oldpipe/podcold's pattern) —
/// this means requests are not protected against a MITM on the network path.
/// Acceptable for now since this only touches Reddit's public read-only feeds,
/// but worth revisiting (e.g. bundling a cacert.pem + CURLOPT_CAINFO) later.
class CurlFetcher {
    private static var active: [CurlFetcher] = []
    private static let curlQueue = DispatchQueue(label: "com.reddiold.curl")
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    /// Serializes every libcurl transfer app-wide (feed/comment/thumbnail/gallery fetches AND
    /// RedditVideoProxy's own video/audio segment fetches, which run on their own connection
    /// threads rather than curlQueue). This project's libcurl is statically linked against
    /// OpenSSL without the modern per-thread-safe locking callbacks configured — a sibling
    /// project (oldpipe) confirmed on real hardware that letting two TLS handshakes run
    /// concurrently across separate CurlHandles can crash/corrupt shared OpenSSL state. A
    /// single process-wide lock trades a little throughput for correctness — acceptable since
    /// each transfer here is a small, bounded fetch (feed XML or one video/audio segment).
    fileprivate static let performLock = NSLock()

    static func fetch(url: URL, userAgent: String, timeout: TimeInterval = 20,
                       completion: @escaping (Data?, Error?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        curlQueue.async {
            let (data, error) = fetcher.syncFetch(url: url.absoluteString, userAgent: userAgent, timeout: timeout, rangeHeader: nil)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data, error)
            }
        }
    }

    /// Same as fetch(url:userAgent:timeout:completion:) but adds a "Range: bytes=..." header —
    /// used for fetching individual video/audio byte-range segments (see RedditVideoProxy).
    /// Accepts HTTP 200 or 206 (partial content) as success, unlike the plain fetch above.
    static func fetchRange(url: URL, userAgent: String, rangeHeader: String, timeout: TimeInterval = 20,
                            completion: @escaping (Data?, Error?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        curlQueue.async {
            let (data, error) = fetcher.syncFetch(url: url.absoluteString, userAgent: userAgent, timeout: timeout, rangeHeader: rangeHeader)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data, error)
            }
        }
    }

    /// Synchronous variant of fetchRange, for use from a background thread that's already
    /// off the main queue (RedditVideoProxy's own connection-handling thread) — avoids the
    /// extra async hop back onto curlQueue for a fetcher that's already serialized per-connection.
    static func syncFetchRange(url: URL, userAgent: String, rangeHeader: String, timeout: TimeInterval = 20) -> (Data?, Error?) {
        let fetcher = CurlFetcher()
        return fetcher.syncFetch(url: url.absoluteString, userAgent: userAgent, timeout: timeout, rangeHeader: rangeHeader)
    }

    private static func retain(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.append(f)
        objc_sync_exit(CurlFetcher.self)
    }

    private static func release(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.removeAll { $0 === f }
        objc_sync_exit(CurlFetcher.self)
    }

    private func syncFetch(url: String, userAgent: String, timeout: TimeInterval, rangeHeader: String?) -> (Data?, Error?) {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        userAgent.withCString { curl_bridge_set_user_agent(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)
        if let rangeHeader = rangeHeader {
            rangeHeader.withCString { curl_bridge_add_header(h, $0) }
        }

        CurlFetcher.performLock.lock()
        let rc = curl_bridge_perform(h)
        CurlFetcher.performLock.unlock()
        guard rc == 0 else {
            let message = String(cString: curl_bridge_strerror(rc))
            return (nil, NSError(domain: "CurlFetcher", code: Int(rc),
                                  userInfo: [NSLocalizedDescriptionKey: message]))
        }
        let httpCode = curl_bridge_response_code(h)
        let acceptableCodes: Set<CLong> = rangeHeader != nil ? [200, 206] : [200]
        guard acceptableCodes.contains(httpCode) else {
            return (nil, NSError(domain: "CurlFetcher", code: Int(httpCode),
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpCode)"]))
        }
        return (buf as Data, nil)
    }
}
