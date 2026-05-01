import Foundation
import CommonCrypto

final class IdentityManager {
    private(set) var visitorId: String?
    private(set) var accountId: String?
    private(set) var traits: [String: Any] = [:]

    private let defaults = UserDefaults(suiteName: "ai.luniq.sdk") ?? .standard
    private let kVisitor = "luniq.visitor_id"
    private let kAccount = "luniq.account_id"
    private let kTraits  = "luniq.traits"

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

    static func hashIdentifier(_ vin: String, pepper: String = "luniq-v1") -> String {
        let input = (vin + pepper).data(using: .utf8) ?? Data()
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        input.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(input.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
