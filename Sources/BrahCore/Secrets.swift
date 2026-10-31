import Foundation
import Security

/// Brah's secrets in the login Keychain: generic passwords with the service "Brah".
public enum Secrets {
    public static let service = "Brah"
    /// The Hermes API key.
    public static let hermesKey = "hermes.key"
    /// The password of the Hermes dashboard, for a dashboard with a sign-in.
    public static let voicePassword = "hermes.voice.password"
    /// The Cloudflare Access service token, for a Hermes behind Cloudflare Access.
    public static let accessClientID = "cf-access.client-id"
    public static let accessClientSecret = "cf-access.client-secret"
    public static let anthropicKey = "anthropic.key"
    public static let customKey = "custom.key"

    public struct Failure: Error, CustomStringConvertible {
        public var status: OSStatus

        public var description: String {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain did not save the secret: \(text)"
        }
    }

    /// The secret, or nil when there is none or it is empty.
    public static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    /// Saves the secret. An empty text deletes it.
    public static func set(_ value: String, for account: String) throws {
        guard !value.isEmpty else { return try delete(account) }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Brah: \(account)"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    /// Removes the secret. No secret is not an error.
    public static func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// The secret lookup of the settings loaders when none is given: the Keychain, but only for
    /// the home folder of the user who runs Brah. Another home folder (a test) gets no Keychain,
    /// so a test never reads a real secret or makes macOS ask for Keychain access.
    static func lookup(_ given: ((String) -> String?)?, home: URL) -> (String) -> String? {
        if let given { return given }
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return home.standardizedFileURL == real ? { get($0) } : { _ in nil }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
