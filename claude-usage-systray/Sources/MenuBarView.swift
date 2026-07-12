import SwiftUI

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
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
            .frame(maxHeight: 470)

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
                .frame(width: 104, height: 5)
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
