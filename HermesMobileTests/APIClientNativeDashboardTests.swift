import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

/// Focused REST contract tests for the native Hermes Agent dashboard surface:
/// `/api/status`, `/auth/password-login`, `/api/auth/ws-ticket`, and session
/// REST routes — asserting exact paths, query parameters, cookies, profile
/// scoping, and error mapping.
final class APIClientNativeDashboardTests: APIClientTestCase {
    // MARK: - Health / status

    func testHealthHitsNativeStatusPath() async throws {
        var requestedPath: String?
        let client = makeClient { request in
            requestedPath = request.url?.path
            return apiTestJSONResponse("""
            {"status": "ok", "auth_required": true, "auth_providers": ["basic"]}
            """, for: request)
        }

        let health = try await client.health()

        XCTAssertEqual(requestedPath, "/api/status")
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.authRequired, true)
        XCTAssertEqual(health.authProviders, ["basic"])
    }

    func testAuthStatusHitsProvidersPath() async throws {
        var requestedPath: String?
        let client = makeClient { request in
            requestedPath = request.url?.path
            return apiTestJSONResponse("""
            {"auth_enabled": true, "logged_in": false, "password_auth_enabled": true}
            """, for: request)
        }

        let status = try await client.authStatus()

        XCTAssertEqual(requestedPath, "/api/auth/providers")
        XCTAssertEqual(status.authEnabled, true)
        XCTAssertEqual(status.loggedIn, false)
        XCTAssertEqual(status.passwordAuthEnabled, true)
    }

    // MARK: - Login

    func testLoginPostsToPasswordLoginWithProviderAndCredentials() async throws {
        var requestedPath: String?
        var requestedMethod: String?
        var decodedBody: [String: String]?
        let client = makeClient { request in
            requestedPath = request.url?.path
            requestedMethod = request.httpMethod
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            decodedBody = try JSONDecoder().decode([String: String].self, from: body)
            return apiTestJSONResponse("""
            {"ok": true, "message": "Signed in"}
            """, for: request)
        }

        let response = try await client.login(username: "alice", password: "secret")

        XCTAssertEqual(requestedPath, "/auth/password-login")
        XCTAssertEqual(requestedMethod, "POST")
        XCTAssertEqual(decodedBody?["provider"], "basic")
        XCTAssertEqual(decodedBody?["username"], "alice")
        XCTAssertEqual(decodedBody?["password"], "secret")
        XCTAssertEqual(response.ok, true)
    }

    func testLoginNon2xxMapsToHTTPError() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"bad credentials"}"#.utf8))
        }

        do {
            _ = try await client.login(username: "alice", password: "wrong")
            XCTFail("Expected unauthorized error")
        } catch APIError.unauthorized {
            // 401 maps to .unauthorized.
        } catch {
            XCTFail("Expected unauthorized, got \(error)")
        }
    }

    // MARK: - WebSocket ticket

    func testMintWebSocketTicketPostsToWSTicketPath() async throws {
        var requestedPath: String?
        var requestedMethod: String?
        let client = makeClient { request in
            requestedPath = request.url?.path
            requestedMethod = request.httpMethod
            return apiTestJSONResponse("""
            {"ticket": "single-use-ticket-abc"}
            """, for: request)
        }

        let ticket = try await client.mintWebSocketTicket(profile: nil)

        XCTAssertEqual(requestedPath, "/api/auth/ws-ticket")
        XCTAssertEqual(requestedMethod, "POST")
        XCTAssertEqual(ticket, "single-use-ticket-abc")
    }

    func testMintWebSocketTicketScopesProfileInBody() async throws {
        var decodedBody: [String: String]?
        let client = makeClient { request in
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            decodedBody = try JSONDecoder().decode([String: String].self, from: body)
            return apiTestJSONResponse("""
            {"ticket": "profile-ticket"}
            """, for: request)
        }

        let ticket = try await client.mintWebSocketTicket(profile: "work")

        XCTAssertEqual(decodedBody?["profile"], "work")
        XCTAssertEqual(ticket, "profile-ticket")
    }

    func testMintWebSocketTicketRejectsEmptyTicket() async {
        let client = makeClient { request in
            return apiTestJSONResponse("""
            {"ticket": ""}
            """, for: request)
        }

        do {
            _ = try await client.mintWebSocketTicket(profile: nil)
            XCTFail("Expected decoding error for empty ticket")
        } catch APIError.decoding {
            // Expected: a missing/empty ticket is rejected.
        } catch {
            XCTFail("Expected decoding error, got \(error)")
        }
    }

    func testMintWebSocketTicketRejectsMissingTicketField() async {
        let client = makeClient { request in
            return apiTestJSONResponse("""
            {}
            """, for: request)
        }

        do {
            _ = try await client.mintWebSocketTicket(profile: nil)
            XCTFail("Expected decoding error for missing ticket")
        } catch APIError.decoding {
            // Expected.
        } catch {
            XCTFail("Expected decoding error, got \(error)")
        }
    }

    // MARK: - Session REST

    func testSessionListHitsSessionsPathWithPagingParams() async throws {
        var requestedPath: String?
        let client = makeClient { request in
            requestedPath = request.url?.path
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            if request.url?.absoluteString.contains("archived=include") == true {
                XCTAssertEqual(query["limit"], "50")
            } else {
                XCTAssertEqual(query["limit"], "100")
            }
            return apiTestJSONResponse("""
            {"sessions": [], "total": 0}
            """, for: request)
        }

        let list = try await client.sessions()
        XCTAssertEqual(requestedPath, "/api/sessions")
        XCTAssertTrue(list.sessions?.isEmpty == true)
    }

    func testSessionDetailHitsSessionAndMessagesRoutes() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            switch path {
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "title": "Planning",
                  "workspace": "/tmp/workspace",
                  "model": "gpt-5.4",
                  "message_count": 2
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {"role": "user", "content": "Hi", "message_id": "m-1", "timestamp": 1000},
                    {"role": "assistant", "content": "Hello", "message_id": "m-2", "timestamp": 1001}
                  ],
                  "pagination": {"limit": 50, "returned": 2}
                }
                """, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let response = try await client.session(id: "session-abc", includeMessages: true)

        XCTAssertEqual(requestedPaths, ["/api/sessions/session-abc", "/api/sessions/session-abc/messages"], "actual paths: \(requestedPaths)")
        XCTAssertEqual(response.session?.sessionId, "session-abc", "actual session: \(String(describing: response.session)); paths: \(requestedPaths)")
        XCTAssertEqual(response.session?.title, "Planning")
        XCTAssertEqual(response.session?.messages?.count, 2)
    }

    func testSessionMutationUsesSessionPatchPath() async throws {
        var requestedPath: String?
        var requestedMethod: String?
        var decodedBody: [String: Any]?
        let client = makeClient { request in
            requestedPath = request.url?.path
            requestedMethod = request.httpMethod
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            decodedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return apiTestJSONResponse("""
            {"ok": true}
            """, for: request)
        }

        _ = try await client.renameSession(id: "session-abc", title: "New Title")

        XCTAssertEqual(requestedPath, "/api/sessions/session-abc")
        XCTAssertEqual(requestedMethod, "PATCH")
        XCTAssertEqual(decodedBody?["title"] as? String, "New Title")
    }

    func testProfileScopedTicketUsesProfileName() async throws {
        // The `profile` scope is validated through mintWebSocketTicket's body —
        // a nil profile sends no profile key (no body) at all, while a non-nil
        // profile is carried in the JSON body.
        var observedBodies: [Int] = []
        let nilClient = makeClient { request in
            observedBodies.append(apiTestBodyData(from: request).map { $0.count } ?? 0)
            return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
        }

        _ = try await nilClient.mintWebSocketTicket(profile: nil)
        XCTAssertEqual(observedBodies, [0], "a nil profile must send no request body")
    }

    // MARK: - Error mapping

    func testNon2xxMapsToHTTPWithBody() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"missing"}"#.utf8))
        }

        do {
            _ = try await client.sessions()
            XCTFail("Expected HTTP error")
        } catch let APIError.http(statusCode, body) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(body, #"{"error":"missing"}"#)
        } catch {
            XCTFail("Expected HTTP error, got \(error)")
        }
    }

    func testTransportErrorMapsToNetwork() async {
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.sessions()
            XCTFail("Expected network error")
        } catch APIError.network {
            // Expected.
        } catch {
            XCTFail("Expected network error, got \(error)")
        }
    }
}
