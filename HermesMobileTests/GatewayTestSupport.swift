import XCTest
import AVFoundation
@testable import HermesMobile

/// A scripted `GatewayClientProviding` double used across the chat gateway
/// tests. Production hands `ChatStreamCoordinator` a `HermesGatewayClient`;
/// these tests inject this double via `gatewayFabricator` so the coordinator
/// lifecycle (connect → resume → submitPrompt → event routing → epoch
/// rejection) is exercised without a live WebSocket.
@MainActor
final class ScriptedGatewayClient: GatewayClientProviding {
    private(set) var isConnected = false

    var onEvent: ((GatewayEvent) -> Void)?
    var onDisconnected: (() -> Void)?

    // Configurable outcomes.
    var connectError: Error?
    var resumeError: Error?
    var submitError: Error?
    var interruptError: Error?
    var attachError: Error?
    var resumeResultFactory: (String) -> GatewayResumeResult = { sessionID in
        .empty(sessionID: sessionID)
    }

    // Call recording.
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var resumeSessionIDs: [String] = []
    private(set) var submittedPrompts: [(sessionID: String, text: String, rewindOrdinal: Int?)] = []
    private(set) var attachedImages: [(sessionID: String, base64: String, filename: String)] = []
    private(set) var attachedPDFs: [(sessionID: String, base64: String, filename: String)] = []
    private(set) var attachedFiles: [(sessionID: String, dataURL: String, name: String, path: String)] = []
    private(set) var interruptedSessionIDs: [String] = []

    init() {}

    func connect() async throws {
        connectCount += 1
        if let connectError {
            throw connectError
        }
        isConnected = true
    }

    func disconnect() {
        disconnectCount += 1
        isConnected = false
        // `disconnect()` is the clean-teardown path (used by teardownGateway);
        // it must NOT fire onDisconnected, which is reserved for transport drops.
    }

    func resumeSession(_ sessionID: String) async throws -> GatewayResumeResult {
        resumeSessionIDs.append(sessionID)
        if let resumeError {
            throw resumeError
        }
        return resumeResultFactory(sessionID)
    }

    func attachImage(sessionID: String, base64: String, filename: String) async throws {
        attachedImages.append((sessionID: sessionID, base64: base64, filename: filename))
        if let attachError { throw attachError }
    }

    func attachPDF(sessionID: String, base64: String, filename: String) async throws {
        attachedPDFs.append((sessionID: sessionID, base64: base64, filename: filename))
        if let attachError { throw attachError }
    }

    func attachFile(sessionID: String, dataURL: String, name: String, path: String) async throws {
        attachedFiles.append((sessionID: sessionID, dataURL: dataURL, name: name, path: path))
        if let attachError { throw attachError }
    }

    func submitPrompt(sessionID: String, text: String, rewindOrdinal: Int?) async throws {
        submittedPrompts.append((sessionID: sessionID, text: text, rewindOrdinal: rewindOrdinal))
        if let submitError {
            throw submitError
        }
    }

    func interrupt(sessionID: String) async throws {
        interruptedSessionIDs.append(sessionID)
        if let interruptError {
            throw interruptError
        }
    }

    /// Simulates the gateway delivering a stream event notification.
    func deliver(_ event: GatewayEvent) {
        onEvent?(event)
    }

    /// Simulates the transport dropping (socket close), which fires
    /// `onDisconnected`; the coordinator treats this as a suspend + reconnect.
    func simulateTransportDisconnect() {
        isConnected = false
        onDisconnected?()
    }
}

extension GatewayResumeResult {
    /// A resume result with no durable messages and no live projection.
    static func empty(sessionID: String) -> GatewayResumeResult {
        GatewayResumeResult(
            sessionId: sessionID,
            messages: [],
            snapshot: GatewayRuntimeSnapshot(
                object: [:],
                inflight: nil,
                queued: nil
            )
        )
    }

    /// A resume result carrying an in-flight assistant projection (used to test
    /// the in-flight-prefix path).
    static func withInflight(
        sessionID: String,
        inflightText: String,
        running: Bool = true
    ) -> GatewayResumeResult {
        GatewayResumeResult(
            sessionId: sessionID,
            messages: [],
            snapshot: GatewayRuntimeSnapshot(
                object: ["running": .bool(running)],
                inflight: .object(["assistant": .string(inflightText)]),
                queued: nil
            )
        )
    }
}

/// Records every gateway fabricator invocation (fresh ticket per epoch) and
/// hands back a fresh scripted client. The returned closure satisfies
/// `ChatStreamCoordinator`/`ChatViewModel`'s `gatewayFabricator` parameter.
@MainActor
final class ScriptedGatewayFabricator {
    private(set) var instances: [ScriptedGatewayClient] = []
    private(set) var tickets: [String] = []
    private(set) var baseURLs: [URL] = []
    private(set) var profiles: [String?] = []
    /// Optional hook: run exactly when a new client is made (e.g. configure the
    /// resume result) before it is returned.
    var onMake: ((_ instance: ScriptedGatewayClient, _ index: Int) -> Void)?

    /// The `gatewayFabricator:` closure to pass into the VM/coordinator.
    var fabricator: @MainActor (URL, String, String?) -> any GatewayClientProviding {
        { [weak self] baseURL, ticket, profile in
            guard let self else {
                return ScriptedGatewayClient()
            }
            let instance = ScriptedGatewayClient()
            self.instances.append(instance)
            self.tickets.append(ticket)
            self.baseURLs.append(baseURL)
            self.profiles.append(profile)
            self.onMake?(instance, self.instances.count)
            return instance
        }
    }

    var latest: ScriptedGatewayClient? {
        instances.last
    }

    var makeCount: Int {
        instances.count
    }
}

/// Parses a gateway event `params` JSON object into a `GatewayEvent` via
/// `StreamEventParser`, failing the test if it cannot be parsed. Test fixtures
/// mirror the wire shape the real parser consumes.
enum GatewayEventFixture {
    static func delta(sessionID: String, text: String) -> GatewayEvent {
        .messageDelta(sessionID: sessionID, text: text)
    }

    static func reasoning(sessionID: String, text: String) -> GatewayEvent {
        .reasoningDelta(sessionID: sessionID, text: text)
    }

    static func complete(sessionID: String, messageID: String? = nil, content: String? = nil, reasoning: String? = nil) -> GatewayEvent {
        .messageComplete(sessionID: sessionID, messageID: messageID, content: content, reasoning: reasoning)
    }

    static func error(sessionID: String, message: String) -> GatewayEvent {
        .messageError(sessionID: sessionID, message: message)
    }

    static func interrupted(sessionID: String) -> GatewayEvent {
        .messageInterrupted(sessionID: sessionID)
    }

    static func toolStarted(sessionID: String, name: String, input: GatewayValue? = nil) -> GatewayEvent {
        .toolStarted(sessionID: sessionID, name: name, input: input)
    }

    static func toolCompleted(sessionID: String, name: String, output: GatewayValue? = nil) -> GatewayEvent {
        .toolCompleted(sessionID: sessionID, name: name, output: output)
    }

    static func title(sessionID: String, title: String) -> GatewayEvent {
        .sessionTitle(sessionID: sessionID, title: title)
    }

    static func approval(sessionID: String, command: String, description: String, choices: [String]? = nil) -> GatewayEvent {
        .approval(sessionID: sessionID, command: command, description: description, choices: choices)
    }

    static func clarification(sessionID: String, requestID: String, question: String, choices: [(label: String, value: String)] = []) -> GatewayEvent {
        .clarification(sessionID: sessionID, requestID: requestID, question: question, choices: choices)
    }

    static func busy(sessionID: String, busy: Bool) -> GatewayEvent {
        .sessionBusy(sessionID: sessionID, busy: busy)
    }

    static func info(sessionID: String, running: Bool, inflightText: String? = nil) -> GatewayEvent {
        var object: [String: GatewayValue] = ["running": .bool(running)]
        if let inflightText, !inflightText.isEmpty {
            object["inflight"] = .object(["assistant": .string(inflightText)])
        }
        return .sessionInfo(sessionID: sessionID, snapshot: GatewayRuntimeSnapshot(object: object))
    }
}
