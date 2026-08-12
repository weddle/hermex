import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientUploadTests: APIClientTestCase {
    func testUploadFileSendsMultipartAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            XCTAssertEqual(request.httpMethod, "POST")

            guard let body = apiTestBodyData(from: request) else {
                XCTFail("Missing request body")
                throw URLError(.badServerResponse)
            }

            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["path"] as? String, "test.jpg")
            XCTAssertEqual(json?["overwrite"] as? Bool, true)
            XCTAssertTrue((json?["data_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
            XCTAssertEqual(json?["data_url"] as? String, "data:image/jpeg;base64," + Data("hello".utf8).base64EncodedString())

            return apiTestJSONResponse("""
            {
              "ok": true,
              "path": "/tmp/workspace/test.jpg",
              "entry": {
                "name": "test.jpg",
                "path": "/tmp/workspace/test.jpg",
                "size": 5,
                "mime_type": "image/jpeg"
              }
            }
            """, for: request)
        }

        let response = try await client.uploadFile(sessionID: "abc123", data: Data("hello".utf8), filename: "test.jpg")

        XCTAssertEqual(response.filename, "test.jpg")
        XCTAssertEqual(response.path, "/tmp/workspace/test.jpg")
        XCTAssertEqual(response.size, 5)
        XCTAssertEqual(response.mime, "image/jpeg")
        XCTAssertEqual(response.isImage, true)
    }
}
