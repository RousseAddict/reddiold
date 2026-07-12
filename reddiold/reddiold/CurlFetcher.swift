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

    static func fetch(url: URL, userAgent: String, timeout: TimeInterval = 20,
                       completion: @escaping (Data?, Error?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        curlQueue.async {
            let (data, error) = fetcher.syncFetch(url: url.absoluteString, userAgent: userAgent, timeout: timeout)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data, error)
            }
        }
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

    private func syncFetch(url: String, userAgent: String, timeout: TimeInterval) -> (Data?, Error?) {
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

        let rc = curl_bridge_perform(h)
        guard rc == 0 else {
            let message = String(cString: curl_bridge_strerror(rc))
            return (nil, NSError(domain: "CurlFetcher", code: Int(rc),
                                  userInfo: [NSLocalizedDescriptionKey: message]))
        }
        let httpCode = curl_bridge_response_code(h)
        guard httpCode == 200 else {
            return (nil, NSError(domain: "CurlFetcher", code: Int(httpCode),
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpCode)"]))
        }
        return (buf as Data, nil)
    }
}
