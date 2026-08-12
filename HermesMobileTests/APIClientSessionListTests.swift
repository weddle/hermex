import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

/// Session list + search contract tests for the native Hermes Agent dashboard
/// REST surface: `GET /api/sessions` (archived/limit paging), `GET /api/sessions/search`
/// (`q` + `limit`), and tolerant decoding of `NativeSessionRow` rows.
final class APIClientSessionListTests: APIClientTestCase {
    func testSessionsDecodesSnakeCaseResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            // The native list pages by `archived` + `limit`; the default fetch
            // excludes archived rows with a 100-row page.
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["archived": "exclude", "limit": "100"])

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "abc123",
                  "title": "Planning",
                  "message_count": 7,
                  "last_activity_at": 1770000000,
                  "pinned": true,
                  "archived": false
                }
              ],
              "total": 1
            }
            """, for: request)
        }

        let response = try await client.sessions()

        XCTAssertEqual(response.sessions?.first?.sessionId, "abc123")
        XCTAssertEqual(response.sessions?.first?.title, "Planning")
        XCTAssertEqual(response.sessions?.first?.messageCount, 7)
        XCTAssertEqual(response.sessions?.first?.lastMessageAt, 1_770_000_000)
        XCTAssertEqual(response.sessions?.first?.pinned, true)
        XCTAssertEqual(response.archivedCount, 1)
    }

    func testSessionsDecodesDelegationAndReadOnlyMetadataTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "subagent-child",
                  "source": "subagent",
                  "source_tag": "subagent",
                  "parent_session_id": "parent-1",
                  "relationship_type": "child_session",
                  "future_field": {"nested": true}
                },
                {
                  "session_id": "legacy-row",
                  "cwd": "/tmp/w"
                },
                {
                  "session_id": "older-server-row"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.sessions()
        let sessions = try XCTUnwrap(response.sessions)
        let child = try XCTUnwrap(sessions.first)

        // Native rows collapse source/source_label/raw_source into `source`.
        XCTAssertEqual(child.sourceTag, "subagent")
        XCTAssertEqual(child.rawSource, "subagent")
        XCTAssertEqual(child.sessionSource, "subagent")
        XCTAssertEqual(child.sourceLabel, "subagent")
        XCTAssertEqual(child.parentSessionId, "parent-1")
        XCTAssertEqual(child.relationshipType, "child_session")
        XCTAssertTrue(child.isDelegatedSubagentSession)

        // Delegated children are runner-owned and view-only.
        XCTAssertTrue(child.isSessionReadOnly)

        // The native row does not carry a separate read_only flag for others.
        XCTAssertNil(sessions[2].readOnly)
        XCTAssertFalse(sessions[2].isDelegatedSubagentSession)
        XCTAssertFalse(sessions[2].isSessionReadOnly)

        // Unknown keys are ignored; source/parent fields decode tolerantly as nil.
        XCTAssertEqual(sessions[1].workspace, "/tmp/w")
        XCTAssertNil(sessions[2].sourceTag)
        XCTAssertNil(sessions[2].parentSessionId)
        XCTAssertNil(sessions[2].relationshipType)
    }

    func testSessionsIncludeArchivedBuildsQueryAndDecodesMergedRows() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["archived": "include", "limit": "50"])

            // Each row carries an `archived` flag; the server counts archived rows
            // in `total` when requested with archived=include.
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "visible-1",
                  "title": "Visible",
                  "archived": false
                },
                {
                  "session_id": "archived-1",
                  "title": "Old research",
                  "archived": true
                }
              ],
              "total": 2
            }
            """, for: request)
        }

        let response = try await client.sessions(includeArchived: true, archivedLimit: 50)

        XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["visible-1", "archived-1"])
        XCTAssertEqual(response.sessions?.last?.archived, true)
        // Tolerant decoding: a server that omits `total` still decodes.
        XCTAssertEqual(response.archivedCount, 2)
    }

    func testSessionSearchRequestBuildsExpectedQueryAndDecodesResultRows() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/search")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            // Native FTS5 search only pages by `q` + `limit`; `content`/`depth`
            // knobs are ignored.
            XCTAssertEqual(query["q"], "billing plan")
            XCTAssertEqual(query["limit"], "20")
            XCTAssertNil(query["content"])
            XCTAssertNil(query["depth"])

            return apiTestJSONResponse("""
            {
              "results": [
                {
                  "session_id": "content-123",
                  "title": "Planning",
                  "unexpected": "ignored"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.searchSessions(query: "billing plan", content: true, depth: 5)

        XCTAssertEqual(response.query, "billing plan")
        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.sessions?.first?.sessionId, "content-123")
        XCTAssertNil(response.sessions?.first?.matchType)
    }

    func testSessionSearchDecodesEmptyQueryResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/search")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["q"], "")
            XCTAssertEqual(query["limit"], "20")

            return apiTestJSONResponse("""
            {
              "results": [
                {
                  "session_id": "abc123",
                  "title": "Planning"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.searchSessions(query: "", content: true, depth: 5)

        XCTAssertEqual(response.sessions?.first?.sessionId, "abc123")
        XCTAssertNil(response.sessions?.first?.matchType)
        XCTAssertEqual(response.query, "")
        XCTAssertEqual(response.count, 1)
    }
}
