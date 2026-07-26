import AppKit

// `--diagnose` prints an anonymized account report and exits, so multi-account
// problems can be inspected without any UI.
if CommandLine.arguments.contains("--diagnose") {
    ClaudeUsageDiagnostics.runFromCommandLine()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
