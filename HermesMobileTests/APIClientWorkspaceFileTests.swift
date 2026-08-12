import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientWorkspaceFileTests: APIClientTestCase {
    func testProjectsBuildsExpectedPathAndDecodesProjectList() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                XCTAssertEqual(request.httpMethod, "POST")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "projects.tree": ##"{"projects":[{"id":"proj123","label":"Client Work","color":"#336699","created_at":1770000000}]}"##,
                "projects.project_sessions": ##"{"project":{"id":"proj123","repos":[]}}"##
            ]
        )

        let response = try await client.projects()
        let project = try XCTUnwrap(response.projects?.first)

        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#336699")
        XCTAssertEqual(project.createdAt, 1_770_000_000)

        // The gateway RPC rides the test-transport socket: assert the exact
        // projects.tree method and its preview_limit param.
        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "projects.tree")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["preview_limit"] as? Int, 3)
    }

    func testProjectsToleratesLossyProjectFields() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "projects.tree": """
                {
                  "projects": [
                    {"id": "proj123", "label": "Client Work", "color": "#336699", "created_at": 1770000000},
                    {"id": 123, "label": true, "color": 456, "created_at": "1770000000"}
                  ]
                }
                """,
                "projects.project_sessions": ##"{"project":{"id":"proj123","repos":[]}}"##
            ]
        )

        let response = try await client.projects()

        // The first node decodes fully via the native tree mapping (label → name).
        let project = try XCTUnwrap(response.projects?.first)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#336699")
        XCTAssertEqual(project.createdAt, 1_770_000_000)

        // A node whose fields are the wrong type must not crash the whole list;
        // native `GatewayValue` coercion degrades those fields to nil.
        XCTAssertEqual(response.projects?.count, 2)
        let lossy = try XCTUnwrap(response.projects?[1])
        XCTAssertNil(lossy.projectId)
        XCTAssertNil(lossy.name)
        XCTAssertNil(lossy.color)
        XCTAssertNil(lossy.createdAt)
    }

    func testCreateProjectBuildsExpectedBodyAndDecodesCreatedProject() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "projects.create": ##"{"project":{"id":"proj123","name":"Client Work","color":"#7cb9ff","created_at":1770000000}}"##
            ]
        )

        let response = try await client.createProject(name: "Client Work", color: "#7cb9ff", workspace: "/tmp/client-work")
        let project = try XCTUnwrap(response.project)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#7cb9ff")
        XCTAssertEqual(project.createdAt, 1_770_000_000)

        // Assert the projects.create RPC body (name + path-based folders contract).
        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "projects.create")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "Client Work")
        XCTAssertEqual(params["folders"] as? [String], ["/tmp/client-work"])
        XCTAssertEqual(params["primary_path"] as? String, "/tmp/client-work")
        XCTAssertEqual(params["use"] as? Bool, true)
        XCTAssertNil(params["color"])
    }

    func testRenameProjectBuildsExpectedBodyAndDecodesRenamedProject() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "projects.update": ##"{"project":{"id":"proj123","name":"Client Archive","color":"#f5c542","created_at":1770000000}}"##
            ]
        )

        let response = try await client.renameProject(id: "proj123", name: "Client Archive", color: "#f5c542")
        let project = try XCTUnwrap(response.project)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Archive")
        XCTAssertEqual(project.color, "#f5c542")
        XCTAssertEqual(project.createdAt, 1_770_000_000)

        // Assert the projects.update RPC body: id + optional name/color.
        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "projects.update")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["id"] as? String, "proj123")
        XCTAssertEqual(params["name"] as? String, "Client Archive")
        XCTAssertEqual(params["color"] as? String, "#f5c542")
        XCTAssertNil(params["project_id"])
    }

    func testRenameProjectOmitsColorWhenNil() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "projects.update": #"{"project":{"id":"proj123","name":"Client Archive"}}"#
            ]
        )

        let response = try await client.renameProject(id: "proj123", name: "Client Archive", color: nil)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.project?.projectId, "proj123")
        XCTAssertEqual(response.project?.name, "Client Archive")
        XCTAssertNil(response.project?.color)

        // A nil color must not be sent on the projects.update wire.
        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "projects.update")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["id"] as? String, "proj123")
        XCTAssertEqual(params["name"] as? String, "Client Archive")
        XCTAssertNil(params["color"])
    }

    func testDeleteProjectBuildsExpectedBodyAndDecodesResponse() async throws {
        let frames = LockedStringList()
        let client = makeGatewayClient(
            handler: { request in
                XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
                return apiTestJSONResponse(#"{"ticket": "t"}"#, for: request)
            },
            frames: frames,
            responses: [
                "projects.delete": #"{"ok":true}"#
            ]
        )

        let response = try await client.deleteProject(id: "proj123")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.project)

        // Assert the projects.delete RPC carries the project id.
        let frame = try XCTUnwrap(frames.all.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "projects.delete")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["id"] as? String, "proj123")
        XCTAssertNil(params["project_id"])
    }

    func testWorkspacesDecodesWorkspaceObjects() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/default-cwd")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "cwd": "/Users/test/project"
            }
            """, for: request)
        }

        let response = try await client.workspaces()

        XCTAssertEqual(response.last, "/Users/test/project")
        XCTAssertEqual(response.workspaces?.first?.path, "/Users/test/project")
        XCTAssertNil(response.workspaces?.first?.name)
    }

    func testWorkspacesToleratesMissingCwd() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/default-cwd")

            return apiTestJSONResponse(#"{}"#, for: request)
        }

        let response = try await client.workspaces()

        XCTAssertNil(response.workspaces)
        XCTAssertNil(response.last)
    }

    func testWorkspaceSuggestionsBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/list")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], "/Users/test/pro")

            return apiTestJSONResponse("""
            {
              "entries": [
                {"name": "project", "path": "/Users/test/project", "type": "dir"},
                {"name": "prototypes", "path": "/Users/test/prototypes", "type": "dir"}
              ],
              "path": "/Users/test/pro"
            }
            """, for: request)
        }

        let response = try await client.workspaceSuggestions(prefix: "/Users/test/pro")

        XCTAssertEqual(response.prefix, "/Users/test/pro")
        XCTAssertEqual(response.suggestions, ["/Users/test/project", "/Users/test/prototypes"])
    }

    func testDirectoryListDecodesUpstreamEntries() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/list")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], ".")
            XCTAssertNil(query["session_id"])

            return apiTestJSONResponse("""
            {
              "entries": [
                {"name": "Sources", "path": "Sources", "type": "dir", "size": null},
                {"name": "LinkedDocs", "path": "LinkedDocs", "type": "symlink", "is_dir": true},
                {"name": "README.md", "path": "README.md", "type": "file", "size": 1200}
              ],
              "path": "."
            }
            """, for: request)
        }

        let response = try await client.directoryList(path: ".")

        XCTAssertEqual(response.path, ".")
        XCTAssertEqual(response.entries?.count, 3)
        XCTAssertEqual(response.entries?[0].name, "Sources")
        XCTAssertEqual(response.entries?[0].type, "dir")
        XCTAssertEqual(response.entries?[1].type, "symlink")
        XCTAssertEqual(response.entries?[1].isDirectory, true)
        XCTAssertEqual(response.entries?[2].size, 1200)
    }

    func testDirectoryListBuildsNestedPathQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/list")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], "Sources/App")
            XCTAssertNil(query["session_id"])

            return apiTestJSONResponse("""
            {
              "entries": [],
              "path": "Sources/App"
            }
            """, for: request)
        }

        let response = try await client.directoryList(path: "Sources/App")

        XCTAssertEqual(response.path, "Sources/App")
    }

    @MainActor
    func testFileBrowserLatestDirectoryRequestWins() async throws {
        let firstRequestStarted = expectation(description: "First directory request started")
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value

            if path == "cat" {
                firstRequestStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.3)
            }

            return apiTestJSONResponse("""
            {
              "entries": [],
              "path": "\(path ?? ".")"
            }
            """, for: request)
        }
        let viewModel = try FileBrowserViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            apiClient: client
        )

        let firstLoad = Task { await viewModel.load(path: "cat") }
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        let latestLoad = Task { await viewModel.load(path: "leetcode-editor") }

        await latestLoad.value
        await firstLoad.value

        XCTAssertEqual(viewModel.currentPath, "leetcode-editor")
    }

    @MainActor
    func testFileBrowserRetriesFailedDirectoryWithoutDiscardingCurrentEntries() async throws {
        var catAttempts = 0
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value

            if path == "cat" {
                catAttempts += 1
                if catAttempts == 1 {
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                    return (try XCTUnwrap(response), Data(#"{"error":"temporarily unavailable"}"#.utf8))
                }
            }

            return apiTestJSONResponse("""
            {
              "entries": [{"name": "cat", "path": "cat", "type": "dir"}],
              "path": "\(path ?? ".")"
            }
            """, for: request)
        }
        let viewModel = try FileBrowserViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            apiClient: client
        )

        await viewModel.loadRoot()
        await viewModel.load(path: "cat")

        XCTAssertEqual(viewModel.currentPath, ".")
        XCTAssertEqual(viewModel.entries.first?.name, "cat")
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.retryLastLoad()

        XCTAssertEqual(viewModel.currentPath, "cat")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(catAttempts, 2)
    }

    @MainActor
    func testFileBrowserCancellationDoesNotSurfaceError() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let viewModel = try FileBrowserViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            apiClient: client
        )

        await viewModel.loadRoot()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    func testFileReadBuildsExpectedQueryAndDecodesTextResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/read-text")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], "Sources/App/FilePreviewView.swift")
            XCTAssertNil(query["session_id"])

            return apiTestJSONResponse("""
            {
              "path": "Sources/App/FilePreviewView.swift",
              "content": "import SwiftUI\\n",
              "size": 15,
              "lines": 2,
              "unexpected": "ignored"
            }
            """, for: request)
        }

        let response = try await client.file(path: "Sources/App/FilePreviewView.swift")

        XCTAssertEqual(response.path, "Sources/App/FilePreviewView.swift")
        XCTAssertEqual(response.content, "import SwiftUI\n")
        XCTAssertEqual(response.size, 15)
        XCTAssertEqual(response.lines, 2)
    }

    func testFileReadToleratesMissingOptionalMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/read-text")

            return apiTestJSONResponse("""
            {
              "content": "hello"
            }
            """, for: request)
        }

        let response = try await client.file(path: "README.md")

        XCTAssertEqual(response.content, "hello")
        XCTAssertNil(response.path)
        XCTAssertNil(response.size)
        XCTAssertNil(response.lines)
    }

    func testRawFileBuildsExpectedQueryAndReturnsBytes() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/download")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], "Screenshots/result.png")
            XCTAssertNil(query["session_id"])

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), expectedData)
        }

        let response = try await client.rawFileData(path: "Screenshots/result.png")

        XCTAssertEqual(response, expectedData)
    }

    func testMediaDataBuildsExpectedQueryAndReturnsBytes() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/result image.png"
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/files/download")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], mediaPath)
            XCTAssertNil(query["session_id"])

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), expectedData)
        }

        let response = try await client.mediaData(path: mediaPath)

        XCTAssertEqual(response, expectedData)
    }

    @MainActor
    func testFilePreviewExportPayloadUsesLoadedTextContent() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/fs/read-text")

            return apiTestJSONResponse("""
            {
              "path": "Sources/Notes.txt",
              "content": "hello\\n",
              "size": 6,
              "lines": 1
            }
            """, for: request)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Sources/Notes.txt",
            apiClient: client
        )

        await viewModel.load()
        let payload = try await viewModel.exportPayload()

        XCTAssertEqual(payload.data, Data("hello\n".utf8))
        XCTAssertEqual(payload.filename, "Notes.txt")
        XCTAssertTrue(payload.contentType.conforms(to: .text))
        XCTAssertFalse(payload.isImage)
    }

    @MainActor
    func testFilePreviewExportPayloadFetchesRawDataForUnsupportedPreview() async throws {
        let rawData = Data([0x50, 0x4B, 0x03, 0x04])
        var requestedPaths: [String] = []
        let client = makeClient { request in
            requestedPaths.append(request.url?.path ?? "nil")
            XCTAssertEqual(request.url?.path, "/api/files/download")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertNil(query["session_id"])
            XCTAssertEqual(query["path"], "Build/archive.zip")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/zip"]
            )
            return (try XCTUnwrap(response), rawData)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Build/archive.zip",
            apiClient: client
        )

        await viewModel.load()
        let payload = try await viewModel.exportPayload()

        if case .unavailable = viewModel.preview {
            XCTAssertTrue(true)
        } else {
            XCTFail("Zip files should keep the unsupported-preview state.")
        }
        XCTAssertEqual(payload.data, rawData)
        XCTAssertEqual(payload.filename, "archive.zip")
        XCTAssertEqual(payload.contentType, UTType.zip)
        XCTAssertFalse(payload.isImage)
        XCTAssertEqual(requestedPaths, ["/api/files/download"])
    }

    // MARK: - Gateway test helpers

    /// Builds an `APIClient` whose `withGatewayConnection` uses a test-transport
    /// `HermesGatewayClient` (via the `gatewayFabricator` seam): the websocket
    /// handshake completes instantly and each JSON-RPC frame is captured on
    /// `frames`, then delivered a canned `result` per method. The `handler`
    /// still serves the `POST /api/auth/ws-ticket` mint through `MockURLProtocol`.
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
