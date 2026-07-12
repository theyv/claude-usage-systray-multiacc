import SwiftUI
import Foundation

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss
    @State private var showAddAccount = false
    @State private var showClaudeCodeLogin = false

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
                    Button("Sign in with Claude Code…") { showClaudeCodeLogin = true }
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
        .sheet(isPresented: $showClaudeCodeLogin) { ClaudeCodeLoginView(settingsManager: settingsManager, usageService: usageService) }
    }

    private func accountSource(_ account: ClaudeAccount) -> String {
        guard let path = account.ccsCredentialsPath else { return "Stored in Keychain" }
        return path.contains("/.ccs/") ? "CCS profile" : "Claude Code login"
    }
}

private struct ClaudeCodeLoginView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var login = ClaudeCodeOAuthLogin()
    @State private var name = ""
    @State private var code = ""
    @State private var error: String?
    @State private var didStart = false
    @State private var createdAccount: ClaudeAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with Claude Code").font(.headline)
            Text("Creates an isolated local login for this account. Claude Code must be installed.")
                .font(.caption).foregroundColor(.secondary)
            if !didStart {
                TextField("Account name (e.g. Work)", text: $name)
                Button("Generate sign-in link") { start() }
            } else {
                if let url = login.authorizationURL { Link("Open Claude sign-in", destination: url) }
                Text(login.status).font(.caption).foregroundColor(.secondary)
                SecureField("Paste the code from the browser", text: $code)
                Button("Finish sign-in") { login.submit(code: code) }.disabled(code.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
        .padding().frame(width: 420)
        .onChange(of: login.completed) { completed in
            guard completed else { return }
            usageService.fetchUsage(accounts: settingsManager.accounts)
            dismiss()
        }
        .onDisappear {
            guard !login.completed, let createdAccount else { return }
            login.cancel()
            settingsManager.removeAccount(createdAccount)
        }
    }

    private func start() {
        do {
            let account = try settingsManager.createClaudeCodeLoginProfile(name: name)
            createdAccount = account
            let directory = URL(fileURLWithPath: account.ccsCredentialsPath!).deletingLastPathComponent()
            try login.start(profileDirectory: directory)
            didStart = true
        } catch { self.error = error.localizedDescription }
    }
}

private final class ClaudeCodeOAuthLogin: ObservableObject {
    @Published private(set) var authorizationURL: URL?
    @Published private(set) var status = "Preparing Claude Code login…"
    @Published private(set) var completed = false
    private var process: Process?
    private var input: Pipe?

    func start(profileDirectory: URL) throws {
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "ClaudeCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude Code is not installed."])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "login", "--claudeai"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = profileDirectory.path
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        self.process = process
        self.input = input
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.completed = process.terminationStatus == 0; self?.status = process.terminationStatus == 0 ? "Login complete." : "Login did not complete." }
        }
        try process.run()
    }

    func submit(code: String) { input?.fileHandleForWriting.write(Data((code + "\n").utf8)); input?.fileHandleForWriting.closeFile(); status = "Finishing login…" }

    func cancel() {
        process?.terminate()
        input?.fileHandleForWriting.closeFile()
    }

    private func consume(_ text: String) {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{07}" })
        if let link = parts.first(where: { $0.hasPrefix("https://claude.com/cai/oauth/authorize") }) {
            authorizationURL = URL(string: String(link)); status = "Open the link, sign in, then paste the code."
        }
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
