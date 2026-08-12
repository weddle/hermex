import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientMemoryEndpointTests: APIClientTestCase {
    func testMemoryReadsNativeProfileFiles() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"profiles":[{"name":"default","path":"/opt/data","is_default":true}]}"#, for: request)
            case "/api/profiles/active":
                return apiTestJSONResponse(#"{"active":"default"}"#, for: request)
            case "/api/fs/read-text":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let path = components?.queryItems?.first(where: { $0.name == "path" })?.value
                let text: String
                switch path {
                case "/opt/data/memories/MEMORY.md": text = "# Notes\n\n- Prefer SwiftUI"
                case "/opt/data/memories/USER.md": text = "# Profile\n\n- Name: Developer"
                case "/opt/data/SOUL.md": text = "# Agent Soul\n\n- Be concise"
                default:
                    let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                    return (response, Data(#"{"detail":"Not found"}"#.utf8))
                }
                let body = try JSONSerialization.data(withJSONObject: ["text": text, "path": path ?? ""])
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let response = try await client.memory()

        XCTAssertEqual(response.memory, "# Notes\n\n- Prefer SwiftUI")
        XCTAssertEqual(response.user, "# Profile\n\n- Name: Developer")
        XCTAssertEqual(response.soul, "# Agent Soul\n\n- Be concise")
        XCTAssertEqual(requestedPaths.filter { $0 == "/api/fs/read-text" }.count, 3)
    }

    func testMemoryTreatsMissingNativeFilesAsEmptySections() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"profiles":[{"name":"default","path":"/opt/data","is_default":true}]}"#, for: request)
            case "/api/profiles/active":
                return apiTestJSONResponse(#"{"active":"default"}"#, for: request)
            case "/api/fs/read-text":
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"detail":"Not found"}"#.utf8))
            default:
                throw URLError(.badURL)
            }
        }

        let response = try await client.memory()

        XCTAssertNil(response.memory)
        XCTAssertNil(response.user)
        XCTAssertNil(response.soul)
    }

    func testMemoryWriteUsesNativeProfilePath() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"profiles":[{"name":"default","path":"/opt/data","is_default":true}]}"#, for: request)
            case "/api/profiles/active":
                return apiTestJSONResponse(#"{"active":"default"}"#, for: request)
            case "/api/fs/write-text":
                XCTAssertEqual(request.httpMethod, "POST")
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["path"] as? String, "/opt/data/memories/USER.md")
                XCTAssertEqual(body["content"] as? String, "# Updated profile")
                return apiTestJSONResponse(#"{"ok":true,"path":"/opt/data/memories/USER.md"}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let response = try await client.writeMemory(section: .user, content: "# Updated profile")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.section, .user)
        XCTAssertEqual(response.path, "/opt/data/memories/USER.md")
    }
}
