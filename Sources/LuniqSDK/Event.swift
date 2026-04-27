import Foundation

struct Event: Codable {
    let id: String
    let name: String
    let properties: [String: AnyCodable]
    let timestamp: Date
    let sessionId: String
    let visitorId: String?
    let accountId: String?

    init(name: String, properties: [String: Any], timestamp: Date, sessionId: String, visitorId: String?, accountId: String?) {
        self.id = UUID().uuidString
        self.name = name
        self.properties = properties.mapValues { AnyCodable($0) }
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.visitorId = visitorId
        self.accountId = accountId
    }
}

public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value }; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value }; return }
        value = NSNull()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}
