import Foundation

/// Loosely-typed InnerTube payload. Renderers change shape often, so parsers
/// read by path and tolerate missing nodes instead of decoding rigid models.
enum JSON: Sendable, Hashable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(data: Data) throws {
        self = JSON(any: try JSONSerialization.jsonObject(with: data))
    }

    private init(any value: Any) {
        switch value {
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        default: self = .null
        }
    }

    var foundationValue: Any {
        switch self {
        case .object(let o): o.mapValues(\.foundationValue)
        case .array(let a): a.map(\.foundationValue)
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var array: [JSON] { if case .array(let a) = self { a } else { [] } }

    /// `{ "runs": [{ "text": … }] }` or `{ "simpleText": … }` joined.
    var text: String? {
        if let s = self["simpleText"]?.string { return s }
        let runs = self["runs"]?.array.compactMap { $0["text"]?.string } ?? []
        return runs.isEmpty ? nil : runs.joined()
    }

    /// Walks a dotted path; numeric components index arrays.
    func at(_ path: String) -> JSON? {
        var node: JSON? = self
        for part in path.split(separator: ".") {
            if let i = Int(part) { node = node?[i] } else { node = node?[String(part)] }
        }
        return node
    }

    /// Every value stored under `key`, depth-first.
    func all(_ key: String) -> [JSON] {
        var out: [JSON] = []
        func walk(_ n: JSON) {
            switch n {
            case .object(let o):
                for (k, v) in o {
                    if k == key { out.append(v) }
                    walk(v)
                }
            case .array(let a): a.forEach(walk)
            default: break
            }
        }
        walk(self)
        return out
    }

    func first(_ key: String) -> JSON? { all(key).first }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByStringLiteral {
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(stringLiteral value: String) { self = .string(value) }
}
