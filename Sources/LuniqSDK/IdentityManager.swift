import Foundation
import CommonCrypto

final class IdentityManager {
    private(set) var visitorId: String?
    private(set) var accountId: String?
    private(set) var traits: [String: Any] = [:]

    private let defaults = UserDefaults(suiteName: "ai.luniq.sdk") ?? .standard
    private let kVisitor = "pulse.visitor_id"
    private let kAccount = "pulse.account_id"
    private let kTraits  = "pulse.traits"

    init() {
        visitorId = defaults.string(forKey: kVisitor)
        accountId = defaults.string(forKey: kAccount)
        traits = defaults.dictionary(forKey: kTraits) ?? [:]
    }

    func set(visitorId: String, accountId: String?, traits: [String: Any]) {
        self.visitorId = visitorId
        self.accountId = accountId
        self.traits.merge(traits) { _, new in new }
        defaults.set(visitorId, forKey: kVisitor)
        defaults.set(accountId, forKey: kAccount)
        defaults.set(self.traits, forKey: kTraits)
    }

    /// SHA-256 hash any sensitive identifier (VIN, SSN, account number, etc.)
    /// before sending it as a property. Pass a stable per-app `pepper` so hashes
    /// are not portable across products.
    static func hashIdentifier(_ value: String, pepper: String = "pulse-v1") -> String {
        let input = (value + pepper).data(using: .utf8) ?? Data()
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        input.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(input.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
