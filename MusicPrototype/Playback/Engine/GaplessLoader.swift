import AVFoundation
import Foundation

/// Serves one direct-format audio URL to AVFoundation with only its gapless information rewritten.
///
/// These fragmented MP4s mark their AAC priming with an edit list (media_time 1600). AVFoundation
/// applies that edit list *and* its default AAC priming of 2112 samples, so each track loses its
/// first 48 ms (an audible click between continuous album tracks) and reports about twice its
/// length. Here `moov` is rewritten: `edts` becomes `free` (same size) and Apple's gapless tag
/// `iTunSMPB` (priming, padding, sample count from that edit list) is appended in `moov/udta`.
/// Every byte after `moov` passes through unchanged, shifted by the added length (fragments
/// address data relative to their `moof`, `sidx` relative to itself). Verified on iPhone (B3.3).
///
/// Only the verified layout is rewritten; `inspect` reports anything else as unsupported so the
/// caller plays the URL directly instead.
@MainActor
final class GaplessLoader: NSObject {
    static let scheme = "ytm-gapless"

    /// The rewritten head and how the rest maps onto the original.
    struct Rewrite: Sendable {
        let head: Data
        let delta: Int
        let originalLength: Int
        let priming: Int
        let padding: Int
        let samples: Int
        let timescale: Int
        var length: Int { originalLength + delta }
        /// The exact presented length.
        var duration: Double { Double(samples) / Double(timescale) }
    }

    enum Inspection: Sendable {
        case supported(Rewrite)
        case unsupported(String)
    }

    private let source: URL
    private let videoID: String
    private let rewrite: Rewrite
    private var serving: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(source: URL, videoID: String, rewrite: Rewrite) {
        self.source = source
        self.videoID = videoID
        self.rewrite = rewrite
    }

    /// An asset that loads through this loader. Keep the loader alive as long as the item
    /// (AVAssetResourceLoader holds its delegate weakly).
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://audio/\(videoID)")!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    // MARK: Serving

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        let r = rewrite
        if let info = request.contentInformationRequest {
            info.contentType = "public.mpeg-4"
            info.contentLength = Int64(r.length)
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { request.finishLoading(); return }
        do {
            var offset = Int(data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource ? r.length : min(r.length, offset + data.requestedLength)
            if offset < r.head.count {
                let upTo = min(end, r.head.count)
                data.respond(with: r.head.subdata(in: offset..<upTo))
                offset = upTo
            }
            // Original bytes, shifted by the added length. A small first chunk keeps the start quick.
            var chunk = 256 * 1024
            while offset < end {
                try Task.checkCancellation()
                let upTo = min(end, offset + chunk)
                let bytes = try await Self.fetch(source, (offset - r.delta)..<(upTo - r.delta))
                guard !request.isCancelled else { return }
                if bytes.isEmpty { break }
                data.respond(with: bytes)
                offset += bytes.count
                chunk = 1024 * 1024
            }
            request.finishLoading()
        } catch {
            guard !request.isCancelled else { return }
            request.finishLoading(with: error)
        }
    }

    nonisolated private static func fetch(_ url: URL, _ range: Range<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 206 || status == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: Inspection and rewrite

    /// Reads the file's head and decides whether it has exactly the verified layout.
    nonisolated static func inspect(_ url: URL, itag: Int) async -> Inspection {
        // Only itag 141 was verified by ear and by PCM analysis.
        guard itag == 141 else { return .unsupported("itag \(itag)") }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        guard let (head, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 206,
              let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int($0) })
        else { return .unsupported("head unavailable") }
        return inspect(head: head, originalLength: total)
    }

    nonisolated static func inspect(head original: Data, originalLength: Int) -> Inspection {
        let b = Data(original)
        let top = boxes(b, 0..<b.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { return .unsupported("moov beyond head") }
        let traks = boxes(b, moov.payload..<moov.end).filter { $0.type == "trak" }
        guard traks.count == 1, let trak = traks.first else { return .unsupported("tracks \(traks.count)") }
        guard let edts = child(b, trak, "edts"), let elst = child(b, edts, "elst") else { return .unsupported("no edit list") }
        let version = Int(b[elst.payload])
        let entries = u32(b, elst.payload + 4)
        guard entries == 1 else { return .unsupported("edit list entries \(entries)") }
        let segment = version == 1 ? u64(b, elst.payload + 8) : u32(b, elst.payload + 8)
        let mediaTimeRaw = version == 1 ? u64(b, elst.payload + 16) : u32(b, elst.payload + 12)
        // A negative (empty) edit reads as a huge unsigned value.
        guard mediaTimeRaw > 0, mediaTimeRaw < 1 << 20 else { return .unsupported("edit media_time") }
        guard let mvhd = child(b, moov, "mvhd"), let mdia = child(b, trak, "mdia"), let mdhd = child(b, mdia, "mdhd"),
              let minf = child(b, mdia, "minf"), let stbl = child(b, minf, "stbl"), let stsd = child(b, stbl, "stsd"),
              boxes(b, (stsd.payload + 8)..<stsd.end).first?.type == "mp4a"
        else { return .unsupported("not AAC in MP4") }
        let movieScale = timescale(b, mvhd), mediaScale = timescale(b, mdhd)
        let mdhdDuration = Int(b[mdhd.payload]) == 1 ? u64(b, mdhd.payload + 24) : u32(b, mdhd.payload + 16)
        guard movieScale > 0, mediaScale > 0 else { return .unsupported("timescale") }
        let samples = segment * mediaScale / movieScale
        // The verified encoding: mdhd, the edit segment and the sidx total all equal the presented
        // length, and the last frame is shortened in trun (padding = the rest of that frame).
        guard mdhdDuration == samples,
              let sidx = top.first(where: { $0.type == "sidx" }), sidxTotal(b, sidx) == samples
        else { return .unsupported("unverified duration layout") }
        let padding = (1024 - (mediaTimeRaw + samples) % 1024) % 1024

        var rewritten = b
        rename(&rewritten, edts.start, "free")
        if let udta = boxes(b, moov.payload..<moov.end).first(where: { $0.type == "udta" }) { rename(&rewritten, udta.start, "free") }
        let tag = smpb(priming: mediaTimeRaw, padding: padding, samples: samples)
        var head = rewritten.subdata(in: 0..<moov.end)
        head.append(tag)
        let size = moov.end - moov.start + tag.count
        for k in 0..<4 { head[moov.start + k] = UInt8((size >> (24 - 8 * k)) & 0xff) }
        return .supported(Rewrite(head: head, delta: tag.count, originalLength: originalLength,
                                  priming: mediaTimeRaw, padding: padding, samples: samples, timescale: mediaScale))
    }

    /// moov/udta/meta/ilst/---- (com.apple.iTunes, iTunSMPB) with the priming, padding and sample count.
    nonisolated static func smpb(priming: Int, padding: Int, samples: Int) -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            let n = payload.count + 8
            return Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) + Data(type.utf8) + payload
        }
        let text = String(format: " 00000000 %08X %08X %016llX", priming, padding, UInt64(samples))
            + String(repeating: " 00000000", count: 8)
        let item = box("----", box("mean", Data(count: 4) + Data("com.apple.iTunes".utf8))
                              + box("name", Data(count: 4) + Data("iTunSMPB".utf8))
                              + box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(text.utf8)))
        let hdlr = box("hdlr", Data(count: 8) + Data("mdirappl".utf8) + Data(count: 9))
        return box("udta", box("meta", Data(count: 4) + hdlr + box("ilst", item)))
    }

    private struct Box { let type: String; let start: Int; let payload: Int; let end: Int }

    nonisolated private static func boxes(_ b: Data, _ range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = u32(b, i), header = 8
            if size == 1 {
                guard i + 16 <= range.upperBound else { break }
                size = u64(b, i + 8); header = 16
            } else if size == 0 { size = range.upperBound - i }
            guard size >= header, i + size <= range.upperBound else { break }
            out.append(Box(type: String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self), start: i, payload: i + header, end: i + size))
            i += size
        }
        return out
    }

    nonisolated private static func child(_ b: Data, _ parent: Box, _ type: String) -> Box? {
        boxes(b, parent.payload..<parent.end).first { $0.type == type }
    }

    nonisolated private static func timescale(_ b: Data, _ box: Box) -> Int {
        u32(b, box.payload + (Int(b[box.payload]) == 1 ? 20 : 12))
    }

    nonisolated private static func sidxTotal(_ b: Data, _ sidx: Box) -> Int {
        let version = Int(b[sidx.payload])
        let refsAt = sidx.payload + (version == 0 ? 20 : 28)
        guard refsAt + 4 <= sidx.end else { return -1 }
        let count = u32(b, refsAt) & 0xffff
        guard refsAt + 4 + count * 12 <= sidx.end else { return -1 }
        return (0..<count).reduce(0) { $0 + u32(b, refsAt + 4 + $1 * 12 + 4) }
    }

    nonisolated private static func rename(_ b: inout Data, _ start: Int, _ type: String) {
        for (k, c) in type.utf8.enumerated() { b[start + 4 + k] = c }
    }
    nonisolated private static func u32(_ b: Data, _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
    nonisolated private static func u64(_ b: Data, _ i: Int) -> Int { u32(b, i) << 32 | u32(b, i + 4) }
}

// AVFoundation calls these on the queue given to `setDelegate` (main).
extension GaplessLoader: @MainActor AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let id = ObjectIdentifier(loadingRequest)
        serving[id] = Task {
            await serve(loadingRequest)
            serving[id] = nil
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        serving.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }
}
