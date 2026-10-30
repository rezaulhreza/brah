import Foundation

/// The process environment, with the names from when the app was called Bruh: `BRUH_X` counts
/// as `BRAH_X` when `BRAH_X` is not set.
public enum BrahEnvironment {
    public static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        for (key, value) in environment where key.hasPrefix("BRUH_") {
            let new = "BRAH_" + key.dropFirst(5)
            if result[new] == nil {
                result[new] = value
            }
        }
        return result
    }
}
