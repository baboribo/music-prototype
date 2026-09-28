import Foundation

/// Strips signed media URLs and session identifiers before anything is
/// printed or written. Public artwork URLs are kept.
public enum Redactor {
    static let mediaKeys: Set<String> = ["url", "hlsManifestUrl", "dashManifestUrl", "serverAbrStreamingUrl", "signatureCipher", "cipher"]
    static let droppedKeys: Set<String> = [
        "visitorData", "trackingParams", "clickTrackingParams", "serializedShareEntity",
        "attestation", "botguardData", "adPlacements", "playerAds", "heartbeatParams",
        "adSlots", "playbackTracking", "ptrackingUrl", "qoeUrl",
        "datasyncId", "delegatedSessionId", "sessionId", "accountName", "email", "channelHandle",
        "onBehalfOfUser", "accountPhoto", "sessionIndex",
    ]

    public static func redact(_ json: JSON) -> JSON {
        switch json {
        case .object(let o):
            var out: [String: JSON] = [:]
            for (k, v) in o {
                if droppedKeys.contains(k) { out[k] = "<redacted>"; continue }
                if mediaKeys.contains(k), let s = v.string, isMedia(s) { out[k] = .string(describe(s)); continue }
                out[k] = redact(v)
            }
            return .object(out)
        case .array(let a): return .array(a.map(redact))
        default: return json
        }
    }

    static func isMedia(_ s: String) -> Bool {
        s.contains("googlevideo.com") || s.contains("manifest") || s.hasPrefix("s=") || s.contains("&sp=") || s.contains("url=")
    }

    /// `https://host/path?{keys}` with every value removed.
    public static func describe(_ s: String) -> String {
        if !s.hasPrefix("http") {
            let keys = s.split(separator: "&").compactMap { $0.split(separator: "=").first }.map(String.init)
            return "<cipher keys=\(keys.joined(separator: ","))>"
        }
        guard let c = URLComponents(string: s) else { return "<url>" }
        let keys = (c.queryItems ?? []).map(\.name)
        let host = c.host.map { $0.replacingOccurrences(of: #"^[^.]+\."#, with: "*.", options: .regularExpression) } ?? "?"
        return "<\(host)\(c.path.count > 40 ? String(c.path.prefix(40)) + "…" : c.path) keys=\(keys.joined(separator: ","))>"
    }
}
