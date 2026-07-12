import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss
    @State private var showAddAccount = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Usage — accounts").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }.padding()
            Form {
                Section("Accounts") {
                    ForEach(settingsManager.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.name)
                                Text(accountSource(account))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { settingsManager.removeAccount(account); usageService.fetchUsage(accounts: settingsManager.accounts) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Import CCS profiles") { settingsManager.importCCSProfiles(); usageService.fetchUsage(accounts: settingsManager.accounts) }
                    Button("Import current Claude Code login") { settingsManager.importCurrentClaudeCodeLogin(); usageService.fetchUsage(accounts: settingsManager.accounts) }
                    Button("Add OAuth token…") { showAddAccount = true }
                }
                Section("Menu bar") { Toggle("Compact display", isOn: Binding(get: { settingsManager.settings.compactDisplay }, set: settingsManager.setCompactDisplay)) }
                Section("Alerts") {
                    Toggle("Enable usage alerts", isOn: Binding(get: { settingsManager.settings.notificationsEnabled }, set: settingsManager.setNotificationsEnabled))
                    Slider(value: Binding(get: { settingsManager.settings.warningThreshold }, set: settingsManager.setWarningThreshold), in: 50...95, step: 5) { Text("Warning") }
                    Slider(value: Binding(get: { settingsManager.settings.criticalThreshold }, set: settingsManager.setCriticalThreshold), in: 60...100, step: 5) { Text("Critical") }
                }
            }.formStyle(.grouped)
        }
        .frame(width: 420, height: 440)
        .sheet(isPresented: $showAddAccount) { AddAccountView(settingsManager: settingsManager, usageService: usageService) }
    }

    private func accountSource(_ account: ClaudeAccount) -> String {
        guard let path = account.ccsCredentialsPath else { return "Stored in Keychain" }
        return path.contains("/.ccs/") ? "CCS profile" : "Claude Code login"
    }
}

private struct AddAccountView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Claude account").font(.headline)
            TextField("Name (e.g. account-one)", text: $name)
            SecureField("Claude Code OAuth access token", text: $token)
            Text("The token is saved only in your macOS Keychain.").font(.caption).foregroundColor(.secondary)
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Add") { add() }.disabled(token.isEmpty) }
        }.padding().frame(width: 400)
    }
    private func add() { do { try settingsManager.addAccount(name: name, token: token); usageService.fetchUsage(accounts: settingsManager.accounts); dismiss() } catch { self.error = error.localizedDescription } }
}
