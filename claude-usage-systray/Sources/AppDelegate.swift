import AppKit
import SwiftUI
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared
    
    private var sentAlerts = Set<String>()

    // Keep Combine subscriptions alive
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = ClaudeEditMenu.makeMainMenu()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsWindow),
            name: .showClaudeUsageSettings,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
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
        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(
            rootView: MenuBarView(
                usageService: usageService,
                settingsManager: settingsManager
            )
        )
        // The popover follows the content, so its height matches the number of
        // accounts instead of being fixed.
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePopover() }
        }
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

    @objc private func showSettingsWindow() {
        closePopover()

        if settingsWindow == nil {
            let settingsView = SettingsView(
                settingsManager: settingsManager,
                usageService: usageService,
                onDone: { [weak self] in self?.settingsWindow?.close() }
            )
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Claude Usage — Accounts & Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 500))
            window.minSize = NSSize(width: 520, height: 500)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.managed, .participatesInCycle]
            window.center()
            settingsWindow = window
        }

        guard let settingsWindow else { return }
        if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.attachedSheet?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let rankedUsages = usageService.accountUsages
            .filter { $0.error == nil && $0.snapshot.sevenDay.utilization < 100 }

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
        guard percentage > 0 else { return .labelColor }
        let hue = max(0, 0.33 * (1 - CGFloat(percentage) / 100))
        return NSColor(calibratedHue: hue, saturation: 0.82, brightness: 0.92, alpha: 1)
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

/// The standard editing shortcuts.
///
/// An `LSUIElement` app never shows a menu bar, and AppKit routes Cmd-X/C/V/A
/// through the main menu's key equivalents — with no main menu, pasting into the
/// Claude.ai login window or the sign-in code field silently did nothing. This
/// menu is never displayed; it exists so those shortcuts reach the first
/// responder. Selectors are looked up by name because they are informal actions
/// implemented by AppKit and WebKit responders rather than declared methods.
enum ClaudeEditMenu {
    static func makeMainMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item(title: "Undo", action: "undo:", key: "z"))
        editMenu.addItem(item(title: "Redo", action: "redo:", key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item(title: "Cut", action: "cut:", key: "x"))
        editMenu.addItem(item(title: "Copy", action: "copy:", key: "c"))
        editMenu.addItem(item(title: "Paste", action: "paste:", key: "v"))
        editMenu.addItem(item(title: "Select All", action: "selectAll:", key: "a"))

        let editItem = NSMenuItem()
        editItem.title = "Edit"
        editItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        return mainMenu
    }

    private static func item(
        title: String,
        action: String,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: NSSelectorFromString(action),
            keyEquivalent: key
        )
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
