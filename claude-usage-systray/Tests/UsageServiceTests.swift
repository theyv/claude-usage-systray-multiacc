import XCTest
import AppKit
@testable import ClaudeUsageSystray

// MARK: - Editing shortcuts

final class ClaudeEditMenuTests: XCTestCase {

    private var editMenu: NSMenu? {
        ClaudeEditMenu.makeMainMenu().items.first?.submenu
    }

    func testPasteIsBoundToCommandV() throws {
        // Without this binding an agent app cannot paste into the login window.
        let paste = try XCTUnwrap(editMenu?.items.first { $0.title == "Paste" })

        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(paste.action, NSSelectorFromString("paste:"))
    }

    func testProvidesEveryStandardEditingShortcut() throws {
        let items = try XCTUnwrap(editMenu?.items.filter { !$0.isSeparatorItem })

        let bindings = items.map { item in
            "\(item.keyEquivalent)-\(item.action.map(NSStringFromSelector) ?? "none")"
        }
        XCTAssertEqual(bindings, ["z-undo:", "z-redo:", "x-cut:", "c-copy:", "v-paste:", "a-selectAll:"])
    }

    func testRedoIsDistinguishedByShift() throws {
        let items = try XCTUnwrap(editMenu?.items)
        let undo = try XCTUnwrap(items.first { $0.title == "Undo" })
        let redo = try XCTUnwrap(items.first { $0.title == "Redo" })

        XCTAssertEqual(undo.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
    }
}

// MARK: - OAuthUsageResponse decoding

final class OAuthUsageResponseTests: XCTestCase {

    func testDecodesFullResponse() throws {
        let json = """
        {
          "five_hour":   { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day":   { "utilization": 71.0, "resets_at": "2026-03-20T11:00:00.367161+00:00" },
          "seven_day_sonnet": { "utilization": 27.0, "resets_at": "2026-03-20T12:00:00.367175+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_cowork": null,
          "iguana_necktie": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 35.0)
        XCTAssertEqual(response.sevenDay?.utilization, 71.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 27.0)
    }

    func testDecodesFableScopedLimit() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_sonnet": null,
          "limits": [{
            "kind": "weekly_scoped",
            "percent": 42.0,
            "resets_at": "2026-03-20T12:00:00+00:00",
            "scope": { "model": { "display_name": "Fable" } }
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fable?.utilization, 42)
        XCTAssertNotNil(response.fable?.resetsAt)
    }

    func testDecodesNullSonnet() throws {
        let json = """
        {
          "five_hour":   { "utilization": 10.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 20.0, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.sevenDaySonnet)
        XCTAssertEqual(response.fiveHour?.utilization, 10.0)
    }

    func testDecodesNullResetTime() throws {
        let json = """
        {
          "five_hour": { "utilization": 0.0, "resets_at": null },
          "seven_day": { "utilization": 13.0, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 0)
        XCTAssertNil(response.fiveHour?.resetsAtDate)
    }

    func testDecodesAllNulls() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.fiveHour)
        XCTAssertNil(response.sevenDay)
        XCTAssertNil(response.sevenDaySonnet)
    }

    func testResetsAtDateParsesWithFractionalSeconds() throws {
        let json = """
        {
          "five_hour": { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day": null, "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertNotNil(response.fiveHour?.resetsAtDate, "resetsAt date should parse successfully")
    }

    func testUtilizationConvertsToInt() throws {
        let json = """
        {
          "five_hour":   { "utilization": 34.7, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 71.2, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": { "utilization": 26.9, "resets_at": "2026-03-20T12:00:00+00:00" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        // Int() truncates (floors), matching how snapshot builds utilization
        XCTAssertEqual(Int(response.fiveHour!.utilization), 34)
        XCTAssertEqual(Int(response.sevenDay!.utilization), 71)
        XCTAssertEqual(Int(response.sevenDaySonnet!.utilization), 26)
    }
}

// MARK: - Claude organizations response parsing

final class ClaudeOrganizationsResponseParserTests: XCTestCase {

    func testParsesOrganizationsArray() {
        let json = #"[{"uuid":"org-array","name":"Example"}]"#
        XCTAssertEqual(
            ClaudeOrganizationsResponseParser.firstOrganizationID(from: json),
            "org-array"
        )
    }

    func testParsesWrappedOrganizationsArray() {
        let json = #"{"organizations":[{"id":"org-wrapped"}]}"#
        XCTAssertEqual(
            ClaudeOrganizationsResponseParser.firstOrganizationID(from: json),
            "org-wrapped"
        )
    }

    func testParsesSingleOrganizationObject() {
        let json = #"{"uuid":"org-single"}"#
        XCTAssertEqual(
            ClaudeOrganizationsResponseParser.firstOrganizationID(from: json),
            "org-single"
        )
    }

    func testPrefersChatOrganizationOverAPIOnlyOrganization() {
        let json = """
        [
          {"uuid":"org-api","capabilities":["api"]},
          {"uuid":"org-chat","capabilities":["api","chat"]}
        ]
        """
        XCTAssertEqual(
            ClaudeOrganizationsResponseParser.firstOrganizationID(from: json),
            "org-chat"
        )
    }

    func testRejectsEmptyOrInvalidResponses() {
        XCTAssertNil(ClaudeOrganizationsResponseParser.firstOrganizationID(from: "[]"))
        XCTAssertNil(ClaudeOrganizationsResponseParser.firstOrganizationID(from: "<html></html>"))
    }
}

final class ClaudeWebAccountFingerprintTests: XCTestCase {

    func testFingerprintNormalizesEmailWithoutPersistingIt() {
        let first = claudeWebAccountFingerprint(
            from: #"{"email_address":" Person@Example.com "}"#
        )
        let second = claudeWebAccountFingerprint(
            from: #"{"email_address":"person@example.com"}"#
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.count, 64)
        XCTAssertFalse(first?.contains("person") ?? true)
    }

    func testFingerprintRejectsMissingEmail() {
        XCTAssertNil(claudeWebAccountFingerprint(from: #"{"memberships":[]}"#))
        XCTAssertNil(claudeWebAccountFingerprint(from: "invalid"))
    }

    func testMaskedEmailKeepsOnlyTheFirstCharacterAndDomain() {
        XCTAssertEqual(
            claudeWebAccountMaskedEmail(from: #"{"email_address":"Person@Example.com"}"#),
            "p***@example.com"
        )
    }

    func testMaskedEmailRejectsUnusableAddresses() {
        XCTAssertNil(claudeWebAccountMaskedEmail(from: #"{"email_address":"@example.com"}"#))
        XCTAssertNil(claudeWebAccountMaskedEmail(from: #"{"email_address":"person@"}"#))
        XCTAssertNil(claudeWebAccountMaskedEmail(from: #"{"memberships":[]}"#))
    }
}

// MARK: - Per-account session isolation

final class ClaudeWebCookiesTests: XCTestCase {

    private func cookie(name: String, domain: String, value: String = "value") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE"
        ])!
    }

    func testSelectsSessionCookiesInEveryDomainFormClaudeUses() {
        // claude.ai answers with a host-only cookie of its own, so both forms
        // have to go before another account's session is installed.
        let cookies = [
            cookie(name: "sessionKey", domain: "claude.ai"),
            cookie(name: "sessionKey", domain: ".claude.ai"),
            cookie(name: "sessionKey", domain: "app.claude.ai")
        ]
        XCTAssertEqual(ClaudeWebCookies.sessionCookies(in: cookies).count, 3)
    }

    func testLeavesUnrelatedCookiesAlone() {
        let cookies = [
            cookie(name: "lastActiveOrg", domain: ".claude.ai"),
            cookie(name: "__cf_bm", domain: ".claude.ai"),
            cookie(name: "sessionKey", domain: ".example.com")
        ]
        XCTAssertTrue(ClaudeWebCookies.sessionCookies(in: cookies).isEmpty)
    }

    func testInstalledSessionCookieIsScopedToClaudeAndSecure() throws {
        let cookie = try XCTUnwrap(ClaudeWebCookies.sessionCookie(value: "session-value"))
        XCTAssertEqual(cookie.name, "sessionKey")
        XCTAssertEqual(cookie.domain, ".claude.ai")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(ClaudeWebCookies.isSessionCookie(cookie))
    }
}

final class ClaudeWebIdentityTests: XCTestCase {

    func testFindsTheProfileThatAlreadyOwnsALogin() {
        let mine = ClaudeAccount(name: "Second", webAccountFingerprint: nil)
        let theirs = ClaudeAccount(name: "First", webAccountFingerprint: "fingerprint-a")

        XCTAssertEqual(
            ClaudeWebIdentity.conflictingAccountName(
                for: "fingerprint-a", in: [theirs, mine], excluding: mine.id
            ),
            "First"
        )
    }

    func testReconnectingTheSameProfileIsNotAConflict() {
        let account = ClaudeAccount(name: "First", webAccountFingerprint: "fingerprint-a")

        XCTAssertNil(
            ClaudeWebIdentity.conflictingAccountName(
                for: "fingerprint-a", in: [account], excluding: account.id
            )
        )
    }

    func testDistinctLoginsDoNotConflict() {
        let first = ClaudeAccount(name: "First", webAccountFingerprint: "fingerprint-a")
        let second = ClaudeAccount(name: "Second", webAccountFingerprint: "fingerprint-b")

        XCTAssertNil(
            ClaudeWebIdentity.conflictingAccountName(
                for: "fingerprint-b", in: [first, second], excluding: second.id
            )
        )
    }

    func testDropsIdentitiesRecordedOnSeveralProfiles() {
        let accounts = [
            ClaudeAccount(name: "First", webOrganizationID: "org", webAccountFingerprint: "shared"),
            ClaudeAccount(name: "Second", webOrganizationID: "org", webAccountFingerprint: "shared"),
            ClaudeAccount(name: "Third", webOrganizationID: "org", webAccountFingerprint: "own")
        ]

        let repaired = ClaudeWebIdentity.clearingDuplicateIdentities(in: accounts)

        XCTAssertNil(repaired[0].webAccountFingerprint)
        XCTAssertNil(repaired[1].webAccountFingerprint)
        XCTAssertEqual(repaired[2].webAccountFingerprint, "own")
        // Sessions and organizations survive; only the untrustworthy identity goes.
        XCTAssertEqual(repaired.map(\.id), accounts.map(\.id))
        XCTAssertEqual(repaired.compactMap(\.webOrganizationID).count, 3)
    }

    func testLeavesSoundIdentitiesUntouched() {
        let accounts = [
            ClaudeAccount(name: "First", webAccountFingerprint: "a"),
            ClaudeAccount(name: "Second", webAccountFingerprint: "b"),
            ClaudeAccount(name: "Third", webAccountFingerprint: nil)
        ]

        XCTAssertEqual(
            ClaudeWebIdentity.clearingDuplicateIdentities(in: accounts).map(\.webAccountFingerprint),
            ["a", "b", nil]
        )
    }
}

// MARK: - Diagnostics

final class ClaudeUsageDiagnosticsTests: XCTestCase {

    private let organizationID = "11111111-2222-3333-4444-555555555555"

    private func input() -> ClaudeUsageDiagnostics.Input {
        let first = ClaudeAccount(
            name: "First", webOrganizationID: organizationID, webAccountFingerprint: "fingerprint-a"
        )
        let second = ClaudeAccount(
            name: "Second", webOrganizationID: organizationID, webAccountFingerprint: "fingerprint-b"
        )
        return ClaudeUsageDiagnostics.Input(
            accounts: [first, second],
            sessionKeys: [first.id: "session-secret-a", second.id: "session-secret-b"],
            snapshots: [
                first.id: UsageSnapshot(
                    fiveHour: UsagePeriod(utilization: 0, resetsAt: Date(timeIntervalSince1970: 3_600)),
                    sevenDay: UsagePeriod(utilization: 49, resetsAt: Date(timeIntervalSince1970: 7_200)),
                    fable: nil,
                    lastUpdated: Date(timeIntervalSince1970: 0)
                )
            ]
        )
    }

    func testReportRevealsNoSecrets() {
        let report = ClaudeUsageDiagnostics.report(for: input(), now: Date(timeIntervalSince1970: 600))

        for secret in [organizationID, "fingerprint-a", "fingerprint-b", "session-secret-a", "session-secret-b"] {
            XCTAssertFalse(report.contains(secret), "diagnostics leaked \(secret)")
        }
    }

    func testReportGroupsSharedAndDistinctValues() {
        let report = ClaudeUsageDiagnostics.report(for: input(), now: Date(timeIntervalSince1970: 600))

        XCTAssertTrue(report.contains("accounts: 2"))
        XCTAssertTrue(report.contains("stored web sessions: 2"))
        // One shared organization, two separate logins and sessions.
        XCTAssertTrue(report.contains("distinct organizations: 1"))
        XCTAssertTrue(report.contains("distinct identities: 2"))
        XCTAssertTrue(report.contains("distinct sessions: 2"))
        XCTAssertEqual(report.components(separatedBy: "organization group: A").count - 1, 2)
        XCTAssertTrue(report.contains("identity group: A"))
        XCTAssertTrue(report.contains("identity group: B"))
    }

    func testReportShowsUsageAndMissingFetches() {
        let report = ClaudeUsageDiagnostics.report(for: input(), now: Date(timeIntervalSince1970: 600))

        XCTAssertTrue(report.contains("5h 0%"))
        XCTAssertTrue(report.contains("weekly 49%"))
        XCTAssertTrue(report.contains("never fetched"))
    }

    func testReportWarnsWhenTwoProfilesShareOneSession() {
        let first = ClaudeAccount(name: "First", webOrganizationID: "org", webAccountFingerprint: "a")
        let second = ClaudeAccount(name: "Second", webOrganizationID: "org", webAccountFingerprint: "b")
        let shared = ClaudeUsageDiagnostics.Input(
            accounts: [first, second],
            sessionKeys: [first.id: "same-session", second.id: "same-session"],
            snapshots: [:]
        )

        let report = ClaudeUsageDiagnostics.report(for: shared, now: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(report.contains("distinct sessions: 1"))
        XCTAssertTrue(report.contains("warning: two profiles hold the same Claude.ai session"))
    }
}

final class WebSessionFileStoreTests: XCTestCase {

    func testStoresSessionsInAUserOnlyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("web-sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WebSessionFileStore(fileURL: fileURL)
        let accountID = UUID()
        XCTAssertNil(try store.sessionKey(for: accountID))

        try store.save("test-session", for: accountID)
        XCTAssertEqual(try store.sessionKey(for: accountID), "test-session")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)

        store.delete(for: accountID)
        XCTAssertNil(try store.sessionKey(for: accountID))
    }
}

// MARK: - calculateUtilization

final class CalculateUtilizationTests: XCTestCase {

    func testZeroTokensIsZeroPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 0, limit: 100_000), 0)
    }

    func testHalfLimitIsFiftyPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 100_000), 50)
    }

    func testExceedingLimitCapsAtHundred() {
        XCTAssertEqual(calculateUtilization(tokens: 200_000, limit: 100_000), 100)
    }

    func testExactLimitIsHundredPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 100_000, limit: 100_000), 100)
    }

    func testZeroLimitReturnsZero() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 0), 0)
    }

    func testRoundsDown() {
        XCTAssertEqual(calculateUtilization(tokens: 1, limit: 3), 33)
    }
}

// MARK: - formatTimeRemaining

final class FormatTimeRemainingTests: XCTestCase {

    func testPastDateReturnsNow() {
        let past = Date().addingTimeInterval(-60)
        XCTAssertEqual(formatTimeRemaining(until: past), "now")
    }

    func testFortyFiveMinutesRemaining() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(45 * 60), from: now), "45m")
    }

    func testTwoHoursThirtyMinutes() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(2 * 3600 + 30 * 60), from: now), "2h 30m")
    }

    func testExactlyOneHour() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(3600), from: now), "1h 0m")
    }

    func testRoundsPartialMinuteUp() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(59), from: now), "1m")
    }

    func testRoundsResetTimestampToNearestMinute() {
        XCTAssertEqual(
            roundedToNearestMinute(Date(timeIntervalSince1970: 119)),
            Date(timeIntervalSince1970: 120)
        )
        XCTAssertEqual(
            roundedToNearestMinute(Date(timeIntervalSince1970: 121)),
            Date(timeIntervalSince1970: 120)
        )
    }
}
