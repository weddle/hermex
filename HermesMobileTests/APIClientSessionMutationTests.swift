import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionMutationTests: APIClientTestCase {
    func testPostRequestsEncodeSnakeCaseBody() async throws {
        // pin/unpin is a native PATCH `/api/sessions/{id}` carrying the
        // `SessionPatchRequest` body (`{pinned}`); the response is a native
        // session row.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/abc123")
            XCTAssertEqual(request.httpMethod, "PATCH")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["pinned"] as? Bool, false)
            XCTAssertNil(json?["title"])
            XCTAssertNil(json?["archived"])
            XCTAssertNil(json?["session_id"])

            return apiTestJSONResponse("""
            {
              "session_id": "abc123",
              "pinned": false
            }
            """, for: request)
        }

        let response = try await client.pinSession(id: "abc123", pinned: false)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.pinned, false)
    }

    func testBranchSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        // Branching goes through the gateway (`session.branch` after the
        // `POST /api/auth/ws-ticket` mint); the `title` is carried as the RPC's
        // `name`, and the returned object keys are the native RPC result shape.
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "session.branch": #"{"session_id":"copy123","title":"Planning (copy)","parent":"abc123"}"#
            ]
        )

        let response = try await client.branchSession(id: "abc123", title: "Planning (copy)")

        XCTAssertEqual(response.sessionId, "copy123")
        XCTAssertEqual(response.title, "Planning (copy)")
        XCTAssertEqual(response.parentSessionId, "abc123")

        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "session.branch")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "abc123")
        XCTAssertEqual(params["name"] as? String, "Planning (copy)")
        XCTAssertNil(params["count"])
    }

    func testBranchSessionIncludesKeepCountForMessageFork() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "session.branch": #"{"session_id":"fork123","title":"Planning (fork)","parent":"abc123"}"#
            ]
        )

        let response = try await client.branchSession(id: "abc123", keepCount: 29)

        XCTAssertEqual(response.sessionId, "fork123")
        XCTAssertEqual(response.title, "Planning (fork)")
        XCTAssertEqual(response.parentSessionId, "abc123")

        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "session.branch")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "abc123")
        XCTAssertEqual(params["count"] as? Int, 29)
        XCTAssertNil(params["name"])
    }

    func testCompressSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        // Compression runs over the gateway (`session.compress`); the RPC
        // result carries `status` + `summary` (+ `messages`), which the app
        // maps into `SessionCompressResponse`. No session row is returned.
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "session.compress": #"{"status":"compressed","summary":{"headline":"Compressed: 8 -> 3 messages","token_line":"Rough transcript estimate: ~1200 -> ~320 tokens"},"messages":[]}"#
            ]
        )

        let response = try await client.compressSession(id: "abc123", focusTopic: "architecture notes")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.focusTopic, "architecture notes")
        XCTAssertEqual(response.summary?.headline, "Compressed: 8 -> 3 messages")
        XCTAssertEqual(response.summary?.tokenLine, "Rough transcript estimate: ~1200 -> ~320 tokens")
        XCTAssertNil(response.summary?.note)
        XCTAssertNil(response.session)

        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "session.compress")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "abc123")
        XCTAssertEqual(params["focus_topic"] as? String, "architecture notes")
    }

    func testCompressionSummaryExtractsCompressedTokenEstimate() {
        let arrowSummary = SessionCompressionSummary(
            headline: "Compressed: 20 -> 10 messages",
            tokenLine: "Approx request size: ~30,100 \u{2192} ~10,347 tokens",
            note: nil,
            referenceMessage: nil
        )
        let asciiSummary = SessionCompressionSummary(
            headline: nil,
            tokenLine: "Rough transcript estimate: ~1200 -> ~320 tokens",
            note: nil,
            referenceMessage: nil
        )

        XCTAssertEqual(arrowSummary.compressedTokenEstimate, 10_347)
        XCTAssertEqual(asciiSummary.compressedTokenEstimate, 320)
    }

    func testSessionMetadataRequestOmitsMessageLimitWhenNil() async throws {
        // Session metadata is a plain `GET /api/sessions/{id}`; the native
        // surface has no message-limit query on the detail route (paging lives
        // on the separate messages route).
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/copy123")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)

            return apiTestJSONResponse("""
            {
              "session_id": "copy123",
              "title": "Planning (copy)",
              "message_count": 4
            }
            """, for: request)
        }

        let response = try await client.session(id: "copy123", includeMessages: false, messageLimit: nil)

        XCTAssertEqual(response.session?.sessionId, "copy123")
        XCTAssertEqual(response.session?.title, "Planning (copy)")
        XCTAssertEqual(response.session?.messageCount, 4)
    }

    func testMoveSessionBuildsExpectedBodyAndDecodesMovedSession() async throws {
        // Moving goes through the gateway `session.workspace.move` RPC, then
        // re-reads the detail via `GET /api/sessions/{id}` to refresh the
        // project attachment.
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                switch request.url?.path {
                case "/api/auth/ws-ticket":
                    return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
                case "/api/sessions/abc123":
                    return apiTestJSONResponse("""
                    {
                      "session_id": "abc123",
                      "project_id": "proj123"
                    }
                    """, for: request)
                default:
                    throw URLError(.badURL)
                }
            },
            frames: frames,
            responses: [
                "session.workspace.move": #"{"ok":true}"#
            ]
        )

        let response = try await client.moveSession(id: "abc123", projectID: "proj123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.projectId, "proj123")

        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "session.workspace.move")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "abc123")
        XCTAssertEqual(params["project_id"] as? String, "proj123")
    }

    func testMoveSessionToNoProjectOmitsProjectID() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                switch request.url?.path {
                case "/api/auth/ws-ticket":
                    return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
                case "/api/sessions/abc123":
                    return apiTestJSONResponse("""
                    {
                      "session_id": "abc123"
                    }
                    """, for: request)
                default:
                    throw URLError(.badURL)
                }
            },
            frames: frames,
            responses: [
                "session.workspace.move": #"{"ok":true}"#
            ]
        )

        let response = try await client.moveSession(id: "abc123", projectID: nil)

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.session?.projectId)

        // Moving to no project sends an explicit JSON `null` project_id on the
        // RPC wire (not a stale project identifier).
        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "session.workspace.move")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "abc123")
        XCTAssertTrue(params["project_id"] is NSNull, "expected project_id to be JSON null, got: \(String(describing: params["project_id"]))")
    }

    func testSessionMutatorMove503WithServerPayloadMapsToStreamingBusyError() async throws {
        // The gateway move RPC succeeds, then the detail re-read returns a 503
        // carrying the server's JSON error payload; `SessionMutator.move` maps
        // that to the streaming-busy error.
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                switch request.url?.path {
                case "/api/auth/ws-ticket":
                    return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
                case "/api/sessions/abc123":
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data(#"{"error": "Session is busy (streaming). Please try again in a moment."}"#.utf8))
                default:
                    throw URLError(.badURL)
                }
            },
            frames: frames,
            responses: [
                "session.workspace.move": #"{"ok":true}"#
            ]
        )

        do {
            try await SessionMutator(client: client).move(sessionID: "abc123", to: "proj123")
            XCTFail("Expected SessionMoveWhileStreamingError")
        } catch is SessionMoveWhileStreamingError {
            XCTAssertEqual(
                SessionMoveWhileStreamingError().errorDescription,
                String(localized: "This session is still responding, so it can't be moved yet. Try again when it finishes.")
            )
        }
    }

    func testSessionMutatorMoveProxy503WithoutJSONPayloadKeepsGenericAPIError() async throws {
        // A tunnel/proxy 503 on the detail re-read serves HTML, not the server's
        // JSON payload; keep the generic connectivity message for that case
        // (issue #25).
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                switch request.url?.path {
                case "/api/auth/ws-ticket":
                    return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
                case "/api/sessions/abc123":
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                    return (response, Data("<html>Service Unavailable</html>".utf8))
                default:
                    throw URLError(.badURL)
                }
            },
            frames: frames,
            responses: [
                "session.workspace.move": #"{"ok":true}"#
            ]
        )

        do {
            try await SessionMutator(client: client).move(sessionID: "abc123", to: nil)
            XCTFail("Expected APIError.http(503)")
        } catch let error as APIError {
            guard case .http(let statusCode, _) = error else {
                return XCTFail("Expected APIError.http, got \(error)")
            }
            XCTAssertEqual(statusCode, 503)
        }
    }

    func testArchiveSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        // Archive is a native PATCH `/api/sessions/{id}` with `{archived: true}`.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/abc123")
            XCTAssertEqual(request.httpMethod, "PATCH")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["archived"] as? Bool, true)
            XCTAssertNil(json?["session_id"])

            return apiTestJSONResponse("""
            {
              "session_id": "abc123",
              "archived": true
            }
            """, for: request)
        }

        let response = try await client.archiveSession(id: "abc123", archived: true)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.archived, true)
    }

    func testUnarchiveSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        // Unarchive is the same PATCH `/api/sessions/{id}` with `{archived: false}`.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/abc123")
            XCTAssertEqual(request.httpMethod, "PATCH")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["archived"] as? Bool, false)
            XCTAssertNil(json?["session_id"])

            return apiTestJSONResponse("""
            {
              "session_id": "abc123",
              "archived": false
            }
            """, for: request)
        }

        let response = try await client.archiveSession(id: "abc123", archived: false)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.archived, false)
    }

    // MARK: - Gateway test helpers

    /// Builds an `APIClient` whose `withGatewayConnection` uses a test-transport
    /// `HermesGatewayClient` (via the `gatewayFabricator` seam): the websocket
    /// handshake completes instantly and each JSON-RPC frame is captured on
    /// `frames`, then delivered a canned `result` per method. The `handler`
    /// still serves the `POST /api/auth/ws-ticket` mint (and any REST follow-up
    /// like the move detail re-read) through `MockURLProtocol`.
    private func makeGatewayClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        frames: LockedStringList,
        responses: [String: String],
        lastResult: String = #"{}"#
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = URL(string: "https://example.test")!

        return APIClient(
            baseURL: baseURL,
            session: session,
            gatewayFabricator: { _, ticket, profile, headers in
                let gateway = HermesGatewayClient(
                    baseURL: baseURL,
                    ticket: ticket,
                    profile: profile,
                    customHeaders: headers
                )
                gateway.testSendFrame = { frame in
                    frames.append(frame)
                    guard let json = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = json["id"] as? Int,
                          let method = json["method"] as? String else { return }
                    let result = responses[method] ?? lastResult
                    gateway.testDeliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
                }
                return gateway
            }
        )
    }
}
