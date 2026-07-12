import SwiftUI

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @State private var showSettings = false

    var body: some View {
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

            Divider().padding(.vertical, 6)
            Button(action: refreshUsage) { Label("Refresh all accounts", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
            Button(action: { showSettings = true }) { Label("Accounts & settings", systemImage: "gear") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
            Button(action: { NSApplication.shared.terminate(nil) }) { Label("Quit", systemImage: "power") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
        }
        .padding(.vertical, 8)
        .frame(minWidth: 330)
        .sheet(isPresented: $showSettings) { SettingsView(settingsManager: settingsManager, usageService: usageService) }
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
                Text(accountUsage.error == nil ? "\(accountUsage.availableCapacity)% available" : "Unavailable")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = accountUsage.error {
                Text(error)
                    .font(.caption).foregroundColor(.red)
            } else {
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
            Text("\(period.utilization)% used").fontWeight(.medium)
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
        if period.utilization >= Int(settings.criticalThreshold) { return .red }
        if period.utilization >= Int(settings.warningThreshold) { return .orange }
        return .accentColor
    }
}
