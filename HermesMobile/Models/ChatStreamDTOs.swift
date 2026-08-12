import Foundation

/// Streaming-event payload DTOs shared between the chat coordinator and the
/// transport. These outlive the SSE client: the gateway-age
/// `ChatStreamCoordinator` constructs them for its delegate, so they must stay
/// decoupled from any specific stream transport.

struct TitleStreamEvent: Decodable, Equatable {
    let sessionId: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
    }

    init(sessionId: String? = nil, title: String? = nil) {
        self.sessionId = sessionId
        self.title = title
    }
}

struct ToolStreamEvent: Decodable, Equatable {
    let eventType: String?
    let name: String?
    let preview: String?
    let args: [String: JSONValue]?
    let duration: Double?
    let isError: Bool?
    let stableID: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case name
        case preview
        case args
        case duration
        case isError = "is_error"
        case tid
        case id
        case toolCallID = "tool_call_id"
        case toolUseID = "tool_use_id"
        case callID = "call_id"
    }

    init(
        eventType: String?,
        name: String?,
        preview: String?,
        args: [String: JSONValue]?,
        duration: Double?,
        isError: Bool?,
        stableID: String? = nil
    ) {
        self.eventType = eventType
        self.name = name
        self.preview = preview
        self.args = args
        self.duration = duration
        self.isError = isError
        self.stableID = stableID?.nonEmptyToolStreamID
    }

    init() {
        eventType = nil
        name = nil
        preview = nil
        args = nil
        duration = nil
        isError = nil
        stableID = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = container.decodeLossyStringIfPresent(forKey: .eventType)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        preview = container.decodeLossyStringIfPresent(forKey: .preview)
        args = try? container.decodeIfPresent([String: JSONValue].self, forKey: .args)
        duration = container.decodeLossyDoubleIfPresent(forKey: .duration)
        isError = container.decodeLossyBoolIfPresent(forKey: .isError)
        stableID = [
            container.decodeLossyStringIfPresent(forKey: .tid),
            container.decodeLossyStringIfPresent(forKey: .id),
            container.decodeLossyStringIfPresent(forKey: .toolCallID),
            container.decodeLossyStringIfPresent(forKey: .toolUseID),
            container.decodeLossyStringIfPresent(forKey: .callID)
        ].compactMap { $0?.nonEmptyToolStreamID }.first
    }
}

struct InterimAssistantStreamEvent: Decodable, Equatable {
    let text: String?
    let alreadyStreamed: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case alreadyStreamed = "already_streamed"
    }

    init(text: String? = nil, alreadyStreamed: Bool? = nil) {
        self.text = text
        self.alreadyStreamed = alreadyStreamed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        alreadyStreamed = container.decodeLossyBoolIfPresent(forKey: .alreadyStreamed)
    }
}

struct MeteringStreamEvent: Decodable, Equatable {
    let tokensPerSecond: Double?
    let isTokensPerSecondAvailable: Bool?
    let isEstimated: Bool?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case tokensPerSecond = "tps"
        case isTokensPerSecondAvailable = "tps_available"
        case isEstimated = "estimated"
        case sessionId = "session_id"
    }

    init(
        tokensPerSecond: Double? = nil,
        isTokensPerSecondAvailable: Bool? = nil,
        isEstimated: Bool? = nil,
        sessionId: String? = nil
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.isTokensPerSecondAvailable = isTokensPerSecondAvailable
        self.isEstimated = isEstimated
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokensPerSecond = container.decodeLossyDoubleIfPresent(forKey: .tokensPerSecond)
        isTokensPerSecondAvailable = container.decodeLossyBoolIfPresent(forKey: .isTokensPerSecondAvailable)
        isEstimated = container.decodeLossyBoolIfPresent(forKey: .isEstimated)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
    }

    var displayableTokensPerSecond: Double? {
        guard isTokensPerSecondAvailable == true,
              isEstimated != true,
              let tokensPerSecond,
              tokensPerSecond.isFinite,
              tokensPerSecond > 0
        else {
            return nil
        }
        return tokensPerSecond
    }
}

struct DoneStreamEvent: Equatable {
    let usage: ContextWindowSnapshot?
    let session: SessionDetail?

    init(usage: ContextWindowSnapshot? = nil, session: SessionDetail? = nil) {
        self.usage = usage
        self.session = session
    }
}

private extension String {
    var nonEmptyToolStreamID: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
