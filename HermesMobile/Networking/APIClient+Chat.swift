import Foundation

extension APIClient {
    func chatStreamStatus(streamID: String) async throws -> ChatStreamStatusResponse {
        try await send(endpoint: .chatStreamStatus(streamID: streamID), method: "GET")
    }

    func steerChat(sessionID: String, text: String) async throws -> ChatSteerResponse {
        try await send(
            endpoint: .chatSteer,
            method: "POST",
            body: ChatSteerRequest(sessionId: sessionID, text: text)
        )
    }
}

private struct ChatSteerRequest: Encodable {
    let sessionId: String
    let text: String
}
