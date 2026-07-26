import SwiftUI

extension Notification.Name {
    static let showClaudeUsageSettings = Notification.Name("ShowClaudeUsageSettings")
}

/// Height the account list reports so the popover can be exactly as tall as the
/// accounts need.
private struct AccountListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @State private var accountListHeight: CGFloat = 0

    /// Beyond this the list scrolls instead of growing into the MacBook notch.
    private let maximumListHeight: CGFloat = 455

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The list takes only the height its accounts occupy, so three
            // accounts do not leave the empty space a fixed height left behind.
            ScrollView {
                accountList
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: AccountListHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    )
            }
            .frame(height: min(max(accountListHeight, 1), maximumListHeight))

            Divider().padding(.vertical, 6)
            Button(action: refreshUsage) { Label("Refresh all accounts", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
            Button(action: {
                NotificationCenter.default.post(name: .showClaudeUsageSettings, object: nil)
            }) { Label("Accounts & settings", systemImage: "gear") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
            Button(action: { NSApplication.shared.terminate(nil) }) { Label("Quit", systemImage: "power") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
        }
        .padding(.vertical, 8)
        .frame(width: 380)
        .onPreferenceChange(AccountListHeightKey.self) { accountListHeight = $0 }
    }

    @ViewBuilder private var accountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if usageService.accountUsages.isEmpty && !usageService.isLoading {
                Text("No Claude accounts configured")
                    .foregroundColor(.secondary)
                    .padding(12)
            } else {
                ForEach(usageService.accountUsages) { accountUsage in
                    AccountUsageView(accountUsage: accountUsage, settings: settingsManager.settings)
                    if accountUsage.id != usageService.accountUsages.last?.id { Divider().padding(.vertical, 6) }
                }
            }
        }
    }

    private func refreshUsage() { usageService.fetchUsage(accounts: settingsManager.accounts) }
}

private struct AccountUsageView: View {
    let accountUsage: AccountUsage
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(accountUsage.account.name).fontWeight(.semibold)
                Spacer()
                Text(accountUsage.hasUsageData ? "\(accountUsage.availableCapacity)% available" : "Unavailable")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = accountUsage.error {
                Text(error)
                    .font(.caption).foregroundColor(.red)
            }
            if accountUsage.hasUsageData {
                LimitRow(label: "5h", period: accountUsage.snapshot.fiveHour, icon: "clock", settings: settings)
                LimitRow(label: "Weekly", period: accountUsage.snapshot.sevenDay, icon: "calendar", settings: settings)
                if let fable = accountUsage.snapshot.fable {
                    LimitRow(label: "Fable", period: fable, icon: "sparkles", settings: settings)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct LimitRow: View {
    let label: String
    let period: UsagePeriod
    let icon: String
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 14).foregroundColor(color)
            Text(label).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(period.utilization)% used")
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(color)
                            .frame(width: max(2, geometry.size.width * CGFloat(period.utilization) / 100))
                    }
                }
                .frame(width: 180, height: 5)
            }
            Spacer()
            if let reset = period.resetsAt {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("in \(formatTimeRemaining(until: reset))").font(.caption)
                    Text(formatResetDate(reset)).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .font(.caption)
    }

    private var color: Color {
        guard period.utilization > 0 else { return .primary }
        // Green → yellow → orange → red, with a neutral 0% label.
        let hue = max(0, 0.33 * (1 - Double(period.utilization) / 100))
        return Color(hue: hue, saturation: 0.82, brightness: 0.92)
    }
}
