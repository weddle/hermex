import Foundation

struct HealthResponse: Decodable {
    let status: String?
    let sessions: Int?
    let activeStreams: Int?
    let uptimeSeconds: Double?
    /// Native dashboard `/api/status`: whether the gate engages.
    let authRequired: Bool?
    /// Native dashboard `/api/status`: advertised auth providers (["basic"] | ["nous"]).
    let authProviders: [String]?

    init(
        status: String? = nil,
        sessions: Int? = nil,
        activeStreams: Int? = nil,
        uptimeSeconds: Double? = nil,
        authRequired: Bool? = nil,
        authProviders: [String]? = nil
    ) {
        self.status = status
        self.sessions = sessions
        self.activeStreams = activeStreams
        self.uptimeSeconds = uptimeSeconds
        self.authRequired = authRequired
        self.authProviders = authProviders
    }
}

struct AuthStatusResponse: Decodable {
    let authEnabled: Bool?
    let loggedIn: Bool?
    /// Finer-grained capabilities newer servers report. All optional so older
    /// servers that omit them decode unchanged. `password_auth_enabled == false`
    /// (and only an explicit false) marks a passkey-only server we can't sign
    /// into yet (#255); a missing value means "unknown" → treat as today.
    let passwordAuthEnabled: Bool?
    let passkeysEnabled: Bool?
    let passwordlessEnabled: Bool?

    init(
        authEnabled: Bool? = nil,
        loggedIn: Bool? = nil,
        passwordAuthEnabled: Bool? = nil,
        passkeysEnabled: Bool? = nil,
        passwordlessEnabled: Bool? = nil
    ) {
        self.authEnabled = authEnabled
        self.loggedIn = loggedIn
        self.passwordAuthEnabled = passwordAuthEnabled
        self.passkeysEnabled = passkeysEnabled
        self.passwordlessEnabled = passwordlessEnabled
    }
}

struct LoginResponse: Decodable {
    let ok: Bool?
    let message: String?
    let error: String?

    init(ok: Bool? = nil, message: String? = nil, error: String? = nil) {
        self.ok = ok
        self.message = message
        self.error = error
    }
}
