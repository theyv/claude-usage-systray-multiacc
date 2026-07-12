import Foundation
import Security
import CryptoKit

private let accountTokenService = "Claude Usage Systray OAuth"

func saveAccountToken(_ token: String, for accountID: UUID) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: accountTokenService,
        kSecAttrAccount as String: accountID.uuidString
    ]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = Data(token.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
}

func readAccountToken(for accountID: UUID) throws -> String {
    try readKeychainToken(service: accountTokenService, account: accountID.uuidString)
}

private func readKeychainToken(service: String, account: String? = nil) throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var completeQuery = query
    if let account { completeQuery[kSecAttrAccount as String] = account }
    var result: AnyObject?
    let status = SecItemCopyMatching(completeQuery as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
    return token
}

private struct CCSCredentials: Decodable {
    let claudeAiOauth: OAuth
    struct OAuth: Decodable { let accessToken: String }
}

func readToken(for account: ClaudeAccount) throws -> String {
    if let path = account.ccsCredentialsPath {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let credentials = try? JSONDecoder().decode(CCSCredentials.self, from: data) {
            return credentials.claudeAiOauth.accessToken
        }
        return try readCCSKeychainToken(profilePath: path)
    }
    return try readAccountToken(for: account.id)
}

/// Claude Code derives a separate macOS Keychain service for every
/// CLAUDE_CONFIG_DIR: `Claude Code-credentials-<first 8 SHA-256 chars>`.
/// CCS profiles are exactly such isolated configuration directories.
private func readCCSKeychainToken(profilePath: String) throws -> String {
    let digest = SHA256.hash(data: Data(profilePath.utf8))
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    let payload = try readKeychainToken(service: "Claude Code-credentials-\(suffix)")
    guard let data = payload.data(using: .utf8) else { throw KeychainError(status: errSecDecode) }
    return try JSONDecoder().decode(CCSCredentials.self, from: data).claudeAiOauth.accessToken
}

func deleteAccountToken(for accountID: UUID) {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: accountTokenService, kSecAttrAccount as String: accountID.uuidString] as CFDictionary)
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not access the account token in Keychain (status \(status))." }
}

struct OAuthUsageResponse: Decodable {
    let fiveHour: APIUsagePeriod?
    let sevenDay: APIUsagePeriod?
    let sevenDaySonnet: APIUsagePeriod?
    let limits: [ScopedLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", sevenDaySonnet = "seven_day_sonnet", limits
    }

    struct APIUsagePeriod: Decodable {
        let utilization: Double
        let resetsAt: String
        enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
        var asUsagePeriod: UsagePeriod { UsagePeriod(utilization: Int(utilization), resetsAt: parseISO8601(resetsAt)) }
        var resetsAtDate: Date? { parseISO8601(resetsAt) }
    }

    struct ScopedLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey { case kind, percent, scope; case resetsAt = "resets_at" }
        struct Scope: Decodable { let model: Model?; struct Model: Decodable { let displayName: String?; enum CodingKeys: String, CodingKey { case displayName = "display_name" } } }
    }

    var fable: UsagePeriod? {
        guard let limit = limits?.first(where: { $0.kind == "weekly_scoped" && $0.scope?.model?.displayName?.localizedCaseInsensitiveContains("fable") == true }), let percent = limit.percent else { return nil }
        return UsagePeriod(utilization: Int(percent), resetsAt: limit.resetsAt.flatMap(parseISO8601))
    }
}

private func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

final class UsageService: ObservableObject {
    static let shared = UsageService()
    @Published private(set) var accountUsages: [AccountUsage] = []
    @Published private(set) var isLoading = false

    private var refreshTimer: Timer?
    private let normalInterval: TimeInterval = 5 * 60
    var urlSession: URLSession = .shared
    private init() {}

    var bestAccount: AccountUsage? {
        accountUsages
            .filter { $0.error == nil }
            .max { $0.availableCapacity < $1.availableCapacity }
    }

    func startPolling(accounts: [ClaudeAccount]) { fetchUsage(accounts: accounts); scheduleTimer() }
    func stopPolling() { refreshTimer?.invalidate(); refreshTimer = nil }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: normalInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fetchUsage(accounts: SettingsManager.shared.accounts)
        }
    }

    func fetchUsage(accounts: [ClaudeAccount]) {
        isLoading = true
        Task {
            let results = await withTaskGroup(of: AccountUsage.self, returning: [AccountUsage].self) { group in
                for account in accounts { group.addTask { await self.fetchUsage(for: account) } }
                var values: [AccountUsage] = []
                for await value in group { values.append(value) }
                return values
            }
            await MainActor.run {
                self.accountUsages = results.sorted { $0.account.name.localizedStandardCompare($1.account.name) == .orderedAscending }
                self.isLoading = false
            }
        }
    }

    private func fetchUsage(for account: ClaudeAccount) async -> AccountUsage {
        do {
            let response = try await fetchOAuthUsage(accessToken: readToken(for: account))
            return AccountUsage(account: account, snapshot: UsageSnapshot(fiveHour: response.fiveHour?.asUsagePeriod ?? UsageSnapshot.placeholder.fiveHour, sevenDay: response.sevenDay?.asUsagePeriod ?? UsageSnapshot.placeholder.sevenDay, fable: response.fable ?? response.sevenDaySonnet?.asUsagePeriod, lastUpdated: Date()), error: nil)
        } catch {
            return AccountUsage(account: account, snapshot: .placeholder, error: error.localizedDescription)
        }
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
