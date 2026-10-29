import Foundation

/// A Hermes on a server can be behind Cloudflare Access. Bruh then sends a service token (a
/// client ID and a client secret) as two headers to the API server and to the dashboard.
public enum CloudflareAccess {
    public static let idHeader = "CF-Access-Client-Id"
    public static let secretHeader = "CF-Access-Client-Secret"

    /// The two headers when both values are set, else none. The environment
    /// (`BRUH_CF_ACCESS_CLIENT_ID`, `BRUH_CF_ACCESS_CLIENT_SECRET`) wins over the Keychain.
    public static func headers(environment: [String: String], secret: (String) -> String?) -> [String: String] {
        func value(_ variable: String, _ account: String) -> String? {
            let text = (environment[variable] ?? secret(account))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let id = value("BRUH_CF_ACCESS_CLIENT_ID", Secrets.accessClientID),
              let secret = value("BRUH_CF_ACCESS_CLIENT_SECRET", Secrets.accessClientSecret)
        else { return [:] }
        return [idHeader: id, secretHeader: secret]
    }

    /// True for an address on this Mac: 127.0.0.1, localhost or ::1.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}
