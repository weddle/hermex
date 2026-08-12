import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientChatEndpointTests: APIClientTestCase {
    func testPendingAttachmentBuildsBrowserCompatibleChatMessageText() {
        let html = PendingAttachment(
            name: "sample.html",
            path: "/tmp/workspace/sample.html",
            mime: "text/html",
            size: 42,
            isImage: false,
            thumbnailData: nil
        )
        let image = PendingAttachment(
            name: "image.jpg",
            path: "/tmp/workspace/image.jpg",
            mime: "image/jpeg",
            size: 100,
            isImage: true,
            thumbnailData: Data()
        )

        let message = PendingAttachment.chatMessageText(
            draft: "Analyze these files",
            attachments: [html, image]
        )

        XCTAssertEqual(
            message,
            "Analyze these files\n\n[Attached files: /tmp/workspace/sample.html, /tmp/workspace/image.jpg]"
        )
    }

    func testChatAttachmentPreviewItemInfersImageMessageAttachment() {
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: nil,
                path: "/tmp/workspace/photo.PNG",
                mime: nil,
                size: 128,
                isImage: nil
            ),
            localData: Data([0x01])
        )

        XCTAssertEqual(item.displayName, "photo.PNG")
        XCTAssertEqual(item.displayPath, "/tmp/workspace/photo.PNG")
        XCTAssertTrue(item.inferredIsImage)
        XCTAssertFalse(item.isKnownUnsupportedBinary)
    }

    func testChatAttachmentPreviewItemUsesPendingFileMetadata() {
        let item = ChatAttachmentPreviewItem(
            pending: PendingAttachment(
                name: "report.pdf",
                path: "/tmp/workspace/report.pdf",
                mime: "application/pdf",
                size: 2_048,
                isImage: false,
                thumbnailData: nil
            )
        )

        XCTAssertEqual(item.displayName, "report.pdf")
        XCTAssertEqual(item.displayPath, "/tmp/workspace/report.pdf")
        XCTAssertFalse(item.inferredIsImage)
        XCTAssertTrue(item.isKnownUnsupportedBinary)
    }

    func testChatStreamStatusBuildsExpectedQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["stream_id"], "stream-123")

            return apiTestJSONResponse("""
            {
              "active": true,
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let response = try await client.chatStreamStatus(streamID: "stream-123")

        XCTAssertEqual(response.active, true)
        XCTAssertEqual(response.streamId, "stream-123")
    }
}
