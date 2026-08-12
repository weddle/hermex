import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APINativeContractReadinessTests: XCTestCase {
    /// Every endpoint case in the native `Endpoint` enum must have a contract
    /// row here with its exact resolved path + query, so a drift in the app's
    /// routing surfaces as a failing test rather than a silent path change.
    func testEndpointContractMatrixMatchesNativeDashboardPaths() throws {
        let contracts: [EndpointContract] = [
            .init(name: "health", method: "GET", endpoint: .health, path: "/api/status"),
            .init(name: "auth status", method: "GET", endpoint: .authStatus, path: "/api/auth/providers"),
            .init(name: "login", method: "POST", endpoint: .login, path: "/auth/password-login"),
            .init(name: "logout", method: "POST", endpoint: .logout, path: "/auth/logout"),
            .init(name: "ws ticket", method: "POST", endpoint: .wsTicket, path: "/api/auth/ws-ticket"),
            .init(name: "sessions", method: "GET", endpoint: .sessions(), path: "/api/sessions", query: ["archived": "exclude", "limit": "100"]),
            .init(
                name: "sessions including archived",
                method: "GET",
                endpoint: .sessions(includeArchived: true, limit: 50),
                path: "/api/sessions",
                query: ["archived": "include", "limit": "50"]
            ),
            .init(
                name: "session search",
                method: "GET",
                endpoint: .sessionsSearch(query: "billing plan", limit: 20),
                path: "/api/sessions/search",
                query: ["q": "billing plan", "limit": "20"]
            ),
            .init(name: "session detail", method: "GET", endpoint: .session(id: "session-123"), path: "/api/sessions/session-123"),
            .init(
                name: "session messages",
                method: "GET",
                endpoint: .sessionMessages(id: "session-123", limit: 50, offset: nil, order: nil),
                path: "/api/sessions/session-123/messages",
                query: ["limit": "50"]
            ),
            .init(name: "session patch", method: "PATCH", endpoint: .sessionPatch(id: "session-123"), path: "/api/sessions/session-123"),
            .init(name: "delete session", method: "DELETE", endpoint: .deleteSession(id: "session-123"), path: "/api/sessions/session-123"),
            .init(
                name: "export session",
                method: "GET",
                endpoint: .exportSession(sessionID: "session-123", format: .json),
                path: "/api/session/export",
                query: ["session_id": "session-123", "format": "json"]
            ),
            .init(
                name: "chat stream status",
                method: "GET",
                endpoint: .chatStreamStatus(streamID: "stream-123"),
                path: "/api/chat/stream/status",
                query: ["stream_id": "stream-123"]
            ),
            .init(name: "chat steer", method: "POST", endpoint: .chatSteer, path: "/api/chat/steer"),
            .init(name: "workspace roots", method: "GET", endpoint: .workspaceRoots, path: "/api/fs/default-cwd"),
            .init(
                name: "workspace suggestions",
                method: "GET",
                endpoint: .workspaceSuggestions(prefix: "/Users/uzair"),
                path: "/api/fs/list",
                query: ["path": "/Users/uzair"]
            ),
            .init(
                name: "directory list root",
                method: "GET",
                endpoint: .directoryList(path: nil),
                path: "/api/fs/list"
            ),
            .init(
                name: "directory list nested",
                method: "GET",
                endpoint: .directoryList(path: "Sources/App.swift"),
                path: "/api/fs/list",
                query: ["path": "Sources/App.swift"]
            ),
            .init(
                name: "file read text",
                method: "GET",
                endpoint: .file(path: "Sources/App.swift"),
                path: "/api/fs/read-text",
                query: ["path": "Sources/App.swift"]
            ),
            .init(
                name: "raw file download",
                method: "GET",
                endpoint: .rawFile(path: "Assets/icon.png"),
                path: "/api/files/download",
                query: ["path": "Assets/icon.png"]
            ),
            .init(
                name: "media download",
                method: "GET",
                endpoint: .media(path: "Assets/icon.png"),
                path: "/api/files/download",
                query: ["path": "Assets/icon.png"]
            ),
            .init(
                name: "git status",
                method: "GET",
                endpoint: .gitStatus(path: "/tmp/repo"),
                path: "/api/git/status",
                query: ["path": "/tmp/repo"]
            ),
            .init(
                name: "git branches",
                method: "GET",
                endpoint: .gitBranches(path: "/tmp/repo"),
                path: "/api/git/branches",
                query: ["path": "/tmp/repo"]
            ),
            .init(
                name: "git review diff",
                method: "GET",
                endpoint: .gitDiff(path: "/tmp/repo", file: "src/main.swift", kind: "staged"),
                path: "/api/git/review/diff",
                query: ["path": "/tmp/repo", "file": "src/main.swift", "scope": "uncommitted", "staged": "true"]
            ),
            .init(name: "git branch switch", method: "POST", endpoint: .gitBranchSwitch, path: "/api/git/branch/switch"),
            .init(name: "git stage", method: "POST", endpoint: .gitStage, path: "/api/git/review/stage"),
            .init(name: "git unstage", method: "POST", endpoint: .gitUnstage, path: "/api/git/review/unstage"),
            .init(name: "git revert", method: "POST", endpoint: .gitRevert, path: "/api/git/review/revert"),
            .init(name: "git commit", method: "POST", endpoint: .gitCommit, path: "/api/git/review/commit"),
            .init(name: "git push", method: "POST", endpoint: .gitPush, path: "/api/git/review/push"),
            .init(name: "model options", method: "GET", endpoint: .modelOptions(profile: nil, refresh: false), path: "/api/model/options"),
            .init(
                name: "model options refresh + profile",
                method: "GET",
                endpoint: .modelOptions(profile: "work", refresh: true),
                path: "/api/model/options",
                query: ["refresh": "1", "profile": "work"]
            ),
            .init(name: "model set", method: "POST", endpoint: .modelSet, path: "/api/model/set"),
            .init(name: "profiles", method: "GET", endpoint: .profiles, path: "/api/profiles"),
            .init(name: "active profile", method: "GET", endpoint: .activeProfile, path: "/api/profiles/active"),
            .init(name: "switch profile", method: "POST", endpoint: .switchProfile, path: "/api/profiles/active"),
            .init(name: "create profile", method: "POST", endpoint: .createProfile, path: "/api/profiles"),
            .init(name: "crons", method: "GET", endpoint: .crons, path: "/api/cron/jobs"),
            .init(name: "cron create", method: "POST", endpoint: .cronCreate, path: "/api/cron/jobs"),
            .init(name: "cron update", method: "PATCH", endpoint: .cronUpdate(jobID: "job-123"), path: "/api/cron/jobs/job-123"),
            .init(name: "cron delete", method: "DELETE", endpoint: .cronDelete(jobID: "job-123"), path: "/api/cron/jobs/job-123"),
            .init(name: "cron run", method: "POST", endpoint: .cronRun(jobID: "job-123"), path: "/api/cron/jobs/job-123/trigger"),
            .init(name: "cron pause", method: "POST", endpoint: .cronPause(jobID: "job-123"), path: "/api/cron/jobs/job-123/pause"),
            .init(name: "cron resume", method: "POST", endpoint: .cronResume(jobID: "job-123"), path: "/api/cron/jobs/job-123/resume"),
            .init(
                name: "cron runs",
                method: "GET",
                endpoint: .cronRuns(jobID: "job-123", limit: 5),
                path: "/api/cron/jobs/job-123/runs",
                query: ["limit": "5"]
            ),
            .init(name: "cron delivery options", method: "GET", endpoint: .cronDeliveryOptions, path: "/api/cron/delivery-targets"),
            .init(name: "memory", method: "GET", endpoint: .memory, path: "/api/memory"),
            .init(name: "memory write", method: "POST", endpoint: .memoryWrite, path: "/api/memory/write"),
            .init(name: "skills", method: "GET", endpoint: .skills, path: "/api/skills"),
            .init(
                name: "skill content",
                method: "GET",
                endpoint: .skillContent(name: "swiftui-ui-patterns", file: nil),
                path: "/api/skills/content",
                query: ["name": "swiftui-ui-patterns"]
            ),
            .init(
                name: "skill linked file",
                method: "GET",
                endpoint: .skillContent(name: "swiftui-ui-patterns", file: "references/navigation.md"),
                path: "/api/skills/content",
                query: ["name": "swiftui-ui-patterns", "file": "references/navigation.md"]
            ),
            .init(name: "toggle skill", method: "POST", endpoint: .toggleSkill, path: "/api/skills/toggle"),
            .init(name: "upload", method: "POST", endpoint: .upload, path: "/api/upload")
        ]

        let baseURL = URL(string: "https://example.test")!

        for contract in contracts {
            let url = contract.endpoint.url(relativeTo: baseURL)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false), contract.name)

            XCTAssertEqual(components.path, contract.path, "\(contract.name) path")
            XCTAssertEqual(queryDictionary(from: components), contract.query, "\(contract.name) query")
            XCTAssertTrue(["GET", "POST", "PATCH", "DELETE"].contains(contract.method), "\(contract.name) method")
        }
    }

    func testNativeJSONMutationsOmitBrowserCSRFHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job-123/pause")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            // `pauseCron` with no reason sends an empty mutation: no JSON body and
            // therefore no Content-Type header from the native client.
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertNil(apiTestBodyData(from: request))

            return apiTestJSONResponse("""
            {"ok": true}
            """, for: request)
        }

        let response = try await client.pauseCron(jobID: "job-123")

        XCTAssertEqual(response.ok, true)
    }

    func testMultipartPostRequestsOmitBrowserCSRFHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            // Native uploads POST a JSON data_url body (not browser multipart), so
            // the request carries the JSON content type, never a multipart boundary.
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "path": "/tmp/workspace/contract.txt",
              "entry": {
                "name": "contract.txt",
                "path": "/tmp/workspace/contract.txt",
                "size": 8,
                "mime_type": "text/plain"
              }
            }
            """, for: request)
        }

        let response = try await client.uploadFile(sessionID: "abc123", data: Data("contract".utf8), filename: "contract.txt")

        XCTAssertEqual(response.filename, "contract.txt")
        XCTAssertEqual(response.path, "/tmp/workspace/contract.txt")
        XCTAssertEqual(response.size, 8)
        XCTAssertEqual(response.mime, "text/plain")
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    private func queryDictionary(from components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private struct EndpointContract {
    let name: String
    let method: String
    let endpoint: Endpoint
    let path: String
    let query: [String: String]

    init(name: String, method: String, endpoint: Endpoint, path: String, query: [String: String] = [:]) {
        self.name = name
        self.method = method
        self.endpoint = endpoint
        self.path = path
        self.query = query
    }
}
