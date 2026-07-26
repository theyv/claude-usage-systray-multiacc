import SwiftUI
import Foundation
import WebKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var showAddAccount = false
    @State private var showClaudeCodeLogin = false
    @State private var accountToRename: ClaudeAccount?
    @State private var renamedAccountName = ""
    @State private var webLoginAccount: ClaudeAccount?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Usage — accounts").font(.headline)
                Spacer()
                Button("Done") {
                    if let onDone { onDone() } else { dismiss() }
                }
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
                            Button { webLoginAccount = account } label: {
                                Image(systemName: account.webOrganizationID == nil ? "globe" : "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(account.webOrganizationID == nil ? "Connect Claude.ai web session" : "Reconnect Claude.ai web session")
                            Button { beginRename(account) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button { move(account, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless)
                                .disabled(settingsManager.accounts.first?.id == account.id)
                            Button { move(account, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless)
                                .disabled(settingsManager.accounts.last?.id == account.id)
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
        .frame(width: 520, height: 500)
        .sheet(isPresented: $showAddAccount) { AddAccountView(settingsManager: settingsManager, usageService: usageService) }
        .sheet(isPresented: $showClaudeCodeLogin) { ClaudeCodeLoginView(settingsManager: settingsManager, usageService: usageService) }
        .sheet(item: $webLoginAccount) { account in
            ClaudeWebLoginView(account: account, settingsManager: settingsManager, usageService: usageService)
        }
        .alert("Rename account", isPresented: Binding(
            get: { accountToRename != nil },
            set: { if !$0 { accountToRename = nil } }
        )) {
            TextField("Account name", text: $renamedAccountName)
            Button("Cancel", role: .cancel) { accountToRename = nil }
            Button("Save") { saveRename() }
        }
    }

    private func accountSource(_ account: ClaudeAccount) -> String {
        if account.webOrganizationID != nil { return "Claude.ai web session" }
        guard let path = account.ccsCredentialsPath else { return "Stored in Keychain" }
        return path.contains("/.ccs/") ? "CCS profile" : "Claude Code login"
    }

    private func move(_ account: ClaudeAccount, by offset: Int) {
        settingsManager.moveAccount(account, by: offset)
        usageService.fetchUsage(accounts: settingsManager.accounts)
    }

    private func beginRename(_ account: ClaudeAccount) {
        renamedAccountName = account.name
        accountToRename = account
    }

    private func saveRename() {
        if let accountToRename { settingsManager.renameAccount(accountToRename, to: renamedAccountName) }
        accountToRename = nil
    }
}

private struct ClaudeWebCredential: Equatable {
    let sessionKey: String
    let organizationID: String
}

private struct ClaudeWebLoginView: View {
    let account: ClaudeAccount
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var login = ClaudeWebLogin()
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(account.name) to Claude.ai").font(.headline)
                    Text(login.status).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Use current session") { login.captureCurrentSession() }
                Button("Cancel") { dismiss() }
            }
            .padding()

            if let error = login.error ?? saveError {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }

            ClaudeWebView(login: login)
        }
        .frame(width: 960, height: 680)
        .onAppear { login.start() }
        .onDisappear { login.cancel() }
        .onChange(of: login.credential) { credential in
            guard let credential else { return }
            do {
                try settingsManager.connectWebSession(
                    account,
                    sessionKey: credential.sessionKey,
                    organizationID: credential.organizationID
                )
                usageService.clearRateLimit(for: account.id)
                usageService.fetchUsage(accounts: settingsManager.accounts)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

private struct ClaudeWebView: NSViewRepresentable {
    @ObservedObject var login: ClaudeWebLogin

    func makeNSView(context: Context) -> WKWebView { login.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
private final class ClaudeWebLogin: NSObject, ObservableObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    @Published private(set) var status = "Preparing Claude.ai login…"
    @Published private(set) var credential: ClaudeWebCredential?
    @Published private(set) var error: String?

    private enum Stage { case idle, signingIn, findingOrganization, complete }
    private var stage = Stage.idle
    private var capturedSessionKey: String?

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Every account gets a fresh, isolated browser session. Reusing the
        // default store silently reconnects the account logged in previously.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        return view
    }()

    func start() {
        guard stage == .idle else { return }
        error = nil
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let sessionCookies = cookies.filter { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
            let group = DispatchGroup()
            for cookie in sessionCookies {
                group.enter()
                cookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                cookieStore.add(self)
                self.stage = .signingIn
                self.status = "Sign in normally. The window will close automatically when connected."
                self.webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
            }
        }
    }

    func cancel() {
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView.stopLoading()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard stage == .signingIn else { return }
        captureCurrentSession(showError: false)
    }

    func captureCurrentSession(showError: Bool = true) {
        guard stage == .signingIn else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            guard self.stage == .signingIn,
                  let sessionKey = cookies.first(where: {
                      $0.name == "sessionKey" && $0.domain.contains("claude.ai")
                  })?.value else {
                if showError {
                    self.error = "No Claude.ai session cookie found yet. Finish signing in, then try again."
                }
                return
            }
            self.error = nil
            self.capturedSessionKey = sessionKey
            self.stage = .findingOrganization
            self.status = "Login complete. Finding your Claude organization…"
            self.webView.load(URLRequest(url: URL(string: "https://claude.ai/api/organizations")!))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if stage == .signingIn {
            captureCurrentSession(showError: false)
            return
        }
        guard stage == .findingOrganization else { return }
        webView.evaluateJavaScript("document.body.innerText || document.body.textContent") { result, evaluationError in
            if let evaluationError {
                self.fail(evaluationError.localizedDescription)
                return
            }
            guard let sessionKey = self.capturedSessionKey,
                  let text = result as? String,
                  let data = text.data(using: .utf8),
                  let organizations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let organization = organizations.first,
                  let organizationID = (organization["uuid"] ?? organization["id"]) as? String else {
                self.fail("Login succeeded, but no Claude organization was found.")
                return
            }
            self.stage = .complete
            self.status = "Connected."
            self.webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            self.credential = ClaudeWebCredential(sessionKey: sessionKey, organizationID: organizationID)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        error = message
        status = "Could not connect this account."
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
            TextField("Name (e.g. Work)", text: $name)
            SecureField("Claude Code OAuth access token", text: $token)
            Text("The token is saved only in your macOS Keychain.").font(.caption).foregroundColor(.secondary)
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Add") { add() }.disabled(token.isEmpty) }
        }.padding().frame(width: 400)
    }
    private func add() { do { try settingsManager.addAccount(name: name, token: token); usageService.fetchUsage(accounts: settingsManager.accounts); dismiss() } catch { self.error = error.localizedDescription } }
}
