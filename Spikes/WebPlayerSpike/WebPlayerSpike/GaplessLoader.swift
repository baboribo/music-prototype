import AVFoundation
import Foundation

/// Serves one direct-format audio URL to AVFoundation with only its gapless information rewritten.
///
/// These fragmented MP4s mark their AAC priming with an edit list (media_time 1600). AVFoundation
/// applies that edit list *and* its default AAC priming of 2112 samples, so every track loses its
/// first 48 ms and reports about twice its length (B3.2). Here `moov` is rewritten: the `edts` box
/// becomes `free` (same size) and Apple's gapless tag `iTunSMPB` (priming, padding, sample count taken
/// from that edit list) is appended in `moov/udta`. Every byte after `moov` is passed through
/// unchanged, shifted by the added length; fragments address their data relative to their own
/// `moof` and `sidx` relative to itself, so the shift is safe. Logs carry numbers only.
@MainActor
final class GaplessLoader: NSObject {
    static let scheme = "ytm-gapless"

    struct Rewrite: Sendable {
        let head: Data          // rewritten bytes [0, moov end + delta)
        let originalHeadEnd: Int
        let delta: Int
        let originalLength: Int
        let priming: Int
        let padding: Int
        let samples: Int
        var length: Int { originalLength + delta }
    }

    enum LoaderError: Error { case http(Int), noMoov, noEditList }

    private let source: URL
    private let videoID: String
    private let onEvent: @MainActor (String, [String: Any]) -> Void
    private var rewrite: Task<Rewrite, Error>?
    private var serving: [ObjectIdentifier: Task<Void, Never>] = [:]
    private(set) var requests = 0

    init(source: URL, videoID: String, onEvent: @escaping @MainActor (String, [String: Any]) -> Void) {
        self.source = source
        self.videoID = videoID
        self.onEvent = onEvent
    }

    /// An asset that loads through this loader. The loader must be kept alive with the item
    /// (AVAssetResourceLoader holds its delegate weakly).
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://audio/\(videoID)")!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    // MARK: Serving

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let r = try await rewritten()
            if let info = request.contentInformationRequest {
                info.contentType = "public.mpeg-4"
                info.contentLength = Int64(r.length)
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else { request.finishLoading(); return }
            var offset = Int(data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource ? r.length : min(r.length, offset + data.requestedLength)
            if offset < r.head.count {
                let upTo = min(end, r.head.count)
                data.respond(with: r.head.subdata(in: offset..<upTo))
                offset = upTo
            }
            // Original bytes, shifted by the added length. Chunks keep the first bytes quick.
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
            onEvent("gaplessLoader", ["event": "error", "error": "\(error)"])
            request.finishLoading(with: error)
        }
    }

    private func rewritten() async throws -> Rewrite {
        if let rewrite { return try await rewrite.value }
        let task = Task { try await Self.makeRewrite(source) }
        rewrite = task
        let r = try await task.value
        onEvent("gaplessLoader", ["event": "rewrite", "priming": r.priming, "padding": r.padding, "samples": r.samples,
                                  "delta": r.delta, "headBytes": r.originalHeadEnd])
        return r
    }

    nonisolated private static func fetch(_ url: URL, _ range: Range<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 206 || status == 200 else { throw LoaderError.http(status) }
        return data
    }

    // MARK: Rewrite

    nonisolated static func makeRewrite(_ url: URL) async throws -> Rewrite {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (head, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw LoaderError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) } ?? head.count
        return try rewrite(head, originalLength: total)
    }

    nonisolated static func rewrite(_ original: Data, originalLength: Int) throws -> Rewrite {
        var b = Data(original)
        guard let moov = boxes(b, 0..<b.count).first(where: { $0.type == "moov" }) else { throw LoaderError.noMoov }
        guard let trak = boxes(b, moov.payload..<moov.end).first(where: { $0.type == "trak" }),
              let edts = boxes(b, trak.payload..<trak.end).first(where: { $0.type == "edts" }),
              let elst = boxes(b, edts.payload..<edts.end).first(where: { $0.type == "elst" }) else { throw LoaderError.noEditList }
        let version = Int(b[elst.payload])
        let segment = version == 1 ? u64(b, elst.payload + 8) : u32(b, elst.payload + 8)
        let mediaTime = version == 1 ? u64(b, elst.payload + 16) : u32(b, elst.payload + 12)
        // elst segment is in the movie timescale, media_time in the media timescale.
        let movieScale = boxes(b, moov.payload..<moov.end).first { $0.type == "mvhd" }.map { u32(b, $0.payload + (Int(b[$0.payload]) == 1 ? 20 : 12)) } ?? 0
        let mdia = boxes(b, trak.payload..<trak.end).first { $0.type == "mdia" }
        let mediaScale = mdia.flatMap { m in boxes(b, m.payload..<m.end).first { $0.type == "mdhd" } }
            .map { u32(b, $0.payload + (Int(b[$0.payload]) == 1 ? 20 : 12)) } ?? movieScale
        let samples = movieScale > 0 ? segment * mediaScale / movieScale : segment
        // The last AAC frame is shortened in trun to end at priming + samples; the rest of it is padding.
        let padding = (1024 - (mediaTime + samples) % 1024) % 1024

        // Retire the edit list and the old udta in place (same sizes), then append the tag.
        rename(&b, edts.start, "free")
        if let udta = boxes(b, moov.payload..<moov.end).first(where: { $0.type == "udta" }) { rename(&b, udta.start, "free") }
        let tag = smpb(priming: mediaTime, padding: padding, samples: samples)
        var head = b.subdata(in: 0..<moov.end)
        head.append(tag)
        let size = moov.end - moov.start + tag.count
        for k in 0..<4 { head[moov.start + k] = UInt8((size >> (24 - 8 * k)) & 0xff) }
        return Rewrite(head: head, originalHeadEnd: moov.end, delta: tag.count, originalLength: originalLength,
                       priming: mediaTime, padding: padding, samples: samples)
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
            if size == 1 { size = u64(b, i + 8); header = 16 } else if size == 0 { size = range.upperBound - i }
            guard size >= header, i + size <= range.upperBound else { break }
            out.append(Box(type: String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self), start: i, payload: i + header, end: i + size))
            i += size
        }
        return out
    }

    nonisolated private static func rename(_ b: inout Data, _ start: Int, _ type: String) {
        for (k, c) in type.utf8.enumerated() { b[start + 4 + k] = c }
    }
    nonisolated private static func u32(_ b: Data, _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
    nonisolated private static func u64(_ b: Data, _ i: Int) -> Int { u32(b, i) << 32 | u32(b, i + 4) }
}

// AVFoundation calls these on the queue given to `setDelegate` (main), hence the main-actor conformance.
extension GaplessLoader: @MainActor AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        requests += 1
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
