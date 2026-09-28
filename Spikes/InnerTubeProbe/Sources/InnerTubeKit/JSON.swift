import Foundation

/// Loosely-typed InnerTube payload. Renderers change shape often, so
/// normalizers read by path and tolerate missing nodes instead of decoding
/// into rigid Codable models.
public enum JSON: Sendable, Hashable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSON] { if case .array(let a) = self { a } else { [] } }
    public var object: [String: JSON] { if case .object(let o) = self { o } else { [:] } }
    public var keys: [String] { object.keys.sorted() }

    /// `{ "runs": [{ "text": … }] }` or `{ "simpleText": … }` joined.
    public var text: String? {
        if let s = self["simpleText"]?.string { return s }
        let runs = self["runs"]?.array.compactMap { $0["text"]?.string } ?? []
        return runs.isEmpty ? nil : runs.joined()
    }

    /// Walks a dotted path; numeric components index arrays.
    public func at(_ path: String) -> JSON? {
        var node: JSON? = self
        for part in path.split(separator: ".") {
            if let i = Int(part) { node = node?[i] } else { node = node?[String(part)] }
        }
        return node
    }

    /// Every value stored under `key`, depth-first. For exploration and for
    /// renderers whose nesting differs between clients.
    public func all(_ key: String) -> [JSON] {
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

    public func first(_ key: String) -> JSON? { all(key).first }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }

    func merging(_ other: [String: JSON]) -> JSON {
        .object(object.merging(other, uniquingKeysWith: { $1 }))
    }
}
