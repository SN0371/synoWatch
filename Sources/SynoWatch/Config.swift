import Foundation

/// Persisted configuration for SynoWatch (excluding sensitive credentials).
/// Password is stored separately in the macOS Keychain.
struct Config: Codable {
    var host: String
    var port: Int
    var useHTTPS: Bool
    var username: String
    var checkInterval: TimeInterval

    static let defaultHTTPPort = 5000
    static let defaultHTTPSPort = 5001
    static let defaultInterval: TimeInterval = 3600

    private static let userDefaultsKey = "SynoWatchConfig"

    /// Loads the saved configuration from UserDefaults, or nil if none exists.
    static func load() -> Config? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Persists this configuration to UserDefaults.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Config.userDefaultsKey)
    }
}
