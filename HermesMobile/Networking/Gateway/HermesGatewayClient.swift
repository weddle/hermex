//
//  HermesGatewayClient.swift
//  HermesMobile
//
//  JSON-RPC over WebSocket client for the Hermes Agent dashboard gateway.
//
//  This client is deliberately thin: it only handles WebSocket transport and
//  JSON-RPC request/response correlation. Session, busy, and reconnection
//  state lives in the chat coordinator; the client reports stream events via
//  `onEvent` and disconnects via `onDisconnected`.
//
//  Adapted from hermes-conduit (MIT License),
//  Conduit/Services/HermesClient.swift for the Hermex fork's native dashboard
//  transport. Preserves Conduit's transport behavior exactly: JSON-RPC text
//  frames, monotonically increasing integer IDs, continuation+timer
//  correlation, `method == "event"` dispatch, `/api/ws?ticket=<single-use>`,
//  non-default `profile` scoping, waiting for the real WebSocket open
//  callback, failing pending calls on disconnect, and no reconnect inside the
//  client.
//

import Foundation
import OSLog

private let gatewayClientLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "HermesGatewayClient"
)

// MARK: - JSON-RPC Types

private struct JsonRpcRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: GatewayValue]?
}

private struct JsonRpcResponse: Decodable {
    let id: Int?
    let result: GatewayValue?
    let error: GatewayRpcError?
    let method: String?
    let params: GatewayValue?
}

struct GatewayRpcError: Decodable, Error, LocalizedError {
    let code: Int?
    let message: String

    var errorDescription: String? { message }
}

enum GatewayError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case notConnected
    case connectionClosed
    case timeout(String)
    case steerRejected

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid gateway URL."
        case .invalidResponse: return "Hermes returned an incomplete response."
        case .notConnected: return "Hermes is not connected."
        case .connectionClosed: return "Hermes connection closed."
        case .timeout(let method): return "Request timed out: \(method)"
        case .steerRejected: return "Hermes could not steer the active response."
        }
    }
}

// MARK: - Pending Request

private struct PendingRequest {
    let continuation: CheckedContinuation<GatewayValue, Error>
    let timer: Timer?
}

/// URLSession only confirms the WebSocket handshake through its delegate. The
/// client must not issue session RPCs or paint a green indicator before this
/// callback, otherwise a just-opened socket can race its first `session.resume`.
private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: ((URLSessionWebSocketTask) -> Void)?
    var onCloseBeforeOpen: ((URLSessionWebSocketTask) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onCloseBeforeOpen?(webSocketTask)
    }
}

// MARK: - HermesGatewayClient

@MainActor
final class HermesGatewayClient {
    // Published state for SwiftUI views
    private(set) var isConnected = false

    // Non-published internal state
    private let baseURL: URL
    private let ticket: String
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var socketDelegate: WebSocketOpenDelegate?
    private var requestId = 0
    private var pending = [Int: PendingRequest]()
    private var closedIntentionally = false
    private var receiveTask: Task<Void, Never>?
    private var socketHasOpened = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openTimeoutTask: Task<Void, Never>?

    let profile: String?
    let customHeaders: [CustomHeader]

    // Callback for stream events (set by the chat coordinator)
    var onEvent: ((GatewayEvent) -> Void)?
    var onDisconnected: (() -> Void)?

    static let requestTimeout: TimeInterval = 30
    static let promptSubmitTimeout: TimeInterval = 180 // 3 minutes

    init(baseURL: URL, ticket: String, profile: String?, customHeaders: [CustomHeader] = []) {
        self.baseURL = baseURL
        self.ticket = ticket
        self.profile = profile
        self.customHeaders = customHeaders
    }

    // MARK: - Connection

    func connect() async throws {
        closedIntentionally = false
        socketHasOpened = false
        let url: URL
        do {
            url = try ConnectionURLPolicy.webSocketURL(
                baseURL: baseURL.absoluteString,
                path: "/api/ws",
                queryItems: [URLQueryItem(name: "ticket", value: ticket)]
            )
        } catch {
            throw GatewayError.invalidURL
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let socketDelegate = WebSocketOpenDelegate()
        socketDelegate.onOpen = { [weak self] task in
            Task { @MainActor in self?.didOpen(task) }
        }
        socketDelegate.onCloseBeforeOpen = { [weak self] task in
            Task { @MainActor in self?.didClose(task) }
        }
        let session = URLSession(configuration: config, delegate: socketDelegate, delegateQueue: nil)
        self.session = session
        self.socketDelegate = socketDelegate

        var request = URLRequest(url: url)
        customHeaders.apply(to: &request)
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        try await waitForSocketOpen(socket)
        isConnected = true
        gatewayClientLogger.notice("WebSocket handshake completed")

        // Start listening for messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func waitForSocketOpen(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
            openTimeoutTask?.cancel()
            openTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.failSocketOpen(socket, error: GatewayError.timeout("WebSocket connection"))
            }
        }
    }

    private func didOpen(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket, !socketHasOpened else { return }
        socketHasOpened = true
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume()
        openContinuation = nil
    }

    private func didClose(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket, !socketHasOpened else { return }
        failSocketOpen(socket, error: GatewayError.connectionClosed)
    }

    private func failSocketOpen(_ socket: URLSessionWebSocketTask, error: Error) {
        guard self.socket === socket else { return }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        socket.cancel(with: .goingAway, reason: nil)
        self.socket = nil
        openContinuation?.resume(throwing: error)
        openContinuation = nil
    }

    private func receiveLoop() async {
        guard let socket = socket else { return }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    handleMessage(data: data)
                case .string(let text):
                    handleMessage(data: Data(text.utf8))
                @unknown default:
                    break
                }
            } catch {
                gatewayClientLogger.error("WebSocket receive failed: \(error.localizedDescription, privacy: .public)")
                isConnected = false
                if !closedIntentionally {
                    onDisconnected?()
                }
                break
            }
        }
    }

    private func handleMessage(data: Data) {
        guard let json = try? JSONDecoder().decode(JsonRpcResponse.self, from: data) else {
            gatewayClientLogger.error("Dropped undecodable inbound WebSocket frame (\(data.count) bytes)")
            return
        }

        // Handle RPC response (has id)
        if let id = json.id {
            guard let pending = pending.removeValue(forKey: id) else {
                gatewayClientLogger.debug("Received unmatched RPC response id \(id)")
                return
            }
            pending.timer?.invalidate()
            if let error = json.error {
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume(returning: json.result ?? .null)
            }
            return
        }

        // Handle stream event notification
        if json.method == "event", let params = json.params {
            if let event = StreamEventParser.parse(params: params) {
                onEvent?(event)
            }
        } else {
            gatewayClientLogger.debug("Received non-event WebSocket notification without an RPC id")
        }
    }

    func disconnect() {
        closedIntentionally = true
        receiveTask?.cancel()
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: GatewayError.connectionClosed)
        openContinuation = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        socketDelegate = nil
        isConnected = false
        // Fail all pending requests
        for (_, pending) in pending {
            pending.timer?.invalidate()
            pending.continuation.resume(throwing: GatewayError.connectionClosed)
        }
        pending.removeAll()
    }

    // MARK: - RPC

    private func rpc(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = HermesGatewayClient.requestTimeout) async throws -> GatewayValue {
        guard let socket, socket.closeCode == .invalid else {
            throw GatewayError.notConnected
        }

        let id = incrementRequestId()
        let scopedParams = scopeParams(params)
        let encodedParams = scopedParams?.mapValues { GatewayValue.from($0) }

        let request = JsonRpcRequest(id: id, method: method, params: encodedParams)
        let body = try JSONEncoder().encode(request)
        gatewayClientLogger.notice("Sending RPC id \(id) method \(method, privacy: .public)")

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Timeout
                let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        if let pending = self?.pending.removeValue(forKey: id) {
                            pending.continuation.resume(throwing: GatewayError.timeout(method))
                        }
                    }
                }

                pending[id] = PendingRequest(continuation: continuation, timer: timer)

                // The Hermes gateway accepts the connection but does not dispatch
                // binary JSON-RPC frames; send text frames only.
                let text = String(decoding: body, as: UTF8.self)
                socket.send(.string(text)) { [weak self] error in
                    if let error {
                        gatewayClientLogger.error("RPC send failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        Task { @MainActor in
                            if let pending = self?.pending.removeValue(forKey: id) {
                                pending.timer?.invalidate()
                                pending.continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: id)
            }
        })
    }

    private func cancelPendingRequest(id: Int) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timer?.invalidate()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func incrementRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func scopeParams(_ params: [String: Any]?) -> [String: Any]? {
        var params = params ?? [:]
        if let profile, profile != "default" {
            params["profile"] = profile
        }
        return params.isEmpty ? nil : params
    }

    // MARK: - API Methods

    func healthCheck() async throws {
        _ = try await rpc("session.list", params: nil, timeout: 8)
    }

    func resumeSession(_ sessionID: String) async throws -> GatewayResumeResult {
        let result = try await rpc("session.resume", params: [
            "session_id": sessionID,
            "cols": 96,
            "source": "desktop"
        ])
        let object = result.objectValue ?? [:]
        let resolvedID = object["session_id"]?.stringValue ?? sessionID
        let messages = (object["messages"]?.arrayValue ?? []).compactMap { Self.gatewayMessage(from: $0) }
        var snapshotObject = object["info"]?.objectValue ?? [:]
        // The resume response owns the liveness fields. Keep `info` for the
        // rest of the runtime metadata, but let top-level values win.
        for key in ["running", "status"] {
            if let value = object[key] {
                snapshotObject[key] = value
            }
        }
        return GatewayResumeResult(
            sessionId: resolvedID,
            messages: messages,
            snapshot: GatewayRuntimeSnapshot(
                object: snapshotObject,
                inflight: object["inflight"],
                queued: object["queued"]
            )
        )
    }

    private static func gatewayMessage(from value: GatewayValue) -> GatewayChatMessage? {
        guard let object = value.objectValue else { return nil }
        let role = object["role"]?.stringValue ?? "assistant"
        let content = object["content"]?.stringValue ?? ""
        let id = object["id"]?.stringValue
        let reasoning = object["reasoning"]?.stringValue
            ?? object["reasoning_content"]?.stringValue
        let toolCalls = (object["tool_calls"]?.arrayValue ?? []).compactMap { tool -> GatewayToolCall? in
            let toolObject = tool.objectValue ?? [:]
            return GatewayToolCall(
                id: toolObject["id"]?.stringValue,
                name: toolObject["name"]?.stringValue
                    ?? toolObject["function"]?.objectValue?["name"]?.stringValue,
                arguments: toolObject["arguments"]?.stringValue
                    ?? toolObject["function"]?.objectValue?["arguments"]?.stringValue,
                output: toolObject["output"]?.stringValue
            )
        }
        return GatewayChatMessage(
            id: id,
            role: role,
            content: content,
            reasoningContent: reasoning,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }

    @discardableResult
    func createSession(model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, fast: Bool? = nil, cwd: String? = nil) async throws -> String {
        var params: [String: Any] = [
            "cols": 96,
            "source": "desktop"
        ]
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        if let model {
            params["model"] = model
            if let provider { params["provider"] = provider }
        }
        if let reasoningEffort { params["reasoning_effort"] = reasoningEffort }
        if let fast, fast { params["fast"] = true }
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["cwd"] = cwd }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        let sessionID = object["session_id"]?.stringValue ?? ""
        guard !sessionID.isEmpty else { throw GatewayError.invalidResponse }
        return sessionID
    }

    func branchSession(parentSessionID: String, messages: [GatewayBranchMessage], title: String, cwd: String? = nil) async throws -> String {
        var params: [String: Any] = [
            "cols": 96,
            "source": "desktop",
            "parent_session_id": parentSessionID,
            "title": title,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        if let cwd, !cwd.isEmpty { params["cwd"] = cwd }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        let sessionID = object["session_id"]?.stringValue ?? ""
        guard !sessionID.isEmpty else { throw GatewayError.invalidResponse }
        return sessionID
    }

    func compressSession(_ sessionID: String) async throws {
        _ = try await rpc("session.compress", params: ["session_id": sessionID])
    }

    func setSessionTitle(_ sessionID: String, title: String) async throws {
        _ = try await rpc("session.title", params: [
            "session_id": sessionID,
            "title": title
        ])
    }

    func projects() async throws -> GatewayValue {
        try await rpc("projects.tree", params: ["preview_limit": 3])
    }

    func projectSessions(_ projectID: String) async throws -> GatewayValue {
        try await rpc("projects.project_sessions", params: ["project_id": projectID])
    }

    func createProject(name: String, folders: [String]) async throws -> GatewayValue {
        try await rpc("projects.create", params: [
            "name": name,
            "folders": folders,
            "primary_path": folders.first ?? "",
            "use": true
        ])
    }

    func updateProject(id: String, name: String?, color: String?) async throws -> GatewayValue {
        var params: [String: Any] = ["id": id]
        if let name, !name.isEmpty { params["name"] = name }
        if let color, !color.isEmpty { params["color"] = color }
        return try await rpc("projects.update", params: params)
    }

    func deleteProject(id: String) async throws -> GatewayValue {
        try await rpc("projects.delete", params: ["id": id])
    }

    func moveSession(_ sessionID: String, toProject projectID: String?) async throws {
        var params: [String: Any] = ["session_id": sessionID]
        if let projectID, !projectID.isEmpty {
            params["project_id"] = projectID
        } else {
            params["project_id"] = NSNull()
        }
        _ = try await rpc("session.workspace.move", params: params)
    }

    /// Submits a user prompt over the gateway (`prompt.submit`).
    ///
    /// When `rewindOrdinal` is set this is a rewind/edit/regenerate: the
    /// gateway drops the `rewindOrdinal`-th user turn (0-based) and everything
    /// after it before running `text`. The ordinal is exactly the count of
    /// user-role messages before the target, and a stem-only rewind of user
    /// turn 0 (which would wipe the whole transcript) additionally opt-in via
    /// `confirm_empty_truncate` — mirroring the upstream desktop client's
    /// `truncateSubmitParams` and `tui_gateway/methods_prompt.py`.
    func submitPrompt(sessionID: String, text: String, rewindOrdinal: Int? = nil) async throws {
        var params: [String: Any] = [
            "session_id": sessionID,
            "text": text
        ]
        if let rewindOrdinal {
            params["confirm_truncate"] = true
            params["truncate_before_user_ordinal"] = rewindOrdinal
            if rewindOrdinal == 0 {
                params["confirm_empty_truncate"] = true
            }
        }
        _ = try await rpc("prompt.submit", params: params, timeout: HermesGatewayClient.promptSubmitTimeout)
    }

    func interrupt(sessionID: String) async throws {
        _ = try await rpc("session.interrupt", params: ["session_id": sessionID])
    }

    func steer(sessionID: String, text: String) async throws {
        let result = try await rpc("session.steer", params: [
            "session_id": sessionID,
            "text": text
        ])
        if result.objectValue?["status"]?.stringValue == "rejected" {
            throw GatewayError.steerRejected
        }
    }

    func redirect(sessionID: String, text: String) async throws -> GatewayRedirectOutcome {
        let result = try await rpc("session.redirect", params: [
            "session_id": sessionID,
            "text": text
        ])
        return GatewayRedirectOutcome(gatewayStatus: result.objectValue?["status"]?.stringValue)
    }

    func respondToApproval(sessionID: String, choice: String) async throws {
        _ = try await rpc("approval.respond", params: [
            "choice": choice,
            "session_id": sessionID
        ])
    }

    func respondToClarification(requestID: String, answer: String) async throws {
        _ = try await rpc("clarify.respond", params: [
            "request_id": requestID,
            "answer": answer
        ])
    }

    func modelOptions(sessionID: String? = nil) async throws -> GatewayValue {
        var params: [String: Any] = ["explicit_only": true]
        if let sessionID { params["session_id"] = sessionID }
        return try await rpc("model.options", params: params)
    }

    func setConfig(sessionID: String, key: String, value: GatewayValue) async throws {
        _ = try await rpc("config.set", params: [
            "key": key,
            "session_id": sessionID,
            "value": value
        ])
    }

    // MARK: - Attachments

    func attachImage(_ sessionID: String, base64: String, filename: String) async throws -> String? {
        let result = try await rpc("image.attach_bytes", params: [
            "session_id": sessionID,
            "content_base64": base64,
            "filename": filename
        ])
        return result.objectValue?["path"]?.stringValue
    }

    func attachPDF(_ sessionID: String, base64: String, filename: String) async throws {
        _ = try await rpc("pdf.attach", params: [
            "session_id": sessionID,
            "content_base64": base64,
            "filename": filename
        ], timeout: 120)
    }

    func attachFile(_ sessionID: String, dataURL: String, name: String, path: String = "") async throws {
        _ = try await rpc("file.attach", params: [
            "session_id": sessionID,
            "data_url": dataURL,
            "name": name,
            "path": path
        ], timeout: 120)
    }
}
