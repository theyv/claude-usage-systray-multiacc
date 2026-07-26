import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings { didSet { saveSettings() } }
    @Published private(set) var accounts: [ClaudeAccount] { didSet { saveAccounts() } }

    private let defaults = UserDefaults.standard
    private let settingsKey = "ClaudeUsageSettings"
    private let accountsKey = "ClaudeUsageAccounts"
    private let ignoredCCSProfilesKey = "ClaudeUsageIgnoredCCSProfiles"
    private let didRepairSharedIdentitiesKey = "ClaudeUsageDidRepairSharedWebIdentities"
    private var ignoredCCSProfiles: Set<String>

    private init() {
        settings = (defaults.data(forKey: settingsKey)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        let storedAccounts = (defaults.data(forKey: accountsKey)).flatMap { try? JSONDecoder().decode([ClaudeAccount].self, from: $0) } ?? []
        if defaults.bool(forKey: didRepairSharedIdentitiesKey) {
            accounts = storedAccounts
        } else {
            // Identities recorded by a shared-cookie build cannot be trusted.
            accounts = ClaudeWebIdentity.clearingDuplicateIdentities(in: storedAccounts)
            defaults.set(true, forKey: didRepairSharedIdentitiesKey)
        }
        ignoredCCSProfiles = Set(defaults.stringArray(forKey: ignoredCCSProfilesKey) ?? [])
        // Assignments made during init skip the observer that persists them.
        if accounts != storedAccounts { saveAccounts() }
    }

    func addAccount(name: String, token: String) throws {
        let account = ClaudeAccount(name: name.isEmpty ? "Claude account \(accounts.count + 1)" : name)
        try saveAccountToken(token, for: account.id)
        accounts.append(account)
    }

    func createClaudeCodeLoginProfile(name: String) throws -> ClaudeAccount {
        let account = ClaudeAccount(name: name.isEmpty ? "Claude account \(accounts.count + 1)" : name)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageSystray/Profiles/\(account.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storedAccount = ClaudeAccount(id: account.id, name: account.name, ccsCredentialsPath: directory.appendingPathComponent(".credentials.json").path)
        accounts.append(storedAccount)
        return storedAccount
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

    /// Imports the normal Claude Code login for people who do not use CCS.
    /// Claude Code keeps its OAuth token in the Keychain associated with this
    /// configuration directory, so no secret is copied into preferences.
    func importCurrentClaudeCodeLogin() {
        let configDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let credentials = configDirectory.appendingPathComponent(".credentials.json").path
        guard !accounts.contains(where: { $0.ccsCredentialsPath == credentials }) else { return }
        accounts.append(ClaudeAccount(name: "Claude Code account \(accounts.count + 1)", ccsCredentialsPath: credentials))
    }

    func removeAccount(_ account: ClaudeAccount) {
        deleteAccountToken(for: account.id)
        deleteWebSessionKey(for: account.id)
        Task { @MainActor in await ClaudeWebProfileStore.forget(account.id) }
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

    /// A confirmed identity is required: without it two profiles could hold the
    /// same login and report the same usage, which is exactly what the
    /// fingerprint exists to prevent.
    func connectWebSession(
        _ account: ClaudeAccount,
        sessionKey: String,
        organizationID: String,
        accountFingerprint: String
    ) throws {
        guard let index = accounts.firstIndex(of: account) else { return }
        if let duplicate = ClaudeWebIdentity.conflictingAccountName(
            for: accountFingerprint,
            in: accounts,
            excluding: account.id
        ) {
            throw ClaudeWebSessionError.alreadyConnected(duplicate)
        }
        try saveWebSessionKey(sessionKey, for: account.id)
        accounts[index].webOrganizationID = organizationID
        accounts[index].webAccountFingerprint = accountFingerprint
    }

    /// Records which Claude.ai login a profile refreshes. Returns the name of the
    /// profile that already owns that login, if any, so the caller can report it
    /// instead of letting two profiles quietly share one account.
    func claimWebAccountIdentity(_ fingerprint: String, for accountID: UUID) -> String? {
        if let conflict = ClaudeWebIdentity.conflictingAccountName(
            for: fingerprint,
            in: accounts,
            excluding: accountID
        ) {
            return conflict
        }
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].webAccountFingerprint != fingerprint else { return nil }
        accounts[index].webAccountFingerprint = fingerprint
        return nil
    }

    func moveAccount(_ account: ClaudeAccount, by offset: Int) {
        guard let index = accounts.firstIndex(of: account) else { return }
        let destination = index + offset
        guard accounts.indices.contains(destination) else { return }
        accounts.swapAt(index, destination)
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
