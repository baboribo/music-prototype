import AVFoundation
import Foundation

/// Gapless boundary analysis for two consecutive album tracks (itag 141, fragmented MP4 / AAC-LC).
/// Decodes each file to PCM from its own sample tables, applies the edit list (priming at the start,
/// segment length at the end), and compares the join with what AVFoundation outputs and with the
/// service duration used as `forwardPlaybackEndTime`. Prints numbers only; the media bytes live in
/// memory and in one temporary file (for AVAssetReader) that is deleted right after reading.
public enum PCMBoundary {
    public struct Track: Sendable {
        public var timescale = 0
        public var mdhdDuration = 0
        public var elstSegment = 0
        public var elstMediaTime = 0
        public var asc = Data([0x12, 0x10])
        public var frames: [Data] = []
        public var frameDurations: [Int] = []
        public var sidxTotal = 0
        public var total: Int { frameDurations.reduce(0, +) }
    }

    // MARK: Container

    static func u32(_ b: Data, _ i: Int) -> Int { Int(b[b.startIndex + i]) << 24 | Int(b[b.startIndex + i + 1]) << 16 | Int(b[b.startIndex + i + 2]) << 8 | Int(b[b.startIndex + i + 3]) }
    static func u64(_ b: Data, _ i: Int) -> Int { u32(b, i) << 32 | u32(b, i + 4) }

    /// Child boxes within `range` of `b`: (type, box start, payload start, end).
    static func boxes(_ b: Data, _ range: Range<Int>) -> [(String, Int, Int, Int)] {
        var out: [(String, Int, Int, Int)] = []
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = u32(b, i)
            var header = 8
            if size == 1 { size = u64(b, i + 8); header = 16 } else if size == 0 { size = range.upperBound - i }
            guard size >= header, i + size <= range.upperBound else { break }
            let type = String(decoding: b[(b.startIndex + i + 4)..<(b.startIndex + i + 8)], as: UTF8.self)
            out.append((type, i, i + header, i + size))
            i += size
        }
        return out
    }

    public static func parse(_ b: Data) -> Track {
        var t = Track()
        func child(_ type: String, _ r: Range<Int>) -> (Int, Int)? { boxes(b, r).first { $0.0 == type }.map { ($0.2, $0.3) } }
        for (type, start, payload, end) in boxes(b, 0..<b.count) {
            switch type {
            case "moov":
                guard let trak = child("trak", payload..<end) else { continue }
                if let edts = child("edts", trak.0..<trak.1), let elst = child("elst", edts.0..<edts.1) {
                    let version = Int(b[b.startIndex + elst.0])
                    t.elstSegment = version == 1 ? u64(b, elst.0 + 8) : u32(b, elst.0 + 8)
                    t.elstMediaTime = version == 1 ? u64(b, elst.0 + 16) : u32(b, elst.0 + 12)
                }
                if let mdia = child("mdia", trak.0..<trak.1) {
                    if let mdhd = child("mdhd", mdia.0..<mdia.1) {
                        let version = Int(b[b.startIndex + mdhd.0])
                        t.timescale = u32(b, mdhd.0 + (version == 1 ? 20 : 12))
                        t.mdhdDuration = version == 1 ? u64(b, mdhd.0 + 24) : u32(b, mdhd.0 + 16)
                    }
                    if let minf = child("minf", mdia.0..<mdia.1), let stbl = child("stbl", minf.0..<minf.1),
                       let stsd = child("stsd", stbl.0..<stbl.1), let mp4a = child("mp4a", (stsd.0 + 8)..<stsd.1),
                       let esds = child("esds", (mp4a.0 + 28)..<mp4a.1) {
                        // DecoderSpecificInfo (tag 5) holds the AudioSpecificConfig.
                        let body = b[(b.startIndex + esds.0 + 4)..<(b.startIndex + esds.1)]
                        if let tag = body.firstIndex(of: 0x05) {
                            var i = tag + 1, length = 0
                            while i < body.endIndex { let v = Int(body[i]); length = length << 7 | (v & 0x7f); i += 1; if v & 0x80 == 0 { break } }
                            if length > 0, i + length <= body.endIndex { t.asc = Data(body[i..<(i + length)]) }
                        }
                    }
                }
            case "sidx":
                let version = Int(b[b.startIndex + payload])
                let refsAt = payload + (version == 0 ? 20 : 28)
                let count = u32(b, refsAt) & 0xffff
                for r in 0..<count { t.sidxTotal += u32(b, refsAt + 4 + r * 12 + 4) }
            case "moof":
                guard let traf = child("traf", payload..<end), let tfhd = child("tfhd", traf.0..<traf.1),
                      let trun = child("trun", traf.0..<traf.1) else { continue }
                let hflags = u32(b, tfhd.0) & 0xffffff
                var o = tfhd.0 + 8
                var base = start  // default-base-is-moof
                if hflags & 0x1 != 0 { base = u64(b, o); o += 8 }
                if hflags & 0x2 != 0 { o += 4 }
                var defaultDuration = 1024, defaultSize = 0
                if hflags & 0x8 != 0 { defaultDuration = u32(b, o); o += 4 }
                if hflags & 0x10 != 0 { defaultSize = u32(b, o); o += 4 }
                let flags = u32(b, trun.0) & 0xffffff
                let count = u32(b, trun.0 + 4)
                var p = trun.0 + 8
                var offset = 0
                if flags & 0x1 != 0 { offset = Int(Int32(truncatingIfNeeded: u32(b, p))); p += 4 }
                if flags & 0x4 != 0 { p += 4 }
                var at = base + offset
                for _ in 0..<count {
                    var duration = defaultDuration, size = defaultSize
                    if flags & 0x100 != 0 { duration = u32(b, p); p += 4 }
                    if flags & 0x200 != 0 { size = u32(b, p); p += 4 }
                    if flags & 0x400 != 0 { p += 4 }
                    if flags & 0x800 != 0 { p += 4 }
                    t.frames.append(b[(b.startIndex + at)..<(b.startIndex + at + size)])
                    t.frameDurations.append(duration)
                    at += size
                }
            default: break
            }
        }
        return t
    }

    // MARK: Decode

    /// Every AAC frame decoded in order; channel 0 and 1 as Float arrays (no trimming).
    public static func decode(_ t: Track) throws -> [[Float]] {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(t.timescale), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(standardFormatWithSampleRate: Double(t.timescale), channels: 2),
              let converter = AVAudioConverter(from: input, to: output) else { throw CocoaError(.featureUnsupported) }
        converter.magicCookie = t.asc
        let maxSize = t.frames.map(\.count).max() ?? 0
        let packets = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(t.frames.count), maximumPacketSize: maxSize)
        var offset = 0
        for (i, frame) in t.frames.enumerated() {
            frame.withUnsafeBytes { raw in (packets.data + offset).copyMemory(from: raw.baseAddress!, byteCount: frame.count) }
            packets.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
            offset += frame.count
        }
        packets.packetCount = AVAudioPacketCount(t.frames.count)
        packets.byteLength = UInt32(offset)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(t.frames.count * 1024 + 4096)) else { throw CocoaError(.featureUnsupported) }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, state in
            if fed { state.pointee = .endOfStream; return nil }
            fed = true
            state.pointee = .haveData
            return packets
        }
        if status == .error { throw error ?? CocoaError(.featureUnsupported) }
        let n = Int(pcm.frameLength)
        return (0..<2).map { c in Array(UnsafeBufferPointer(start: pcm.floatChannelData![c], count: n)) }
    }

    /// What AVFoundation's own reader outputs for the file (its trimming, not ours).
    public static func readerPCM(_ file: URL) async throws -> [[Float]] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [[], []] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2,
        ])
        let provider = reader.outputProvider(for: out)
        try reader.start()
        var l: [Float] = [], r: [Float] = []
        while let ready = try await provider.next() {
            guard case .dataBuffer(let block) = ready.content else { continue }
            let data = block.withUnsafeBlockBuffer { buffer -> [Float] in
                let length = CMBlockBufferGetDataLength(buffer)
                var data = [Float](repeating: 0, count: length / 4)
                _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                return data
            }
            for i in stride(from: 0, to: data.count - 1, by: 2) { l.append(data[i]); r.append(data[i + 1]) }
        }
        return [l, r]
    }

    /// How AVFoundation maps the file: asset/track durations and edit segments (seconds and samples).
    public static func timeline(_ file: URL, timescale: Int) async throws -> [String] {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return ["no track"] }
        let (range, segments) = try await track.load(.timeRange, .segments)
        func smp(_ t: CMTime) -> String { t.isNumeric ? "\(Int((t.seconds * Double(timescale)).rounded()))" : "?" }
        var out = ["  AVAsset duration \(smp(duration)) samples; track timeRange start \(smp(range.start)) duration \(smp(range.duration))"]
        for seg in segments {
            let m = seg.timeMapping
            out.append("    segment source start \(smp(m.source.start)) dur \(smp(m.source.duration)) → target start \(smp(m.target.start)) dur \(smp(m.target.duration))\(seg.isEmpty ? " (empty)" : "")")
        }
        return out
    }

    /// Test copies with the edit list changed in place (media_time rewritten, or `edts` renamed to `free`).
    public static func patched(_ b: Data, mediaTime: Int?) -> Data {
        var d = b
        guard let moov = boxes(d, 0..<d.count).first(where: { $0.0 == "moov" }),
              let trak = boxes(d, moov.2..<moov.3).first(where: { $0.0 == "trak" }),
              let edts = boxes(d, trak.2..<trak.3).first(where: { $0.0 == "edts" }),
              let elst = boxes(d, edts.2..<edts.3).first(where: { $0.0 == "elst" }) else { return d }
        if let mediaTime {
            let at = elst.2 + 12  // version 0: flags(4) count(4) segment(4) media_time(4)
            for k in 0..<4 { d[d.startIndex + at + k] = UInt8((mediaTime >> (24 - 8 * k)) & 0xff) }
        } else {
            for (k, c) in "free".utf8.enumerated() { d[d.startIndex + edts.1 + 4 + k] = c }
        }
        return d
    }

    /// Test copy with Apple's gapless tag (`iTunSMPB`: priming, padding, sample count) in moov/udta/meta/ilst,
    /// replacing the existing udta. Fragments address data relative to their moof, so growing moov is safe.
    public static func withSMPB(_ b: Data, priming: Int, padding: Int, samples: Int) -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var d = Data(); let n = payload.count + 8
            d.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            d.append(contentsOf: Array(type.utf8)); d.append(payload); return d
        }
        let text = String(format: " 00000000 %08X %08X %016llX 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000", priming, padding, UInt64(samples))
        let mean = box("mean", Data([0, 0, 0, 0]) + Data("com.apple.iTunes".utf8))
        let name = box("name", Data([0, 0, 0, 0]) + Data("iTunSMPB".utf8))
        let data = box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(text.utf8))
        let ilst = box("ilst", box("----", mean + name + data))
        let hdlr = box("hdlr", Data(count: 8) + Data("mdirappl".utf8) + Data(count: 9))
        let udta = box("udta", box("meta", Data(count: 4) + hdlr + ilst))
        var d = b
        guard let moov = boxes(d, 0..<d.count).first(where: { $0.0 == "moov" }) else { return d }
        if let old = boxes(d, moov.2..<moov.3).first(where: { $0.0 == "udta" }) {
            for (k, c) in "free".utf8.enumerated() { d[d.startIndex + old.1 + 4 + k] = c }
        }
        d.insert(contentsOf: udta, at: d.startIndex + moov.3)
        let size = moov.3 - moov.1 + udta.count
        for k in 0..<4 { d[d.startIndex + moov.1 + k] = UInt8((size >> (24 - 8 * k)) & 0xff) }
        return d
    }

    // MARK: Measures

    /// Offset of `needle` (first `count` samples) inside `hay`, searched over `lags`; returns (lag, mean abs error).
    static func align(_ hay: [Float], _ needle: [Float], lags: ClosedRange<Int>, count: Int = 4096, from: Int = 0) -> (Int, Double) {
        var best = (0, Double.infinity)
        for lag in lags where lag + from >= 0 && lag + from + count <= hay.count && from + count <= needle.count {
            var e = 0.0
            for i in 0..<count { e += Double(abs(hay[lag + from + i] - needle[from + i])) }
            if e / Double(count) < best.1 { best = (lag, e / Double(count)) }
        }
        return best
    }

    public static func alignStart(_ raw: [Float], _ reader: [Float]) -> (Int, Double) { align(raw, reader, lags: -2200...8200) }

    /// Second-order prediction residual of each sample from the two before it.
    static func residual(_ x: [Float], _ i: Int) -> Double { Double(abs(x[i] - (2 * x[i - 1] - x[i - 2]))) }

    /// Join `a[..<aEnd]` + `b[bStart...]`: residuals at the two first B samples vs the local residual
    /// distribution (median and 99th percentile over 512 samples on each side). Ratio ≫ 1 = step/click.
    static func join(_ a: [[Float]], _ aEnd: Int, _ b: [[Float]], _ bStart: Int) -> (ratio: Double, p99ratio: Double, step: Double, level: Double) {
        var worst = 0.0, worstP99 = 0.0, step = 0.0, level = 0.0
        for c in 0..<2 {
            let x = Array(a[c][max(0, aEnd - 514)..<aEnd]) + Array(b[c][bStart..<min(b[c].count, bStart + 514)])
            let j = min(514, aEnd)
            var local = (2..<x.count).filter { $0 != j && $0 != j + 1 }.map { residual(x, $0) }.sorted()
            if local.isEmpty { local = [1] }
            let median = max(local[local.count / 2], 1e-6), p99 = max(local[Int(Double(local.count) * 0.99)], 1e-6)
            let r = max(residual(x, j), residual(x, j + 1))
            worst = max(worst, r / median); worstP99 = max(worstP99, r / p99)
            step = max(step, Double(abs(x[j] - x[j - 1])))
            level = max(level, Double(x[(j - 64)..<(j + 64)].map { abs($0) }.max() ?? 0))
        }
        return (worst, worstP99, step, level)
    }

    static func f(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }

    public static func report(_ a: Track, _ b: Track, pcmA: [[Float]], pcmB: [[Float]], readerA: [[Float]], readerB: [[Float]],
                              serviceMsA: Int?, serviceMsB: Int?, label: String) -> [String] {
        var out: [String] = []
        for (name, t, pcm, reader, service) in [("A", a, pcmA, readerA, serviceMsA), ("B", b, pcmB, readerB, serviceMsB)] {
            let padding = t.frames.count * 1024 - t.elstMediaTime - t.elstSegment  // last frame shortened in trun
            out.append("\(name): timescale \(t.timescale) frames \(t.frames.count) total \(t.total) decoded \(pcm[0].count) | mdhd \(t.mdhdDuration) sidx \(t.sidxTotal) | elst media_time(priming) \(t.elstMediaTime) segment \(t.elstSegment) → padding \(padding)")
            // Where AVFoundation's reader output sits in the raw decode.
            let head = align(pcm[0], reader[0], lags: -2200...4200)
            let startInRaw = head.0
            let tailFrom = max(0, reader[0].count - 4096)
            let tail = align(pcm[0], reader[0], lags: (startInRaw - 64)...(startInRaw + 64), from: tailFrom)
            out.append("  reader: \(reader[0].count) samples, starts at raw \(startInRaw) (err \(f(head.1, 6))), tail aligned at raw offset \(tail.0) (err \(f(tail.1, 6))), ends at raw \(tail.0 + reader[0].count) vs elst end \(t.elstMediaTime + t.elstSegment)")
            if let service {
                let cut = Int((Double(service) / 1000 * Double(t.timescale)).rounded())
                out.append("  service \(service) ms = \(cut) samples; as forwardPlaybackEndTime from presentation start → raw \(t.elstMediaTime + cut), i.e. \(cut - t.elstSegment) samples vs elst end (\(f(Double(cut - t.elstSegment) / Double(t.timescale) * 1000, 2)) ms)")
            }
            let silentHead = pcm[0].prefix(t.elstMediaTime).map { abs($0) }.max() ?? 0
            let tailRange = (t.elstMediaTime + t.elstSegment)..<pcm[0].count
            let tailPeak = tailRange.isEmpty ? 0 : (pcm[0][tailRange].map { abs($0) }.max() ?? 0)
            out.append("  peak |x| in priming \(f(Double(silentHead), 4)), in padding \(f(Double(tailPeak), 4))")
        }
        let aEnd = a.elstMediaTime + a.elstSegment
        let bStart = b.elstMediaTime
        func line(_ name: String, _ aE: Int, _ bS: Int) {
            guard aE > 520, aE <= pcmA[0].count, bS >= 0, bS + 520 < pcmB[0].count else { out.append("  \(name): out of range"); return }
            let j = join(pcmA, aE, pcmB, bS)
            out.append("  \(name): A..\(aE) + B \(bS)..  residual/median \(f(j.ratio, 1)), residual/p99 \(f(j.p99ratio, 2)), |step| \(f(j.step, 4)), local peak \(f(j.level, 3))")
        }
        out.append("join \(label):")
        line("elst exact (priming+padding trimmed)", aEnd, bStart)
        line("no trims (raw end + raw start)", pcmA[0].count, 0)
        line("A padding kept, B primed", min(a.total, pcmA[0].count), bStart)
        line("A elst end, B priming kept", aEnd, 0)
        if let s = serviceMsA {
            let cut = Int((Double(s) / 1000 * Double(a.timescale)).rounded())
            line("A cut at service duration, B elst start", a.elstMediaTime + cut, bStart)
        }
        // AVFoundation's reader output joined as is: A's reader end + B's reader start (2112 later than elst).
        let readerStartB = align(pcmB[0], readerB[0], lags: -2200...4200).0
        line("AVFoundation reader A end + reader B start", aEnd, readerStartB)
        // Where would the smoothest join be? Scan A's end ±2048 with B fixed at its elst start.
        var scan: [(Int, Double)] = []
        for d in -2048...2048 where aEnd + d > 520 && aEnd + d <= pcmA[0].count {
            scan.append((d, join(pcmA, aEnd + d, pcmB, bStart).p99ratio))
        }
        scan.sort { $0.1 < $1.1 }
        let exact = scan.first { $0.0 == 0 }?.1 ?? .nan
        let rank = scan.firstIndex { $0.0 == 0 } ?? -1
        out.append("  scan A end ±2048 (B at elst start): elst exact ranks \(rank + 1)/\(scan.count) (p99 ratio \(f(exact, 2))); best offsets \(scan.prefix(5).map { "\($0.0):\(f($0.1, 2))" }.joined(separator: " "))")
        return out
    }
}
