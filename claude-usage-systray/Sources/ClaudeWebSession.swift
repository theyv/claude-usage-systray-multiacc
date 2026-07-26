import Foundation
import WebKit

/// Cookie hygiene for claude.ai.
///
/// Usage is authorized purely by the `sessionKey` cookie, so a stale one left
/// behind silently answers for the wrong account: claude.ai re-issues its own
/// host-only `sessionKey` on every response, and a request carrying two session
/// cookies is resolved by the server rather than by us.
enum ClaudeWebCookies {
    static let sessionCookieName = "sessionKey"

    static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == sessionCookieName else { return false }
        let domain = cookie.domain.lowercased()
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    /// Every claude.ai session cookie present, in whichever domain form it was
    /// stored. Used both to read the session a login produced and to clear one
    /// before another account's is installed.
    static func sessionCookies(in cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter(isSessionCookie)
    }

    static func sessionCookie(value: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: ".claude.ai",
            .path: "/",
            .name: sessionCookieName,
            .value: value,
            .secure: "TRUE"
        ])
    }
}

enum ClaudeWebProfileError: LocalizedError {
    case cookieRejected

    var errorDescription: String? {
        "Could not install the Claude.ai session for this account."
    }
}

/// One browser profile per local account.
///
/// Sharing `WKWebsiteDataStore.default()` made a single login answer for every
/// account: the session cookie claude.ai set while refreshing the first account
/// stayed in the shared jar and outranked the cookie installed for the next one,
/// so all profiles reported identical usage. Each account now gets its own jar,
/// persistent where the OS supports it so the Cloudflare clearance earned while
/// signing in survives into later refreshes.
@MainActor
enum ClaudeWebProfileStore {
    /// WebKit rejects the all-zero UUID as a data store identifier.
    private static let unusableIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func store(for accountID: UUID) -> WKWebsiteDataStore {
        if let existing = stores[accountID] { return existing }
        var isolated: WKWebsiteDataStore?
        if #available(macOS 14.0, *) {
            if accountID != unusableIdentifier {
                isolated = WKWebsiteDataStore(forIdentifier: accountID)
            }
        }
        let resolved = isolated ?? .nonPersistent()
        stores[accountID] = resolved
        return resolved
    }

    /// Leaves exactly one claude.ai session cookie in the profile: any earlier
    /// one is removed *before* this account's is set.
    static func installOnlySessionCookie(_ sessionKey: String, in store: WKWebsiteDataStore) async throws {
        guard let cookie = ClaudeWebCookies.sessionCookie(value: sessionKey) else {
            throw ClaudeWebProfileError.cookieRejected
        }
        let cookieStore = store.httpCookieStore
        for stale in ClaudeWebCookies.sessionCookies(in: await allCookies(in: cookieStore)) {
            await delete(stale, in: cookieStore)
        }
        await set(cookie, in: cookieStore)
    }

    /// Empties a profile so a sign-in cannot inherit the previous account.
    static func removeAllData(for accountID: UUID) async {
        let dataStore = store(for: accountID)
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { continuation.resume() }
        }
    }

    /// Drops a profile entirely, used when the local account is deleted.
    static func forget(_ accountID: UUID) async {
        await removeAllData(for: accountID)
        stores[accountID] = nil
        guard accountID != unusableIdentifier else { return }
        if #available(macOS 14.0, *) {
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: accountID) { _ in continuation.resume() }
            }
        }
    }

    private static func allCookies(in cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private static func delete(_ cookie: HTTPCookie, in cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.delete(cookie) { continuation.resume() }
        }
    }

    private static func set(_ cookie: HTTPCookie, in cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) { continuation.resume() }
        }
    }
}

/// Which local profile a given Claude.ai login belongs to. Identities are only
/// ever held as a fingerprint, never as an address.
enum ClaudeWebIdentity {
    static func conflictingAccountName(
        for fingerprint: String,
        in accounts: [ClaudeAccount],
        excluding accountID: UUID
    ) -> String? {
        accounts.first { $0.id != accountID && $0.webAccountFingerprint == fingerprint }?.name
    }

    /// Before 1.2.7 every refresh shared one cookie jar, so one login could
    /// answer for all profiles and its fingerprint was stamped onto each of
    /// them. Such an identity says nothing about the session actually stored, so
    /// duplicates are dropped once and relearned from isolated refreshes.
    static func clearingDuplicateIdentities(in accounts: [ClaudeAccount]) -> [ClaudeAccount] {
        let duplicated = Set(
            Dictionary(grouping: accounts.compactMap(\.webAccountFingerprint), by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
        )
        guard !duplicated.isEmpty else { return accounts }
        return accounts.map { account in
            guard let fingerprint = account.webAccountFingerprint,
                  duplicated.contains(fingerprint) else { return account }
            var repaired = account
            repaired.webAccountFingerprint = nil
            return repaired
        }
    }
}

enum ClaudeWebSessionError: LocalizedError {
    case alreadyConnected(String)

    var errorDescription: String? {
        switch self {
        case .alreadyConnected(let accountName):
            return "This Claude.ai login is already connected as \(accountName)."
        }
    }
}
