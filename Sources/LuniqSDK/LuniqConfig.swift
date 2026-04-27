import Foundation

public struct LuniqConfig {
    public let apiKey: String
    public let endpoint: String
    public var environment: String
    public var autoCapture: Bool
    public var enabled: Bool
    public var batchSize: Int
    public var flushIntervalSec: TimeInterval
    public var maxQueueSize: Int
    public var redactPII: Bool

    public init(
        apiKey: String,
        endpoint: String,
        environment: String = "PRD",
        autoCapture: Bool = true,
        enabled: Bool = true,
        batchSize: Int = 50,
        flushIntervalSec: TimeInterval = 30,
        maxQueueSize: Int = 10_000,
        redactPII: Bool = true
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.environment = environment
        self.autoCapture = autoCapture
        self.enabled = enabled
        self.batchSize = batchSize
        self.flushIntervalSec = flushIntervalSec
        self.maxQueueSize = maxQueueSize
        self.redactPII = redactPII
    }
}
