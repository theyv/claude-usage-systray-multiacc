import Foundation

/// A state dump that is safe to paste into a public issue.
///
/// Multi-account problems are invisible from the outside — the interesting facts
/// are whether two profiles resolve to the same login, organization, or session.
/// Those are reported as group letters assigned in order of appearance, so the
/// report proves whether values are shared without ever revealing one. No
/// cookie, token, address, or organization identifier reaches the output.
enum ClaudeUsageDiagnostics {
    struct Input {
        let accounts: [ClaudeAccount]
        /// Session keys are only compared and grouped, never printed.
        let sessionKeys: [UUID: String]
        let snapshots: [UUID: UsageSnapshot]
    }

    static func report(for input: Input, now: Date = Date()) -> String {
        var lines = [
            "Claude Usage Systray diagnostics",
            "accounts: \(input.accounts.count)",
            "stored web sessions: \(input.sessionKeys.count)"
        ]

        var organizations = GroupLabels()
        var identities = GroupLabels()
        var sessions = GroupLabels()

        var accountLines: [String] = []
        for (position, account) in input.accounts.enumerated() {
            let sessionKey = input.sessionKeys[account.id]
            accountLines.append("")
            accountLines.append("position \(position + 1)")
            accountLines.append("  source: \(source(of: account))")
            accountLines.append("  web session stored: \(sessionKey == nil ? "no" : "yes")")
            accountLines.append("  session group: \(sessions.label(for: sessionKey))")
            accountLines.append("  organization group: \(organizations.label(for: account.webOrganizationID))")
            accountLines.append("  identity group: \(identities.label(for: account.webAccountFingerprint))")
            accountLines.append("  last usage: \(usageDescription(for: account, in: input, now: now))")
        }

        lines.append("distinct sessions: \(sessions.count)")
        lines.append("distinct organizations: \(organizations.count)")
        lines.append("distinct identities: \(identities.count)")
        lines.append(contentsOf: accountLines)

        if sessions.count < input.sessionKeys.count {
            lines.append("")
            lines.append("warning: two profiles hold the same Claude.ai session — reconnect one of them.")
        }
        if identities.count == 1 && input.accounts.filter({ $0.webAccountFingerprint != nil }).count > 1 {
            lines.append("")
            lines.append("warning: every connected profile reports one identity — reconnect them.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func source(of account: ClaudeAccount) -> String {
        if account.webOrganizationID != nil { return "Claude.ai web session" }
        guard let path = account.ccsCredentialsPath else { return "OAuth token in Keychain" }
        return path.contains("/.ccs/") ? "CCS profile" : "Claude Code login"
    }

    private static func usageDescription(for account: ClaudeAccount, in input: Input, now: Date) -> String {
        guard let snapshot = input.snapshots[account.id] else { return "never fetched" }
        var parts = [
            "5h \(snapshot.fiveHour.utilization)%",
            "weekly \(snapshot.sevenDay.utilization)%"
        ]
        if let reset = snapshot.sevenDay.resetsAt {
            parts.append("weekly reset \(formatResetDate(reset)) (in \(formatTimeRemaining(until: reset, from: now)))")
        }
        parts.append("fetched \(formatAge(of: snapshot.lastUpdated, now: now)) ago")
        return parts.joined(separator: " · ")
    }

    private static func formatAge(of date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Stable letters (A, B, C…) so identical values are visibly identical
    /// across accounts while the values themselves stay out of the report.
    private struct GroupLabels {
        private var labels: [String: String] = [:]

        var count: Int { labels.count }

        mutating func label(for value: String?) -> String {
            guard let value else { return "none" }
            if let existing = labels[value] { return existing }
            let label = Self.name(for: labels.count)
            labels[value] = label
            return label
        }

        private static func name(for index: Int) -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let letter = String(alphabet[index % alphabet.count])
            let cycle = index / alphabet.count
            return cycle == 0 ? letter : "\(letter)\(cycle + 1)"
        }
    }
}

extension ClaudeUsageDiagnostics {
    /// Entry point for `ClaudeUsageSystray --diagnose`, which needs no UI and
    /// never touches Keychain, so it can run while the app is up.
    static func runFromCommandLine() -> Never {
        let accounts = SettingsManager.shared.accounts
        var sessionKeys: [UUID: String] = [:]
        for account in accounts {
            if let sessionKey = try? WebSessionFileStore.shared.sessionKey(for: account.id) {
                sessionKeys[account.id] = sessionKey
            }
        }
        let input = Input(
            accounts: accounts,
            sessionKeys: sessionKeys,
            snapshots: UsageService.loadCachedSnapshots()
        )
        print(report(for: input), terminator: "")
        exit(0)
    }
}
