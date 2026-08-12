//
//  DashboardCookieStore.swift
//  HermesMobile
//
//  Foundation-only persistence of the native dashboard's session cookies so the
//  app can restore a signed-in session after relaunch without re-entering the
//  password. The native password-login flow authenticates through
//  `HTTPCookieStorage.shared`; this store captures only origin-matching cookies
//  and keeps them per-server via Hermex's Keychain abstraction.
//
//  Adapted from hermes-conduit (MIT License),
//  Conduit/Services/DashboardTicketBridge.swift (DashboardCookiePersistence),
//  restricted to Foundation (no WebKit).
//

import Foundation

/// Persists and restores dashboard session cookies through Hermex's existing
/// `KeychainStoring` abstraction, scoped by normalized server URL.
@MainActor
enum DashboardCookieStore {
    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
        let sameSitePolicy: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresDate = cookie.expiresDate
            isSecure = cookie.isSecure
            isHTTPOnly = cookie.isHTTPOnly
            sameSitePolicy = cookie.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .secure: isSecure ? "TRUE" : "FALSE"
            ]
            if let expiresDate { properties[.expires] = expiresDate }
            if isHTTPOnly { properties[.init("HttpOnly")] = "TRUE" }
            if let sameSitePolicy { properties[.sameSitePolicy] = sameSitePolicy }
            return HTTPCookie(properties: properties)
        }
    }

    /// Restores the saved cookies for `serverURL` into `HTTPCookieStorage.shared`
    /// before the first probe, re-establishing a signed-in session.
    static func restore(into storage: HTTPCookieStorage = .shared, for baseURL: URL, keychain: any KeychainStoring = KeychainStore()) {
        guard let data = loadCookies(for: baseURL, keychain: keychain),
              let saved = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }
        for cookie in saved.compactMap(\.cookie) {
            storage.setCookie(cookie)
        }
    }

    /// Captures the dashboard-origin cookies from `HTTPCookieStorage.shared`
    /// for `baseURL` into the per-server Keychain record.
    static func capture(from storage: HTTPCookieStorage = .shared, for baseURL: URL, keychain: any KeychainStoring = KeychainStore()) {
        guard let host = baseURL.host?.lowercased() else { return }
        let cookies = (storage.cookies(for: baseURL) ?? []).filter { cookieMatchesHost($0, host: host) }
        guard !cookies.isEmpty,
              let data = try? JSONEncoder().encode(cookies.map(StoredCookie.init)) else {
            // No cookies to persist: clear any stale record rather than keep it.
            try? keychain.delete(.dashboardCookies, scope: baseURL.absoluteString)
            return
        }
        try? keychain.save(data.base64EncodedString(), forKey: .dashboardCookies, scope: baseURL.absoluteString)
    }

    /// Clears the persisted cookie record for one server and removes its
    /// origin-matching cookies from the shared store, so disconnect/sign-out
    /// leaves no reusable session behind.
    static func clear(for baseURL: URL, keychain: any KeychainStoring = KeychainStore()) {
        clearNativeCookies(for: baseURL)
        try? keychain.delete(.dashboardCookies, scope: baseURL.absoluteString)
    }

    /// Removes dashboard-origin cookies from the shared Foundation cookie store.
    nonisolated static func clearNativeCookies(for baseURL: URL) {
        guard let host = baseURL.host?.lowercased() else { return }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookieMatchesHost(cookie, host: host) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    private static func loadCookies(for baseURL: URL, keychain: any KeychainStoring) -> Data? {
        guard let stored = try? keychain.load(.dashboardCookies, scope: baseURL.absoluteString),
              let data = Data(base64Encoded: stored) else { return nil }
        return data
    }

    nonisolated private static func cookieMatchesHost(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        // A leading dot means the cookie applies to the host and its subdomains.
        let base = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == base || host.hasSuffix(".\(base)")
    }
}
