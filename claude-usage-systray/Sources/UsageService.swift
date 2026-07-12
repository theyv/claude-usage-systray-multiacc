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
        return try readCCSKeychainToken(profileDirectory: URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
    return try readAccountToken(for: account.id)
}

/// Claude Code derives a separate macOS Keychain service for every
/// CLAUDE_CONFIG_DIR: `Claude Code-credentials-<first 8 SHA-256 chars>`.
/// CCS profiles are exactly such isolated configuration directories.
private func readCCSKeychainToken(profileDirectory: String) throws -> String {
    let digest = SHA256.hash(data: Data(profileDirectory.utf8))
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    let service = "Claude Code-credentials-\(suffix)"
    return try decodeOAuthToken(readKeychainTokenUsingSecurityCLI(service: service))
}

private func decodeOAuthToken(_ payload: String) throws -> String {
    guard let data = payload.data(using: .utf8) else { throw KeychainError(status: errSecDecode) }
    return try JSONDecoder().decode(CCSCredentials.self, from: data).claudeAiOauth.accessToken
}

private func readKeychainTokenUsingSecurityCLI(service: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    let loginKeychain = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Keychains/login.keychain-db").path
    process.arguments = ["find-generic-password", "-s", service, "-w", loginKeychain]
    process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "CCSKeychain", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Could not read this CCS profile from Keychain."])
    }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
    private let normalInterval: TimeInterval = 3 * 60
    private let rateLimitInterval: TimeInterval = 10 * 60
    private var retryAfter: Date?
    private var cachedTokens: [UUID: String] = [:]
    var urlSession: URLSession = .shared
    private init() {}

    var bestAccount: AccountUsage? {
        accountUsages
            .filter { $0.hasUsageData }
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
        guard !isLoading else { return }
        if let retryAfter, retryAfter > Date() { return }
        isLoading = true
        let previousUsages = Dictionary(uniqueKeysWithValues: accountUsages.map { ($0.id, $0) })
        Task {
            // Anthropic's usage endpoint is sensitive to bursts. Fetching CCS
            // profiles one at a time prevents a manual refresh from turning all
            // rows into simultaneous 429 failures.
            var results: [AccountUsage] = []
            var rateLimited = false
            for account in accounts {
                if rateLimited {
                    results.append(staleUsage(for: account, previous: previousUsages[account.id], error: "Rate limited — retrying later"))
                    continue
                }

                let result = await fetchUsage(for: account, previous: previousUsages[account.id])
                results.append(result)
                if result.error?.hasPrefix("HTTP 429") == true {
                    rateLimited = true
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            await MainActor.run {
                self.accountUsages = results.sorted { $0.account.name.localizedStandardCompare($1.account.name) == .orderedAscending }
                if rateLimited { self.retryAfter = Date().addingTimeInterval(self.rateLimitInterval) }
                self.isLoading = false
            }
        }
    }

    private func fetchUsage(for account: ClaudeAccount, previous: AccountUsage?) async -> AccountUsage {
        do {
            let response = try await fetchOAuthUsage(accessToken: try accessToken(for: account))
            return AccountUsage(account: account, snapshot: UsageSnapshot(fiveHour: response.fiveHour?.asUsagePeriod ?? UsageSnapshot.placeholder.fiveHour, sevenDay: response.sevenDay?.asUsagePeriod ?? UsageSnapshot.placeholder.sevenDay, fable: response.fable ?? response.sevenDaySonnet?.asUsagePeriod, lastUpdated: Date()), error: nil, isStale: false)
        } catch {
            return staleUsage(for: account, previous: previous, error: error.localizedDescription)
        }
    }

    private func accessToken(for account: ClaudeAccount) throws -> String {
        if let cachedToken = cachedTokens[account.id] { return cachedToken }
        let token = try readToken(for: account)
        cachedTokens[account.id] = token
        return token
    }

    private func staleUsage(for account: ClaudeAccount, previous: AccountUsage?, error: String) -> AccountUsage {
        if let previous, previous.hasUsageData {
            return AccountUsage(account: account, snapshot: previous.snapshot, error: error, isStale: true)
        }
        return AccountUsage(account: account, snapshot: .placeholder, error: error, isStale: false)
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OAuthUsage", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(160))"])
        }
        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
