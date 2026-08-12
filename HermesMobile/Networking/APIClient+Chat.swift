import Foundation

extension APIClient {
    func startChat(
        sessionID: String,
        message: String,
        workspace: String?,
        model: String?,
        modelProvider: String? = nil,
        profile: String? = nil,
        explicitModelPick: Bool = false,
        attachments: [JSONValue]? = nil
    ) async throws -> ChatStartResponse {
        try await send(
            endpoint: .chatStart,
            method: "POST",
            body: ChatStartRequest(
                sessionId: sessionID,
                message: message,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile,
                explicitModelPick: explicitModelPick ? true : nil,
                attachments: attachments
            )
        )
    }

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

private struct ChatStartRequest: Encodable {
    let sessionId: String
    let message: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
    let explicitModelPick: Bool?
    let attachments: [JSONValue]?
}

private struct ChatSteerRequest: Encodable {
    let sessionId: String
    let text: String
}
