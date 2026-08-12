import XCTest
import AVFoundation
@testable import HermesMobile

/// Focused transport tests for the native Hermes Agent gateway:
/// JSON-RPC request/response correlation (response IDs resolve the matching
/// pending request), disconnect failing pending requests, event parsing, and
/// `ConnectionURLPolicy` HTTP→WS scheme conversion + origin validation.
final class GatewayTransportTests: XCTestCase {
    // MARK: - JSON-RPC correlation

    @MainActor
    func testRpcIDsResolveTheMatchingPendingRequest() async throws {
        let client = HermesGatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            ticket: "ticket-1",
            profile: nil
        )

        let sendFrames = LockedStringList()
        client.testSendFrame = { text in
            sendFrames.append(text)
        }

        // Connect completes instantly under the test transport.
        try await client.connect()

        // Fire a resume and, before it resolves, submit a redirect call. The
        // gateway may answer out of order; each response ID must resolve the
        // request that sent that ID, not the most recent one.
        let resumeTask = Task { @MainActor in
            try await client.resumeSession("session-abc")
        }
        let redirectTask = Task { @MainActor in
            try await client.redirect(sessionID: "session-abc", text: "Keep going")
        }

        // Capture the two request frames and deliver responses OUT OF ORDER.
        let frames = await sendFrames.waitFor(count: 2)
        XCTAssertEqual(frames.count, 2)

        // Parse frames: resume carries session.resume, redirect carries session.redirect.
        let resumeFrame = try XCTUnwrap(frames.first { $0.contains("session.resume") })
        let redirectFrame = try XCTUnwrap(frames.first { $0.contains("\"session.redirect\"") })
        let resumeID = try Self.requestID(from: resumeFrame)
        let redirectID = try Self.requestID(from: redirectFrame)
        XCTAssertNotEqual(resumeID, redirectID, "each RPC must use a distinct integer id")

        // Respond to the REDIRECT request first, then the RESUME request.
        client.testDeliverFrame(Self.responseFrame(id: redirectID, result: #"{"status":"queued"}"#))
        client.testDeliverFrame(Self.responseFrame(id: resumeID, result: Self.resumeResultJSON(sessionID: "session-abc")))

        // Both must resolve to their own request's values despite out-of-order replies.
        let redirectResult = try await redirectTask.value
        XCTAssertEqual(redirectResult, .queued, "redirect response must map status:'queued' → .queued")

        let resumeResult = try await resumeTask.value
        XCTAssertEqual(resumeResult.sessionId, "session-abc")
        XCTAssertEqual(resumeResult.snapshot.running, true)

        client.disconnect()
    }

    @MainActor
    func testDisconnectFailsPendingRequests() async throws {
        let client = HermesGatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            ticket: "ticket-2",
            profile: nil
        )
        client.testSendFrame = { _ in }
        try await client.connect()

        let pendingResume = Task { @MainActor in
            do {
                _ = try await client.resumeSession("session-abc")
                XCTFail("Expected pending resume to fail after disconnect")
                return
            } catch {
                // Expected path: connection closed.
            }
        }

        // Give the RPC a chance to register its pending request.
        try await Task.sleep(nanoseconds: 20_000_000)
        client.disconnect()

        await pendingResume.value
    }

    @MainActor
    func testResumeSessionMintsRequestWithExpectedParams() async throws {
        let client = HermesGatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            ticket: "ticket-3",
            profile: nil
        )
        let sendFrames = LockedStringList()
        client.testSendFrame = { sendFrames.append($0) }
        try await client.connect()

        let resumeTask = Task { @MainActor in
            try await client.resumeSession("session-abc")
        }

        let frame = try await sendFrames.firstFrame()
        let requestID = try Self.requestID(from: frame)
        XCTAssertTrue(frame.contains("\"method\":\"session.resume\""), "frame: \(frame)")
        XCTAssertTrue(frame.contains("\"session_id\":\"session-abc\""), "frame: \(frame)")
        XCTAssertTrue(frame.contains("\"cols\":96"), "frame: \(frame)")
        XCTAssertTrue(frame.contains("\"source\":\"desktop\""), "frame: \(frame)")

        client.testDeliverFrame(Self.responseFrame(id: requestID, result: Self.resumeResultJSON(sessionID: "session-abc")))
        let result = try await resumeTask.value
        XCTAssertEqual(result.sessionId, "session-abc")
    }

    @MainActor
    func testProfileScopesRequestParams() async throws {
        let client = HermesGatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            ticket: "ticket-4",
            profile: "work"
        )
        let sendFrames = LockedStringList()
        client.testSendFrame = { sendFrames.append($0) }
        try await client.connect()

        let resumeTask = Task { @MainActor in
            try await client.resumeSession("session-abc")
        }
        let frame = try await sendFrames.firstFrame()
        XCTAssertTrue(frame.contains("\"profile\":\"work\""), "non-default profile must scope params: \(frame)")

        let requestID = try Self.requestID(from: frame)
        client.testDeliverFrame(Self.responseFrame(id: requestID, result: Self.resumeResultJSON(sessionID: "session-abc")))
        _ = try await resumeTask.value
    }

    @MainActor
    func testRpcErrorResumesWithGatewayError() async throws {
        let client = HermesGatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            ticket: "ticket-5",
            profile: nil
        )
        let sendFrames = LockedStringList()
        client.testSendFrame = { sendFrames.append($0) }
        try await client.connect()

        let resumeTask = Task { @MainActor in
            do {
                _ = try await client.resumeSession("session-abc")
                XCTFail("Expected RPC error")
            } catch let error as GatewayRpcError {
                XCTAssertEqual(error.message, "session not found")
                XCTAssertEqual(error.code, -32000)
            }
        }
        let frame = try await sendFrames.firstFrame()
        let requestID = try Self.requestID(from: frame)
        client.testDeliverFrame(Self.errorResponseFrame(id: requestID, code: -32000, message: "session not found"))
        try await resumeTask.value
    }

    // MARK: - Event parsing (StreamEventParser)

    @MainActor
    func testMessageDeltaEventParsesToGatewayEvent() throws {
        let event = try parseEvent(#"{"type":"message.delta","session_id":"session-abc","text":"Hello "}"#)
        XCTAssertEqual(event, .messageDelta(sessionID: "session-abc", text: "Hello "))
    }

    @MainActor
    func testReasoningDeltaEventParses() throws {
        let event = try parseEvent(#"{"type":"reasoning.delta","session_id":"session-abc","reasoning":"Hmm"}"#)
        XCTAssertEqual(event, .reasoningDelta(sessionID: "session-abc", text: "Hmm"))
    }

    @MainActor
    func testToolStartEventParses() throws {
        let event = try parseEvent(#"{"type":"tool.start","session_id":"session-abc","payload":{"name":"bash","input":{"cmd":"ls"}}}"#)
        guard case .toolStarted(let sessionID, let name, let input) = event else {
            return XCTFail("expected toolStarted, got \(event)")
        }
        XCTAssertEqual(sessionID, "session-abc")
        XCTAssertEqual(name, "bash")
        XCTAssertEqual(input, .object(["cmd": .string("ls")]))
    }

    @MainActor
    func testMessageCompleteEventParses() throws {
        let event = try parseEvent(#"{"type":"message.complete","session_id":"session-abc","payload":{"message_id":"m-1","content":"Done","reasoning":"thought"}}"#)
        XCTAssertEqual(
            event,
            .messageComplete(sessionID: "session-abc", messageID: "m-1", content: "Done", reasoning: "thought")
        )
    }

    @MainActor
    func testApprovalRequestEventParses() throws {
        let event = try parseEvent(#"{"type":"approval.request","session_id":"session-abc","payload":{"command":"rm -rf /tmp/x","description":"Delete temp dir","choices":["allow","deny"]}}"#)
        XCTAssertEqual(
            event,
            .approval(sessionID: "session-abc", command: "rm -rf /tmp/x", description: "Delete temp dir", choices: ["allow", "deny"])
        )
    }

    @MainActor
    func testClarifyRequestEventParses() throws {
        let event = try parseEvent(#"{"type":"clarify","session_id":"session-abc","payload":{"request_id":"r-1","question":"Which?","choices":[{"label":"A","value":"a"},{"label":"B","value":"b"}]}}"#)
        XCTAssertEqual(
            event,
            .clarification(sessionID: "session-abc", requestID: "r-1", question: "Which?", choices: [("A", "a"), ("B", "b")])
        )
    }

    @MainActor
    func testUnknownEventMapsToIgnored() throws {
        let event = try parseEvent(#"{"type":"something.else","session_id":"session-abc","payload":{}}"#)
        XCTAssertEqual(event, .ignored)
    }

    // MARK: - ConnectionURLPolicy

    func testWebSocketURLConvertsHTTPSchemeToWS() throws {
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: "http://127.0.0.1:9119",
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: "abc")]
        )
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 9119)
        XCTAssertEqual(url.path, "/api/ws")
        XCTAssertEqual(url.query, "ticket=abc")
    }

    func testWebSocketURLConvertsHTTPSToWSS() throws {
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: "https://example.test",
            path: "/api/ws"
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "example.test")
        XCTAssertEqual(url.path, "/api/ws")
    }

    func testHTTPRemoteNonLoopbackIsRejected() {
        // Remote hosts must use HTTPS; only loopback and Tailscale hosts may use HTTP.
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://example.com")))
        // localhost HTTP is allowed.
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://127.0.0.1:9119")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://localhost:9119")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "https://example.com")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://1.2.3.4:9119")))
        // Tailscale hosts allow HTTP.
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://machine.tail1234.ts.net")))
    }

    func testHTTPRemoteLoopbackNormalizationRejectsNonLoopback() {
        XCTAssertThrowsError(try ConnectionURLPolicy.normalizedBaseURL("http://remote.example.com:9119"))
        XCTAssertNoThrow(try ConnectionURLPolicy.normalizedBaseURL("http://127.0.0.1:9119"))
        XCTAssertNoThrow(try ConnectionURLPolicy.normalizedBaseURL("https://example.com"))
    }

    func testOriginMatchingIgnoresDefaultPortCase() {
        let expected = URL(string: "https://example.test")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(URL(string: "https://example.test/chat"), expected: expected))
        XCTAssertTrue(ConnectionURLPolicy.originMatches(URL(string: "https://example.test:443/other"), expected: expected))
        // A different explicit port does NOT match.
        XCTAssertFalse(ConnectionURLPolicy.originMatches(URL(string: "https://example.test:8443/other"), expected: expected))
        XCTAssertFalse(ConnectionURLPolicy.originMatches(URL(string: "https://other.test"), expected: expected))
        XCTAssertFalse(ConnectionURLPolicy.originMatches(URL(string: "http://example.test"), expected: expected))
    }

    // MARK: - Helpers

    @MainActor
    private func parseEvent(_ json: String) throws -> GatewayEvent {
        let params = try JSONDecoder().decode(GatewayValue.self, from: Data(json.utf8))
        let event = try XCTUnwrap(StreamEventParser.parse(params: params))
        return event
    }

    private static func requestID(from frame: String) throws -> Int {
        // Extract "id":<n> at the start of the JSON-RPC request.
        let pattern = #""id":\s*(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(frame.startIndex..<frame.endIndex, in: frame)
        guard let match = regex.firstMatch(in: frame, range: range),
              let idRange = Range(match.range(at: 1), in: frame),
              let id = Int(frame[idRange]) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no id in frame: \(frame)"])
        }
        return id
    }

    private static func responseFrame(id: Int, result: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#
    }

    private static func errorResponseFrame(id: Int, code: Int, message: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    private static func resumeResultJSON(sessionID: String) -> String {
        #"{"session_id":"\#(sessionID)","running":true,"info":{"model":"gpt-5.4"},"messages":[]}"#
    }
}

/// Thread-safe string list for capturing test-transport outbound frames.
final class LockedStringList {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var all: [String] {
        snapshot()
    }

    var isEmpty: Bool {
        snapshot().isEmpty
    }

    func waitFor(count: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async -> [String] {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let current = snapshot()
            if current.count >= count {
                return current
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot()
    }

    func firstFrame(timeoutNanoseconds: UInt64 = 2_000_000_000) async throws -> String {
        let frames = await waitFor(count: 1, timeoutNanoseconds: timeoutNanoseconds)
        guard let first = frames.first else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no frame captured"])
        }
        return first
    }
}
