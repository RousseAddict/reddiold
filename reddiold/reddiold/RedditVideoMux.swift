import Foundation

// MARK: - RedditVideoMux
//
// Reddit's v.redd.it CDN always serves video via a fragmented MP4 (CMAF) HLS stream, video-only
// and audio-only, addressed via #EXT-X-MAP/#EXT-X-BYTERANGE — MPMoviePlayerController (this
// project's legacy iOS 6/7/8 video player) cannot parse fMP4-in-HLS at all (that only arrived
// with iOS 10's AVFoundation), and the old progressive DASH_{res}.mp4 fallback now returns
// HTTP 403 (confirmed via curl, 2026-07-23). This file transmuxes one video fragment + one
// paired audio fragment (matched by playlist segment index — see M3U8Parser) into a classic
// MPEG-TS segment, which MPMoviePlayerController natively understands.
//
// Ported from oldpipe's HLSTransmuxer.swift (built for the structurally identical problem with
// YouTube's separately-served DASH video/audio fMP4 streams), with the sidx-box parsing and
// time-window audio trimming DROPPED — Reddit's own playlists already publish exact per-segment
// byte ranges directly (see M3U8Parser), and video/audio segment counts are confirmed aligned
// 1:1, so no YouTube-style sidx-derived range math is needed here.
//
// Pure data-in/data-out (no networking, no UI) — runs inside RedditVideoProxy's connection
// threads serving MPMoviePlayerController; every failure path returns nil rather than crashing.

// MARK: - Byte reading helpers

fileprivate extension Data {
    func be16(_ o: Int) -> Int { Int(self[startIndex + o]) << 8 | Int(self[startIndex + o + 1]) }
    func be32(_ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(self[startIndex + o + i]) }
        return v
    }
    func fourCC(_ o: Int) -> String {
        String(bytes: self[(startIndex + o)..<(startIndex + o + 4)], encoding: .isoLatin1) ?? "????"
    }
    func sub(_ o: Int, _ len: Int) -> Data {
        subdata(in: (startIndex + o)..<(startIndex + o + len))
    }
}

// MARK: - MP4 box iteration

private struct MP4Box { let type: String; let payload: Data; let fileOffset: Int; let fullSize: Int }

private func mp4Boxes(in data: Data, baseOffset: Int = 0) -> [MP4Box] {
    var out: [MP4Box] = []
    var off = 0
    while off + 8 <= data.count {
        var size = Int(data.be32(off))
        let type = data.fourCC(off + 4)
        var hdr = 8
        if size == 1 {
            guard off + 16 <= data.count else { break }
            // 64-bit "largesize" is stored right after the fourCC — read it as a plain Int
            // via two be32 halves (avoids a redundant be64 helper for a 32-bit-only field
            // we never expect Reddit's segments to exceed).
            let hi = Int(data.be32(off + 8)), lo = Int(data.be32(off + 12))
            size = (hi << 32) | lo; hdr = 16
        }
        if size < hdr || off + size > data.count { break }
        out.append(MP4Box(type: type, payload: data.sub(off + hdr, size - hdr),
                          fileOffset: baseOffset + off, fullSize: size))
        off += size
    }
    return out
}

private func findMP4Box(_ data: Data, _ path: [String]) -> MP4Box? {
    var current = data
    for (i, name) in path.enumerated() {
        guard let b = mp4Boxes(in: current).first(where: { $0.type == name }) else { return nil }
        if i == path.count - 1 { return b }
        current = b.payload
    }
    return nil
}

// MARK: - init segment parsing

private struct TrexDefaults { var duration: UInt32 = 0; var size: UInt32 = 0; var flags: UInt32 = 0 }

private struct VideoInitInfo {
    let timescale: Int64
    let sps: [Data]
    let pps: [Data]
    let nalLengthSize: Int
    let defaults: TrexDefaults
}

private struct AudioInitInfo {
    let timescale: Int64
    let aacProfile: Int      // ADTS profile field = AudioObjectType - 1
    let freqIndex: Int
    let channelConfig: Int
    let defaults: TrexDefaults
}

private func parseTrex(_ initData: Data) -> TrexDefaults {
    var d = TrexDefaults()
    if let trex = findMP4Box(initData, ["moov", "mvex", "trex"]), trex.payload.count >= 24 {
        let p = trex.payload
        d.duration = p.be32(12); d.size = p.be32(16); d.flags = p.be32(20)
    }
    return d
}

private func mdhdTimescale(_ initData: Data) -> Int64? {
    guard let mdhd = findMP4Box(initData, ["moov", "trak", "mdia", "mdhd"]), mdhd.payload.count >= 16 else { return nil }
    let p = mdhd.payload
    let ver = p[p.startIndex]
    if ver == 1 { guard p.count >= 24 else { return nil }; return Int64(p.be32(20)) }
    return Int64(p.be32(12))
}

private func parseVideoInit(_ initData: Data) -> VideoInitInfo? {
    guard let ts = mdhdTimescale(initData), ts > 0 else { return nil }
    guard let stsd = findMP4Box(initData, ["moov", "trak", "mdia", "minf", "stbl", "stsd"]),
          stsd.payload.count > 8 else { return nil }
    guard let avc1 = mp4Boxes(in: stsd.payload.sub(8, stsd.payload.count - 8)).first,
          avc1.type == "avc1" || avc1.type == "avc3",
          avc1.payload.count > 78 else { return nil }
    let children = mp4Boxes(in: avc1.payload.sub(78, avc1.payload.count - 78))
    guard let avcC = children.first(where: { $0.type == "avcC" }), avcC.payload.count >= 7 else { return nil }
    let c = avcC.payload
    let nalLen = Int(c[c.startIndex + 4] & 0x03) + 1
    var o = 5
    let numSPS = Int(c[c.startIndex + o] & 0x1F); o += 1
    var sps: [Data] = []
    for _ in 0..<numSPS {
        guard c.count >= o + 2 else { return nil }
        let l = c.be16(o); o += 2
        guard c.count >= o + l else { return nil }
        sps.append(c.sub(o, l)); o += l
    }
    guard c.count >= o + 1 else { return nil }
    let numPPS = Int(c[c.startIndex + o]); o += 1
    var pps: [Data] = []
    for _ in 0..<numPPS {
        guard c.count >= o + 2 else { return nil }
        let l = c.be16(o); o += 2
        guard c.count >= o + l else { return nil }
        pps.append(c.sub(o, l)); o += l
    }
    guard !sps.isEmpty, !pps.isEmpty else { return nil }
    return VideoInitInfo(timescale: ts, sps: sps, pps: pps, nalLengthSize: nalLen,
                         defaults: parseTrex(initData))
}

private func parseAudioInit(_ initData: Data) -> AudioInitInfo? {
    guard let ts = mdhdTimescale(initData), ts > 0 else { return nil }
    guard let stsd = findMP4Box(initData, ["moov", "trak", "mdia", "minf", "stbl", "stsd"]),
          stsd.payload.count > 8 else { return nil }
    guard let mp4a = mp4Boxes(in: stsd.payload.sub(8, stsd.payload.count - 8)).first,
          mp4a.type == "mp4a", mp4a.payload.count > 28 else { return nil }
    let children = mp4Boxes(in: mp4a.payload.sub(28, mp4a.payload.count - 28))
    guard let esds = children.first(where: { $0.type == "esds" }) else { return nil }
    let e = esds.payload
    var o = 4
    func readDescriptor() -> (tag: Int, len: Int)? {
        guard e.count >= o + 2 else { return nil }
        let tag = Int(e[e.startIndex + o]); o += 1
        var len = 0
        for _ in 0..<4 {
            guard e.count >= o + 1 else { return nil }
            let b = Int(e[e.startIndex + o]); o += 1
            len = len << 7 | (b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        return (tag, len)
    }
    var asc: Data?
    if let d0 = readDescriptor(), d0.tag == 0x03 {
        o += 3
        if let d1 = readDescriptor(), d1.tag == 0x04 {
            o += 13
            if let d2 = readDescriptor(), d2.tag == 0x05, e.count >= o + d2.len {
                asc = e.sub(o, d2.len)
            }
        }
    }
    guard let cfg = asc, cfg.count >= 2 else { return nil }
    let b0 = Int(cfg[cfg.startIndex]), b1 = Int(cfg[cfg.startIndex + 1])
    let aot = b0 >> 3
    let freqIndex = (b0 & 0x07) << 1 | (b1 >> 7)
    let chan = (b1 >> 3) & 0x0F
    guard freqIndex != 15 else { return nil }   // explicit sample rate in ASC — not supported
    return AudioInitInfo(timescale: ts, aacProfile: max(0, aot - 1), freqIndex: freqIndex,
                         channelConfig: chan, defaults: parseTrex(initData))
}

// MARK: - fragment (moof/mdat) parsing

private struct FragSample {
    let data: Data
    let dts: Int64        // in track timescale
    let ctsOffset: Int64  // composition offset (pts = dts + cts)
    let duration: Int64
    let isSync: Bool
}

private func parseFragments(_ blob: Data, defaults: TrexDefaults) -> [FragSample]? {
    var samples: [FragSample] = []
    for box in mp4Boxes(in: blob) where box.type == "moof" {
        let moofStart = box.fileOffset
        guard let traf = mp4Boxes(in: box.payload).first(where: { $0.type == "traf" }) else { continue }
        var baseDecode: Int64 = 0
        var tfhdDefaultDur = defaults.duration
        var tfhdDefaultSize = defaults.size
        var tfhdDefaultFlags = defaults.flags
        let baseDataOffset: Int64 = Int64(moofStart)  // default-base-is-moof
        for child in mp4Boxes(in: traf.payload) {
            let p = child.payload
            switch child.type {
            case "tfhd":
                guard p.count >= 8 else { return nil }
                let flags = p.be32(0) & 0x00FF_FFFF
                var o = 8
                if flags & 0x01 != 0 { return nil }   // explicit base_data_offset unsupported
                if flags & 0x02 != 0 { o += 4 }
                if flags & 0x08 != 0 { guard p.count >= o + 4 else { return nil }; tfhdDefaultDur = p.be32(o); o += 4 }
                if flags & 0x10 != 0 { guard p.count >= o + 4 else { return nil }; tfhdDefaultSize = p.be32(o); o += 4 }
                if flags & 0x20 != 0 { guard p.count >= o + 4 else { return nil }; tfhdDefaultFlags = p.be32(o); o += 4 }
            case "tfdt":
                guard p.count >= 8 else { return nil }
                let ver = p[p.startIndex]
                if ver == 1 {
                    guard p.count >= 12 else { return nil }
                    let hi = Int64(p.be32(4)), lo = Int64(p.be32(8))
                    baseDecode = (hi << 32) | lo
                } else {
                    baseDecode = Int64(p.be32(4))
                }
            case "trun":
                guard p.count >= 8 else { return nil }
                let ver = p[p.startIndex]
                let flags = p.be32(0) & 0x00FF_FFFF
                let count = Int(p.be32(4))
                var o = 8
                var dataOffset: Int64 = 0
                if flags & 0x001 != 0 { guard p.count >= o + 4 else { return nil }; dataOffset = Int64(Int32(bitPattern: p.be32(o))); o += 4 }
                var firstSampleFlags: UInt32?
                if flags & 0x004 != 0 { guard p.count >= o + 4 else { return nil }; firstSampleFlags = p.be32(o); o += 4 }
                var pos = baseDataOffset + dataOffset
                var dts = baseDecode
                for i in 0..<count {
                    var dur = Int64(tfhdDefaultDur)
                    var size = Int(tfhdDefaultSize)
                    var sflags = tfhdDefaultFlags
                    var cts: Int64 = 0
                    if flags & 0x100 != 0 { guard p.count >= o + 4 else { return nil }; dur = Int64(p.be32(o)); o += 4 }
                    if flags & 0x200 != 0 { guard p.count >= o + 4 else { return nil }; size = Int(p.be32(o)); o += 4 }
                    if flags & 0x400 != 0 { guard p.count >= o + 4 else { return nil }; sflags = p.be32(o); o += 4 }
                    if flags & 0x800 != 0 {
                        guard p.count >= o + 4 else { return nil }
                        cts = ver == 0 ? Int64(p.be32(o)) : Int64(Int32(bitPattern: p.be32(o)))
                        o += 4
                    }
                    if i == 0, let f = firstSampleFlags { sflags = f }
                    guard size >= 0, pos >= 0, Int(pos) + size <= blob.count else { return nil }
                    let isSync = (sflags & 0x0001_0000) == 0
                    samples.append(FragSample(data: blob.sub(Int(pos), size), dts: dts,
                                              ctsOffset: cts, duration: dur, isSync: isSync))
                    pos += Int64(size)
                    dts += dur
                }
            default: break
            }
        }
    }
    return samples
}

// MARK: - Annex-B / ADTS conversion

private func annexB(_ sample: FragSample, nalLengthSize: Int, sps: [Data], pps: [Data]) -> Data {
    var out = Data()
    let start: [UInt8] = [0, 0, 0, 1]
    out.append(contentsOf: start); out.append(contentsOf: [0x09, 0xF0])   // access-unit delimiter
    if sample.isSync {
        for s in sps { out.append(contentsOf: start); out.append(s) }
        for p in pps { out.append(contentsOf: start); out.append(p) }
    }
    let d = sample.data
    var o = 0
    while o + nalLengthSize <= d.count {
        var len = 0
        for i in 0..<nalLengthSize { len = len << 8 | Int(d[d.startIndex + o + i]) }
        o += nalLengthSize
        guard o + len <= d.count else { break }
        out.append(contentsOf: start)
        out.append(d.sub(o, len))
        o += len
    }
    return out
}

private func adtsFrame(_ frame: Data, profile: Int, freqIndex: Int, channels: Int) -> Data {
    let len = frame.count + 7
    var h = [UInt8](repeating: 0, count: 7)
    h[0] = 0xFF
    h[1] = 0xF1  // MPEG-4, layer 0, no CRC
    let b2: Int = ((profile & 3) << 6) | ((freqIndex & 0xF) << 2) | ((channels >> 2) & 1)
    let b3: Int = ((channels & 3) << 6) | ((len >> 11) & 3)
    let b5: Int = ((len & 7) << 5) | 0x1F
    h[2] = UInt8(b2)
    h[3] = UInt8(b3)
    h[4] = UInt8((len >> 3) & 0xFF)
    h[5] = UInt8(b5)
    h[6] = 0xFC
    var out = Data(h)
    out.append(frame)
    return out
}

// MARK: - MPEG-TS writer

private let mpegCRCTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt32(i) << 24
        for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        table[i] = crc
    }
    return table
}()

private func mpegCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in data { crc = (crc << 8) ^ mpegCRCTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF] }
    return crc
}

private final class TSWriter {
    var out = Data()
    private var cc: [Int: UInt8] = [:]
    let pmtPID = 4096, videoPID = 256, audioPID = 257
    var ok = true

    private func nextCC(_ pid: Int) -> UInt8 {
        let v = cc[pid] ?? 0
        cc[pid] = (v + 1) & 0x0F
        return v
    }

    private func psi(_ pid: Int, table: Data) {
        var payload = Data([0x00])
        payload.append(table)
        let crc = mpegCRC32(table)
        payload.append(contentsOf: [UInt8(crc >> 24 & 0xFF), UInt8(crc >> 16 & 0xFF),
                                    UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        var pkt = Data([0x47, UInt8(0x40 | (pid >> 8)), UInt8(pid & 0xFF), UInt8(0x10 | nextCC(pid))])
        pkt.append(payload)
        while pkt.count < 188 { pkt.append(0xFF) }
        out.append(pkt)
    }

    func writePAT() {
        let table = Data([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0x00, 0x01, UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)])
        psi(0, table: table)
    }

    func writePMT() {
        var t = Data([0x02, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
                      UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF), 0xF0, 0x00])
        t.append(contentsOf: [0x1B, UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF), 0xF0, 0x00])
        t.append(contentsOf: [0x0F, UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF), 0xF0, 0x00])
        let sectionLen = t.count - 3 + 4
        t[t.startIndex + 2] = UInt8(sectionLen & 0xFF)
        t[t.startIndex + 1] = UInt8(0xB0 | (sectionLen >> 8))
        psi(pmtPID, table: t)
    }

    private func encodePTS(_ prefix: UInt8, _ ts: Int64) -> [UInt8] {
        let t = UInt64(bitPattern: ts) & 0x1_FFFF_FFFF
        return [
            UInt8(UInt64(prefix) << 4 | (t >> 30) << 1 | 1),
            UInt8((t >> 22) & 0xFF),
            UInt8(((t >> 14) & 0xFE) | 1),
            UInt8((t >> 7) & 0xFF),
            UInt8(((t << 1) & 0xFE) | 1),
        ]
    }

    func writePES(pid: Int, streamId: UInt8, pts: Int64, dts: Int64?, payload: Data,
                  randomAccess: Bool, pcr: Int64?) {
        var pes = Data([0x00, 0x00, 0x01, streamId])
        var hdr = Data()
        let ptsDtsFlags: UInt8 = dts != nil ? 0xC0 : 0x80
        var tsBytes = encodePTS(dts != nil ? 3 : 2, pts)
        if let d = dts { tsBytes += encodePTS(1, d) }
        hdr.append(contentsOf: [0x80, ptsDtsFlags, UInt8(tsBytes.count)])
        hdr.append(contentsOf: tsBytes)
        let pesLen = hdr.count + payload.count
        if streamId == 0xE0 || pesLen > 0xFFFF {
            pes.append(contentsOf: [0x00, 0x00])
        } else {
            pes.append(contentsOf: [UInt8(pesLen >> 8), UInt8(pesLen & 0xFF)])
        }
        pes.append(hdr)
        pes.append(payload)

        var off = 0
        var first = true
        while off < pes.count {
            var pkt = Data(capacity: 188)
            let remaining = pes.count - off
            var adaptation = Data()
            if first && (pcr != nil || randomAccess) {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                var af = Data([flags])
                if let pcrV = pcr {
                    flags |= 0x10
                    af = Data([flags])
                    let base = UInt64(bitPattern: pcrV) & 0x1_FFFF_FFFF
                    af.append(contentsOf: [
                        UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF),
                        UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF),
                        UInt8(((base & 1) << 7) | 0x7E), 0x00,
                    ])
                }
                adaptation = af
            }
            var capacity = 184 - (adaptation.isEmpty ? 0 : adaptation.count + 1)
            if remaining < capacity {
                let stuff = capacity - remaining
                if adaptation.isEmpty {
                    adaptation = Data([0x00])
                    var need = stuff - 2
                    if need < 0 {
                        pkt = Data([0x47, UInt8((first ? 0x40 : 0x00) | (pid >> 8)), UInt8(pid & 0xFF),
                                    UInt8(0x30 | nextCC(pid)), 0x00])
                        pkt.append(pes.sub(off, remaining))
                        if pkt.count != 188 { ok = false; return }
                        out.append(pkt)
                        off += remaining
                        first = false
                        continue
                    }
                    while need > 0 { adaptation.append(0xFF); need -= 1 }
                } else {
                    for _ in 0..<stuff { adaptation.append(0xFF) }
                }
                capacity = remaining
            }
            let hasAF = !adaptation.isEmpty
            pkt = Data([0x47, UInt8((first ? 0x40 : 0x00) | (pid >> 8)), UInt8(pid & 0xFF),
                        UInt8((hasAF ? 0x30 : 0x10) | nextCC(pid))])
            if hasAF {
                pkt.append(UInt8(adaptation.count))
                pkt.append(adaptation)
            }
            let n = min(capacity, remaining)
            pkt.append(pes.sub(off, n))
            if pkt.count != 188 { ok = false; return }
            out.append(pkt)
            off += n
            first = false
        }
    }
}

// MARK: - Public API

/// Parsed init-segment state for one video+audio stream pair. Opaque to callers — created by
/// RedditHLSTransmuxer.parse and passed back into muxSegment. Immutable → safe to share across
/// RedditVideoProxy's concurrent connection threads without locking.
struct RedditHLSStreamInfo {
    fileprivate let vInit: VideoInitInfo
    fileprivate let aInit: AudioInitInfo
}

final class RedditHLSTransmuxer {

    // 1s guard so DTS (= PTS - CTS offset) never goes negative on the first samples.
    private static let ptsOffset: Int64 = 90000

    // Parse both streams' init segments (the #EXT-X-MAP byte range — ftyp+moov, no sidx box
    // present at all, since Reddit's own playlist already gives every segment's byte range
    // directly — see M3U8Parser).
    static func parse(videoInitData: Data, audioInitData: Data) -> RedditHLSStreamInfo? {
        guard let vInit = parseVideoInit(videoInitData) else { return nil }
        guard let aInit = parseAudioInit(audioInitData) else { return nil }
        return RedditHLSStreamInfo(vInit: vInit, aInit: aInit)
    }

    // Transmux one segment: a video fragment blob + the INDEX-MATCHED audio fragment blob
    // (Reddit's video/audio variant playlists are confirmed to always have equal segment
    // counts — see M3U8Parser header) -> one MPEG-TS blob.
    static func muxSegment(_ info: RedditHLSStreamInfo, videoBlob: Data, audioBlob: Data) -> Data? {
        guard let vSamples = parseFragments(videoBlob, defaults: info.vInit.defaults), !vSamples.isEmpty else { return nil }
        guard let aSamples = parseFragments(audioBlob, defaults: info.aInit.defaults), !aSamples.isEmpty else { return nil }

        let w = TSWriter()
        w.writePAT()
        w.writePMT()

        struct Item { let dts90: Int64; let write: (TSWriter) -> Void }
        var items: [Item] = []
        let vts = info.vInit.timescale
        for s in vSamples {
            let dts90 = s.dts * 90000 / vts + ptsOffset
            let pts90 = (s.dts + s.ctsOffset) * 90000 / vts + ptsOffset
            let es = annexB(s, nalLengthSize: info.vInit.nalLengthSize, sps: info.vInit.sps, pps: info.vInit.pps)
            let sync = s.isSync
            items.append(Item(dts90: dts90) { tw in
                tw.writePES(pid: tw.videoPID, streamId: 0xE0, pts: pts90, dts: dts90, payload: es,
                            randomAccess: sync, pcr: dts90 - 9000)
            })
        }
        let ats = info.aInit.timescale
        for s in aSamples {
            let pts90 = s.dts * 90000 / ats + ptsOffset
            let es = adtsFrame(s.data, profile: info.aInit.aacProfile,
                               freqIndex: info.aInit.freqIndex, channels: info.aInit.channelConfig)
            items.append(Item(dts90: pts90) { tw in
                tw.writePES(pid: tw.audioPID, streamId: 0xC0, pts: pts90, dts: nil, payload: es,
                            randomAccess: false, pcr: nil)
            })
        }
        items.sort { $0.dts90 < $1.dts90 }
        for item in items { item.write(w) }
        guard w.ok else { return nil }
        return w.out
    }
}
