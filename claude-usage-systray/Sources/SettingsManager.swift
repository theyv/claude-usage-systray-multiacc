import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings { didSet { saveSettings() } }
    @Published private(set) var accounts: [ClaudeAccount] { didSet { saveAccounts() } }

    private let defaults = UserDefaults.standard
    private let settingsKey = "ClaudeUsageSettings"
    private let accountsKey = "ClaudeUsageAccounts"
    private let ignoredCCSProfilesKey = "ClaudeUsageIgnoredCCSProfiles"
    private var ignoredCCSProfiles: Set<String>

    private init() {
        settings = (defaults.data(forKey: settingsKey)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        accounts = (defaults.data(forKey: accountsKey)).flatMap { try? JSONDecoder().decode([ClaudeAccount].self, from: $0) } ?? []
        ignoredCCSProfiles = Set(defaults.stringArray(forKey: ignoredCCSProfilesKey) ?? [])
    }

    func addAccount(name: String, token: String) throws {
        let account = ClaudeAccount(name: name.isEmpty ? "Claude account \(accounts.count + 1)" : name)
        try saveAccountToken(token, for: account.id)
        accounts.append(account)
    }

    /// Discovers CCS account lanes without copying their secrets. A profile that
    /// has not been logged in is deliberately kept: the popover can explain it
    /// needs login instead of silently disappearing.
    func importCCSProfiles() {
        let instances = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccs/instances", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(at: instances, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for directory in directories {
            let name = directory.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let credentials = directory.appendingPathComponent(".credentials.json").path
            guard !ignoredCCSProfiles.contains(credentials), !accounts.contains(where: { $0.name == name || $0.ccsCredentialsPath == credentials }) else { continue }
            accounts.append(ClaudeAccount(name: name, ccsCredentialsPath: credentials))
        }
    }

    func removeAccount(_ account: ClaudeAccount) {
        deleteAccountToken(for: account.id)
        if let ccsCredentialsPath = account.ccsCredentialsPath {
            ignoredCCSProfiles.insert(ccsCredentialsPath)
            defaults.set(Array(ignoredCCSProfiles), forKey: ignoredCCSProfilesKey)
        }
        accounts.removeAll { $0.id == account.id }
    }

    func renameAccount(_ account: ClaudeAccount, to name: String) {
        guard let index = accounts.firstIndex(of: account) else { return }
        accounts[index].name = name.isEmpty ? account.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setWarningThreshold(_ value: Double) { settings.warningThreshold = value }
    func setCriticalThreshold(_ value: Double) { settings.criticalThreshold = value }
    func setNotificationsEnabled(_ enabled: Bool) { settings.notificationsEnabled = enabled }
    func setCompactDisplay(_ enabled: Bool) { settings.compactDisplay = enabled }
    func resetToDefaults() { settings = AppSettings() }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) { defaults.set(encoded, forKey: settingsKey) }
    }

    private func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) { defaults.set(encoded, forKey: accountsKey) }
    }
}
