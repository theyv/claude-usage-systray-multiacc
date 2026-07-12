import AppKit
import SwiftUI
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared
    
    private var sentAlerts = Set<String>()

    // Keep Combine subscriptions alive
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupNotifications()
        startUsagePolling()

        // The status item always follows the account with the most capacity left.
        usageService.$accountUsages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.checkForNotifications()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDidUpdate),
            name: NSNotification.Name("UsageDidUpdate"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Claude Usage")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 590)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                usageService: usageService,
                settingsManager: settingsManager
            )
        )
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    private func startUsagePolling() {
        settingsManager.importCCSProfiles()
        usageService.startPolling(accounts: settingsManager.accounts)
        
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    @objc private func settingsDidChange() {
        updateStatusItemAppearance()
    }

    @objc private func usageDidUpdate() {
        updateStatusItemAppearance()
        checkForNotifications()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let displayOrder = ["account-one", "account-two", "account-three"]
        let rankedUsages = usageService.accountUsages
            .filter { $0.error == nil && $0.snapshot.sevenDay.utilization < 100 }
            .sorted {
                let left = displayOrder.firstIndex(of: $0.account.name.lowercased()) ?? displayOrder.count
                let right = displayOrder.firstIndex(of: $1.account.name.lowercased()) ?? displayOrder.count
                return left == right ? $0.account.name < $1.account.name : left < right
            }

        guard let selected = usageService.bestAccount else {
            button.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Claude Usage")
            button.title = " — "
            return
        }
        let snapshot = selected.snapshot
        let weekUsage = snapshot.sevenDay.utilization

        if settingsManager.settings.compactDisplay {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let str = NSMutableAttributedString()
            for (index, accountUsage) in rankedUsages.enumerated() {
                if index > 0 {
                    str.append(NSAttributedString(string: " | ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                }
                let fiveHourUsage = accountUsage.snapshot.fiveHour.utilization
                str.append(NSAttributedString(string: "\(fiveHourUsage)%", attributes: [.font: font, .foregroundColor: usageColor(for: fiveHourUsage)]))
            }

            button.image = nil
            button.attributedTitle = str.length > 0 ? str : NSAttributedString(string: " — ", attributes: [.font: font])
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            let symbolName: String
            if weekUsage >= 80 { symbolName = "exclamationmark.triangle.fill" }
            else if weekUsage >= 50 { symbolName = "chart.pie.fill" }
            else { symbolName = "chart.pie" }

            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Claude Usage")?
                .withSymbolConfiguration(config)
            button.attributedTitle = NSAttributedString(
                string: "\(weekUsage)%",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: usageColor(for: weekUsage)
                ]
            )
        }
    }

    private func usageColor(for percentage: Int) -> NSColor {
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        if percentage >= criticalThreshold {
            return .systemRed
        } else if percentage >= warningThreshold {
            return .systemOrange
        }
        return .labelColor
    }

    private func checkForNotifications() {
        guard settingsManager.settings.notificationsEnabled else { return }
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)

        for accountUsage in usageService.accountUsages where accountUsage.hasUsageData {
            checkAlert(account: accountUsage.account.name, limit: "5h", usage: accountUsage.snapshot.fiveHour.utilization, warning: warningThreshold, critical: criticalThreshold)
            checkAlert(account: accountUsage.account.name, limit: "weekly", usage: accountUsage.snapshot.sevenDay.utilization, warning: warningThreshold, critical: criticalThreshold)
        }
    }

    private func checkAlert(account: String, limit: String, usage: Int, warning: Int, critical: Int) {
        let warningKey = "\(account)-\(limit)-warning"
        let criticalKey = "\(account)-\(limit)-critical"
        if usage < warning {
            sentAlerts.remove(warningKey)
            sentAlerts.remove(criticalKey)
            return
        }
        if usage >= critical, !sentAlerts.contains(criticalKey) {
            sendNotification(title: "Critical: \(account) Claude usage", body: "\(limit) usage is \(usage)%.", isCritical: true)
            sentAlerts.insert(criticalKey)
        } else if usage < critical, !sentAlerts.contains(warningKey) {
            sendNotification(title: "Warning: \(account) Claude usage", body: "\(limit) usage is \(usage)%.", isCritical: false)
            sentAlerts.insert(warningKey)
        }
    }

    private func sendNotification(title: String, body: String, isCritical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isCritical ? .defaultCritical : .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }
}
