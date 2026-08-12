import XCTest
@testable import HermesMobile

/// Clarification prompt tests. The legacy clarify REST endpoint was replaced by
/// the gateway `clarify.respond` RPC, and clarify payloads arrive as `clarify`
/// gateway stream events routed through
/// `ChatStreamCoordinator` → `applyClarificationUpdate`. The pure model-decode
/// and marker-parsing tests are kept as-is; the stream tests drive
/// `.clarification` `GatewayEvent`s through the shared
/// `ScriptedGatewayFabricator`/`ScriptedGatewayClient`/`GatewayEventFixture`
/// doubles.
final class ClarificationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testClarificationPendingDecodesUpstreamShapeTolerantly() throws {
        let response = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data("""
            {
              "pending": {
                "clarify_id": "clarify-1",
                "question": "Which branch should I use?",
                "choices_offered": ["main", 42, true],
                "session_id": "session-abc",
                "kind": "clarify",
                "requested_at": "1716150000.0",
                "timeout_seconds": "120",
                "expires_at": 1716150120.0,
                "future_field": {"ignored": true}
              },
              "pending_count": "2"
            }
            """.utf8)
        )

        XCTAssertEqual(response.pending?.clarifyId, "clarify-1")
        XCTAssertEqual(response.pending?.question, "Which branch should I use?")
        XCTAssertEqual(response.pending?.choicesOffered, ["main", "42.0", "true"])
        XCTAssertEqual(response.pending?.sessionId, "session-abc")
        XCTAssertEqual(response.pending?.kind, "clarify")
        XCTAssertEqual(response.pending?.requestedAt, 1_716_150_000)
        XCTAssertEqual(response.pending?.timeoutSeconds, 120)
        XCTAssertEqual(response.pending?.expiresAt, 1_716_150_120)
        XCTAssertEqual(response.pendingCount, 2)
    }

    func testClarificationPendingDecodesNullAndMissingOptionals() throws {
        let noPending = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data(#"{"pending": null}"#.utf8)
        )
        XCTAssertNil(noPending.pending)
        XCTAssertNil(noPending.pendingCount)

        let minimal = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data(#"{"pending":{"question":"Answer this."}}"#.utf8)
        )
        XCTAssertEqual(minimal.pending?.displayQuestion, "Answer this.")
        XCTAssertEqual(minimal.pending?.displayChoices, [])
    }

    func testClarificationRespondResponseDecodesStaleFieldsTolerantly() throws {
        let stale = try JSONDecoder().decode(
            ClarificationRespondResponse.self,
            from: Data(#"{"ok": false, "error": "Clarification prompt expired or not found.", "stale": true}"#.utf8)
        )
        XCTAssertEqual(stale.ok, false)
        XCTAssertEqual(stale.stale, true)
        XCTAssertNil(stale.staleCleared)
        XCTAssertNil(stale.relayed)

        let cleared = try JSONDecoder().decode(
            ClarificationRespondResponse.self,
            from: Data(#"{"ok": true, "response": "A", "stale_cleared": "true", "relayed": 1}"#.utf8)
        )
        XCTAssertEqual(cleared.ok, true)
        XCTAssertEqual(cleared.staleCleared, true)
        XCTAssertEqual(cleared.relayed, true)
        XCTAssertNil(cleared.stale)
    }

    /// The SSE decoder is gone; clarify payloads now arrive as `clarify`
    /// gateway event notifications parsed by `StreamEventParser`. This pins the
    /// wire shape the coordinator consumes: `request_id` + `question` +
    /// `choices[{label,value}]` → `.clarification`.
    func testStreamEventParserParsesClarifyNotification() throws {
        let params = try JSONDecoder().decode(GatewayValue.self, from: Data("""
        {
          "type": "clarify",
          "session_id": "session-abc",
          "payload": {
            "request_id": "clarify-2",
            "question": "Choose deployment target",
            "choices": [
              {"label": "iPhone", "value": "iphone"},
              {"label": "iPad", "value": "ipad"}
            ]
          }
        }
        """.utf8))

        let event = try XCTUnwrap(StreamEventParser.parse(params: params))

        guard case .clarification(let sessionID, let requestID, let question, let choices) = event else {
            XCTFail("Expected .clarification, got \(event)")
            return
        }
        XCTAssertEqual(sessionID, "session-abc")
        XCTAssertEqual(requestID, "clarify-2")
        XCTAssertEqual(question, "Choose deployment target")
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices.first?.label, "iPhone")
        XCTAssertEqual(choices.first?.value, "iphone")
    }

    /// Clarify-marker detection on raw SSE-era JSON payload blobs (used by the
    /// defensive stream-payload sniffing) still works on the current model.
    func testClarificationMarkerParsingDetectsClarifyPayloads() {
        XCTAssertTrue(ClarificationPendingResponse.containsClarificationMarkers(
            in: Data(#"{"pending":{"question":"Which?"}}"#.utf8)
        ))
        XCTAssertTrue(ClarificationPendingResponse.containsClarificationMarkers(
            in: Data(#"{"question":"Which?","choices_offered":["A","B"]}"#.utf8)
        ))
        XCTAssertFalse(ClarificationPendingResponse.containsClarificationMarkers(
            in: Data(#"{"pending": null}"#.utf8)
        ))
        XCTAssertFalse(ClarificationPendingResponse.containsClarificationMarkers(
            in: Data(#"{"ok": true}"#.utf8)
        ))
    }

    @MainActor
    func testClarificationEventPublishesPrompt() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Set up the project")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.clarification(
            sessionID: "session-abc",
            requestID: "clarify-1",
            question: "Which branch?",
            choices: [("main", "main"), ("release", "release")]
        ))

        XCTAssertEqual(viewModel.clarificationPrompt?.sessionID, "session-abc")
        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "clarify-1")
        XCTAssertEqual(viewModel.clarificationPrompt?.question, "Which branch?")
        XCTAssertEqual(viewModel.clarificationPrompt?.choices, ["main", "release"])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    func testClarificationForDifferentSessionDoesNotRenderOverCurrentChat() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Continue")
        XCTAssertTrue(didStart)

        viewModel.applyClarificationUpdate(
            ClarificationPendingResponse(
                pending: PendingClarification(
                    clarifyId: "other-clarify",
                    question: "Other session?",
                    sessionId: "other-session"
                ),
                pendingCount: 1
            ),
            sessionID: "other-session"
        )

        XCTAssertNil(viewModel.clarificationPrompt)

        viewModel.applyClarificationUpdate(
            ClarificationPendingResponse(
                pending: PendingClarification(
                    clarifyId: "current-clarify",
                    question: "Current session?",
                    sessionId: "session-abc"
                ),
                pendingCount: 1
            ),
            sessionID: "session-abc"
        )

        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "current-clarify")
    }

    /// The respond path now calls the gateway `clarify.respond` RPC (no REST
    /// body to assert), so the reachable local contract is the guard: an
    /// empty/whitespace-only response keeps the prompt and shows a validation
    /// error without hitting the network.
    @MainActor
    func testEmptyClarificationRespondKeepsPromptAndShowsValidationError() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Continue")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.clarification(
            sessionID: "session-abc",
            requestID: "clarify-1",
            question: "Which branch?"
        ))

        XCTAssertNotNil(viewModel.clarificationPrompt)

        let didRespond = await viewModel.respondToClarification("   ")

        XCTAssertFalse(didRespond)
        XCTAssertNotNil(viewModel.clarificationPrompt)
        XCTAssertEqual(
            viewModel.clarificationErrorMessage,
            String(localized: "Enter a response before submitting.")
        )
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    private func makeViewModel(
        gatewayFabricator: @escaping @MainActor (URL, String, String?) -> any GatewayClientProviding,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        return ChatViewModel(
            session: try makeSession(),
            server: server,
            client: client,
            gatewayFabricator: gatewayFabricator
        )
    }

    private func makeSession() throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace",
              "model": "gpt-5.4"
            }
            """.utf8)
        )
    }
}
