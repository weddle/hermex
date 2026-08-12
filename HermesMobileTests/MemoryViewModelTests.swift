import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class MemoryViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testLoadReadsNativeMemoryFiles() async throws {
        let client = makeClient { request in
            try Self.nativeMemoryResponse(for: request, soul: "# Soul")
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(viewModel.memoryText, "# Notes")
        XCTAssertEqual(viewModel.userText, "# Profile")
        XCTAssertEqual(viewModel.soulText, "# Soul")
        XCTAssertFalse(viewModel.showsProjectContext)
    }

    @MainActor
    func testSaveWritesNativeFileAndReloadsMemory() async throws {
        var writtenPath: String?
        var writtenContent: String?
        let client = makeClient { request in
            if request.url?.path == "/api/fs/write-text" {
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                writtenPath = body["path"] as? String
                writtenContent = body["content"] as? String
                return apiTestJSONResponse(#"{"ok":true,"path":"/opt/data/SOUL.md"}"#, for: request)
            }
            return try Self.nativeMemoryResponse(for: request, soul: "# Updated Soul")
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didSave = await viewModel.save(section: .soul, content: "# Updated Soul")

        XCTAssertTrue(didSave)
        XCTAssertEqual(writtenPath, "/opt/data/SOUL.md")
        XCTAssertEqual(writtenContent, "# Updated Soul")
        XCTAssertEqual(viewModel.soulText, "# Updated Soul")
        XCTAssertTrue(viewModel.hasLoaded)
    }

    private static func nativeMemoryResponse(
        for request: URLRequest,
        soul: String
    ) throws -> (HTTPURLResponse, Data) {
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
            case "/opt/data/memories/MEMORY.md": text = "# Notes"
            case "/opt/data/memories/USER.md": text = "# Profile"
            case "/opt/data/SOUL.md": text = soul
            default: throw URLError(.fileDoesNotExist)
            }
            let data = try JSONSerialization.data(withJSONObject: ["text": text, "path": path ?? ""])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        default:
            throw URLError(.badURL)
        }
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
}
