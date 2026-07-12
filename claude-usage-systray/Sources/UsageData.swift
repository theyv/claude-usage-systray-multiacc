import Foundation

struct AppSettings: Codable {
    var warningThreshold: Double = 80.0
    var criticalThreshold: Double = 90.0
    var notificationsEnabled: Bool = true
    var compactDisplay: Bool = true

    var isConfigured: Bool { true }
}

struct ClaudeAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// When present, the token is read directly from a CCS profile instead of
    /// being duplicated into this app's Keychain item.
    var ccsCredentialsPath: String?

    init(id: UUID = UUID(), name: String, ccsCredentialsPath: String? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ccsCredentialsPath = ccsCredentialsPath
    }
}

struct UsagePeriod: Hashable {
    let utilization: Int
    let resetsAt: Date?

    var remaining: Int { max(0, 100 - utilization) }
}

struct UsageSnapshot: Hashable {
    let fiveHour: UsagePeriod
    let sevenDay: UsagePeriod
    let fable: UsagePeriod?
    let lastUpdated: Date

    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsagePeriod(utilization: 0, resetsAt: nil),
            sevenDay: UsagePeriod(utilization: 0, resetsAt: nil),
            fable: nil,
            lastUpdated: Date()
        )
    }
}

struct AccountUsage: Identifiable, Hashable {
    let account: ClaudeAccount
    let snapshot: UsageSnapshot
    let error: String?

    var id: UUID { account.id }

    /// The account is only as available as its tightest general quota.
    var availableCapacity: Int {
        min(snapshot.fiveHour.remaining, snapshot.sevenDay.remaining)
    }
}

func formatTimeRemaining(until date: Date, from now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "now" }
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

/// Kept pure so quota calculations remain independently testable.
func calculateUtilization(tokens: Int, limit: Int) -> Int {
    guard limit > 0 else { return 0 }
    return min(100, tokens * 100 / limit)
}

func formatResetDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("EEEE HH:mm")
    return formatter.string(from: date)
}
