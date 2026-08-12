import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

/// Gateway-era send/stream tests for `ChatViewModel`.
///
/// These drive the send path through `beginTurn` (mint ticket → gateway
/// connect → resume → submitPrompt) with `ScriptedGatewayClient`/
/// `ScriptedGatewayFabricator` injected via the view model's
/// `gatewayFabricator`. Stream events are delivered with
/// `gateway.deliver(GatewayEventFixture…)` — there is no SSE stream, no
/// stream-ID replay.
///
/// Behavior coverage retained from the SSE era:
/// - optimistic user-message append + rollback (connect/resume/submit
///   failures)
/// - live delta/reasoning/tool event routing into the transcript
/// - approval/clarification events routed to the pending-action coordinator
/// - fresh-ticket reconnect + stale-epoch event rejection
/// - in-flight assistant projection applied once (no duplicate deltas)
/// - device-local Listen (AVSpeechSynthesizer) behaviors
/// - attachment upload, workspace selection, cache/reload, pagination, and
///   composer-config REST behaviors that don't require the gateway.
final class ChatViewModelSendTests: XCTestCase {
    override func tearDown() {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Send lifecycle (beginTurn → optimistic append + rollback)

    @MainActor
    func testSendMessageAppendsOptimisticUserMessageAndDrivesGatewayLifecycle() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("  Keep working  ")

        XCTAssertTrue(didStart)
        // beginTurn: mint one ticket → one gateway → connect → resume → submit.
        XCTAssertEqual(fabricator.makeCount, 1)
        XCTAssertEqual(fabricator.tickets, ["ticket-1"])
        let gateway = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(gateway.connectCount, 1)
        XCTAssertEqual(gateway.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.text), ["Keep working"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.rewindOrdinal), [nil])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.role, "user")
        XCTAssertEqual(viewModel.messages.first?.content, "Keep working")
        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" && $0.content == "Keep working" }.count, 1)
    }

    @MainActor
    func testSendMessageRollsBackOptimisticUserMessageWhenTicketMintFails() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"unauthorized"}"#.utf8))
        }

        let didStart = await viewModel.sendMessage("Keep working")

        XCTAssertFalse(didStart)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSendMessageRollsBackOptimisticUserMessageWhenConnectFails() async throws {
        let fabricator = ScriptedGatewayFabricator()
        fabricator.onMake = { gateway, _ in
            gateway.connectError = URLError(.cannotConnectToHost)
        }
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")

        XCTAssertFalse(didStart)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSendMessageRollsBackOptimisticUserMessageWhenSubmitFails() async throws {
        let fabricator = ScriptedGatewayFabricator()
        fabricator.onMake = { gateway, _ in
            gateway.submitError = URLError(.timedOut)
        }
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")

        XCTAssertFalse(didStart)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    // MARK: - Live stream event routing

    @MainActor
    func testLiveStreamEventsUpdateTranscriptBeforeCompletion() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "I need to inspect the workspace."))
        gateway.deliver(.toolStarted(sessionID: "session-abc", name: "read_file", input: .object(["path": .string("PROJECT_SPEC.md")])))
        gateway.deliver(.toolCompleted(sessionID: "session-abc", name: "read_file", output: .string("Read PROJECT_SPEC.md")))
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "First live token."))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.name, "read_file")
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, true)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "First live token.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertFalse(viewModel.responseCompletionHapticTrigger > 0)
    }

    @MainActor
    func testReasoningAndToolEventsAnchorToStableAssistantTurnBeforeFirstToken() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Use tools before answering")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "I should inspect the workspace."))
        // Reasoning chunks are flushed through the coalesced path; the anchor
        // is assigned at flush time.
        viewModel.flushPendingStreamingContent()

        let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.messageId, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.content, "")
        XCTAssertEqual(viewModel.reasoningAnchorMessageID, liveAssistantID)
        XCTAssertFalse(viewModel.hasStreamingAssistantMessageContent)

        gateway.deliver(.toolStarted(sessionID: "session-abc", name: "terminal", input: .object(["cmd": .string("pwd")])))

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.toolCallAnchorMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["terminal"])

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Live answer starts now."))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.messageId, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.content, "Live answer starts now.")
        XCTAssertTrue(viewModel.hasStreamingAssistantMessageContent)
    }

    @MainActor
    func testLiveStreamScrollTriggerCoalescesRapidUpdates() async throws {
        let fabricator = ScriptedGatewayFabricator()
        // Inject a tiny coalescing window for fast test awaits.
        let viewModel = try makeViewModel(
            gatewayFabricator: fabricator.fabricator,
            streamingScrollCoalescingDelayNanoseconds: 1_000_000
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Stream a long response")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        let initialTrigger = viewModel.streamingScrollTrigger

        for index in 0..<20 {
            gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "token-\(index) "))
        }
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)

        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 1)
        XCTAssertTrue(viewModel.messages.last?.content?.hasPrefix("token-0 token-1") == true)

        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "Check the next step."))
        gateway.deliver(.toolStarted(sessionID: "session-abc", name: "read_file", input: .object(["path": .string("README.md")])))
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 1)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 1)
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 2)
    }

    @MainActor
    func testLiveStreamContentCoalescesRapidTokenUpdates() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Stream a long response")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        for index in 0..<25 {
            gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "chunk-\(index) "))
        }

        try await waitForStreamingContent(
            viewModel,
            toSatisfy: { $0 == (0..<25).map { "chunk-\($0) " }.joined() }
        )
    }

    @MainActor
    func testDisplayedTranscriptMessagesMemoMatchesPureMappingAcrossAppendsAndEdits() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        func assertMemoMatchesPureMapping(_ message: String, line: UInt = #line) {
            XCTAssertEqual(
                viewModel.displayedTranscriptMessages,
                ChatViewModel.transcriptMessages(
                    from: viewModel.messages,
                    messageOffset: viewModel.messagesOffset
                ),
                message,
                line: line
            )
        }

        assertMemoMatchesPureMapping("memo should match for an empty transcript")

        let didStart = await viewModel.sendMessage("Stream a long response")
        XCTAssertTrue(didStart)
        assertMemoMatchesPureMapping("memo should match after the optimistic append")

        let gateway = try XCTUnwrap(fabricator.latest)
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "first chunk "))
        viewModel.flushPendingStreamingContent()
        XCTAssertTrue(viewModel.messages.last?.content?.contains("first chunk") == true)
        assertMemoMatchesPureMapping("memo should match after a streaming content edit")

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "second chunk "))
        viewModel.flushPendingStreamingContent()
        assertMemoMatchesPureMapping("memo should match after a second content edit")
    }

    @MainActor
    func testInterimDeltaEventsUpdateTranscriptBeforeCompletion() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Use the project skill")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Inspecting repo structure."))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Inspecting repo structure.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertFalse(viewModel.responseCompletionHapticTrigger > 0)
    }

    // MARK: - Completion / error / interrupt

    @MainActor
    func testMessageCompleteFlushesContentAndMarksResponseComplete() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Summarize")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Done with this."))
        gateway.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: "Done with this."))
        // messageComplete's content append is buffered behind the word-cadence
        // flush; drain it deterministically.
        viewModel.flushPendingStreamingContent()

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
        XCTAssertTrue(viewModel.responseCompletionNeedsTranscriptRefresh)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Summarize", "Done with this."])
    }

    @MainActor
    func testMessageErrorSurfacesAndClearsActiveStream() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let liveActivityManager = SpyChatLiveActivityManager()
        let viewModel = try makeViewModel(
            gatewayFabricator: fabricator.fabricator,
            liveActivityManager: liveActivityManager
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.error(sessionID: "session-abc", message: "server failed"))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.sendErrorMessage, "server failed")
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)
    }

    @MainActor
    func testCancelActiveStreamSendsInterruptAndClearsActiveStream() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Stop me later")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        _ = await viewModel.cancelActiveStream()

        // session.interrupt must be issued to the gateway and the live stream
        // cleared locally regardless of the coordinator's (nil) response.
        XCTAssertEqual(gateway.interruptedSessionIDs, ["session-abc"])
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testMessageInterruptedEventClearsActiveStream() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let liveActivityManager = SpyChatLiveActivityManager()
        let viewModel = try makeViewModel(
            gatewayFabricator: fabricator.fabricator,
            liveActivityManager: liveActivityManager
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.interrupted(sessionID: "session-abc"))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .cancelled)
    }

    // MARK: - Approval / clarification event routing

    @MainActor
    func testApprovalEventPublishesPromptAndRespondsWithoutStoppingChat() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(.approval(
            sessionID: "session-abc",
            command: "curl https://example.test/install.sh | bash",
            description: "High risk command",
            choices: ["network_download", "pipe_to_shell"]
        ))

        XCTAssertEqual(viewModel.approvalPrompt?.sessionID, "session-abc")
        XCTAssertEqual(viewModel.approvalPrompt?.pending.command, "curl https://example.test/install.sh | bash")
        XCTAssertEqual(viewModel.approvalPrompt?.patternKeys, ["network_download", "pipe_to_shell"])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    func testApprovalForDifferentSessionDoesNotRenderOverCurrentChat() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        viewModel.applyApprovalUpdate(
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: "other-approval",
                    command: "danger",
                    description: "Other session",
                    patternKey: "other"
                ),
                pendingCount: 1
            ),
            sessionID: "other-session"
        )

        XCTAssertNil(viewModel.approvalPrompt)

        viewModel.applyApprovalUpdate(
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: "current-approval",
                    command: "python script.py",
                    description: "Current session",
                    patternKey: "python_exec"
                ),
                pendingCount: 1
            ),
            sessionID: "session-abc"
        )

        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "current-approval")
    }

    @MainActor
    func testClarificationEventPublishesPromptAndQuestion() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Set up the project")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(.clarification(
            sessionID: "session-abc",
            requestID: "clarify-1",
            question: "Which database?",
            choices: [("Postgres", "postgres"), ("SQLite", "sqlite")]
        ))

        XCTAssertEqual(viewModel.clarificationPrompt?.sessionID, "session-abc")
        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "clarify-1")
        XCTAssertEqual(viewModel.clarificationPrompt?.question, "Which database?")
        XCTAssertEqual(viewModel.clarificationPrompt?.choices, ["Postgres", "SQLite"])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    // MARK: - Reconnect + in-flight projection

    @MainActor
    func testTransportDisconnectSuspendsActiveStream() async throws {
        let fabricator = ScriptedGatewayFabricator()
        var ticketCounter = 0
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            ticketCounter += 1
            return apiTestJSONResponse("{\"ticket\": \"ticket-\(ticketCounter)\"}", for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let firstGateway = try XCTUnwrap(fabricator.instances.first)
        XCTAssertEqual(fabricator.makeCount, 1)

        firstGateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Partial live answer."))
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Partial live answer."])

        // Transport drops: the coordinator suspends the stream connection and
        // schedules an async reconnect (deferred by the checking interval). No
        // new client is minted synchronously by the drop itself.
        firstGateway.simulateTransportDisconnect()

        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertEqual(fabricator.makeCount, 1, "The drop must not mint a fresh client synchronously")
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    func testInFlightAssistantProjectionAppliedOnceBeforeStreamDeltas() async throws {
        let fabricator = ScriptedGatewayFabricator()
        fabricator.onMake = { gateway, _ in
            gateway.resumeResultFactory = { sessionID in
                .withInflight(sessionID: sessionID, inflightText: "Expected prefix ")
            }
        }
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        // The resume projection's in-flight assistant text becomes the visible
        // streaming message prefix once (streamingAssistantMessageID was nil at
        // resume time).
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "continuation."))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Expected prefix continuation."])
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
    }

    @MainActor
    func testStaleEpochEventsAreIgnoredAfterReconnect() async throws {
        let fabricator = ScriptedGatewayFabricator()
        var ticketCounter = 0
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            ticketCounter += 1
            return apiTestJSONResponse("{\"ticket\": \"ticket-\(ticketCounter)\"}", for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let firstGateway = try XCTUnwrap(fabricator.instances.first)

        // Deliver a live delta from the FIRST epoch so it lands in the transcript,
        // then begin a second turn (new epoch) as a reconnect would.
        firstGateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "First epoch partial."))
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First epoch partial."])

        _ = await viewModel.sendMessage("Second message")
        XCTAssertEqual(fabricator.makeCount, 2)

        let assistantCountBeforeStale = viewModel.messages.filter { $0.role == "assistant" }.count
        // Events from the old epoch's client must not route into the new stream.
        firstGateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "STALE"))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, assistantCountBeforeStale)
        XCTAssertEqual(viewModel.messages.last?.content, "Second message")
    }

    // MARK: - Load-messages / cache / pagination

    @MainActor
    func testLoadMessagesClearsPendingStreamingBuffersBeforeReload() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            switch request.url?.path {
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "cwd": "/tmp/workspace",
                  "message_count": 2
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {
                      "role": "user",
                      "content": "Keep working",
                      "timestamp": 1770000100,
                      "message_id": "user-1"
                    },
                    {
                      "role": "assistant",
                      "content": "From server.",
                      "timestamp": 1770000101,
                      "message_id": "assistant-1"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        for index in 0..<5 {
            gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "buffered-\(index) "))
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "From server.")
    }

    @MainActor
    func testLoadMessagesDuringActiveStreamPreservesLiveStateWhenServerSnapshotIsStale() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            switch request.url?.path {
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "message_count": 1
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {
                      "role": "user",
                      "content": "Keep working",
                      "timestamp": 1770000100,
                      "message_id": "user-1"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "I need to inspect the workspace."))
        gateway.deliver(.toolStarted(sessionID: "session-abc", name: "read_file", input: .object(["path": .string("CURRENT.md")])))
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Partial live answer."))

        let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Partial live answer.")
    }

    @MainActor
    func testLoadMessagesUsesCachedTranscriptForTunnelUnavailableFailure() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Wrong session", timestamp: 1_770_000_003, messageId: "wrong-session")
            ],
            serverURL: serverURL,
            sessionID: "other-session",
            in: context
        )
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Wrong server", timestamp: 1_770_000_004, messageId: "wrong-server")
            ],
            serverURL: otherServerURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions/session-abc":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 502,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )
                return (try XCTUnwrap(response), Data("bad gateway".utf8))
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        let didSend = await viewModel.sendMessage("New message", modelContext: context)
        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.sendErrorMessage, "Reconnect to the server to send a message.")
    }

    @MainActor
    func testLoadMessagesSurfacesTunnelUnavailableFailureWhenCacheIsEmpty() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
            return (try XCTUnwrap(response), Data("bad gateway".utf8))
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server or tunnel is unavailable. Check that the Mac is awake, the Hermes Agent dashboard is running, and the tunnel is connected."
        )
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesDoesNotUseCachedTranscriptForRealServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached answer", timestamp: 1_770_000_001, messageId: "stale")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.errorMessage, "The Hermes server hit an internal error. Check the server logs, then try again.")
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesDoesNotReplaceSuccessfulOnlineTranscriptWithStaleCache() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached answer", timestamp: 1_770_000_001, messageId: "stale")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Fresh planning",
                  "message_count": 2
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {
                      "role": "user",
                      "content": "Fresh question",
                      "timestamp": 1770000100,
                      "message_id": "fresh-user"
                    },
                    {
                      "role": "assistant",
                      "content": "Fresh answer",
                      "timestamp": 1770000101,
                      "message_id": "fresh-assistant"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question", "Fresh answer"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: serverURL,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Fresh question", "Fresh answer"]
        )
    }

    @MainActor
    func testPrepareInitialMessageLoadPrimesCacheWithoutStartingNetwork() throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTFail("Cache preparation must not start a request: \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badURL)
        }

        viewModel.prepareInitialMessageLoad(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)
    }

    @MainActor
    func testPrepareInitialMessageLoadBoundsLargeCachedTranscriptToNewestPage() throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let cachedMessages = (0..<75).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Cached message \(index)",
                timestamp: Double(1_770_000_000 + index),
                messageId: "cached-\(index)"
            )
        }
        try CacheStore.cacheMessages(
            cachedMessages,
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTFail("Cache preparation must not start a request: \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badURL)
        }

        viewModel.prepareInitialMessageLoad(modelContext: context)

        XCTAssertEqual(viewModel.messages.count, 50)
        XCTAssertEqual(viewModel.messages.first?.content, "Cached message 25")
        XCTAssertEqual(viewModel.messages.last?.content, "Cached message 74")
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)
    }

    @MainActor
    func testLoadOlderMessagesUsesCurrentOffsetAndPrependsWithoutDuplicates() async throws {
        var requestQueries: [[String: String]] = []
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "message_count": 4
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                requestQueries.append(query)
                if query["offset"] == nil {
                    return apiTestJSONResponse("""
                    {
                      "session_id": "session-abc",
                      "messages": [
                        {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                        {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                      ],
                      "pagination": {"offset": 2, "returned": 2, "limit": 50}
                    }
                    """, for: request)
                }
                XCTAssertEqual(query["offset"], "2")
                XCTAssertEqual(query["order"], "oldest")
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {"role": "user", "content": "Older question", "timestamp": 1, "message_id": "u-0"},
                    {"role": "assistant", "content": "Older answer", "timestamp": 2, "message_id": "a-1"}
                  ],
                  "pagination": {"offset": 0, "returned": 2, "limit": 50}
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()

        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(requestQueries.count, 2)
        XCTAssertNil(requestQueries[0]["offset"])
        XCTAssertEqual(requestQueries[1]["offset"], "2")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Older question",
            "Older answer",
            "Recent question",
            "Recent answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testLoadOlderMessagesKeepsAffordanceWhenAnotherOlderPageExists() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "message_count": 51
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                if query["offset"] == nil {
                    return apiTestJSONResponse("""
                    {
                      "session_id": "session-abc",
                      "messages": [
                        {"role": "user", "content": "Tail", "timestamp": 51, "message_id": "u-50"}
                      ],
                      "pagination": {"offset": 50, "returned": 1, "limit": 50}
                    }
                    """, for: request)
                }
                XCTAssertEqual(query["offset"], "50")
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {"role": "assistant", "content": "Earlier page", "timestamp": 50, "message_id": "a-49"}
                  ],
                  "pagination": {"offset": 49, "returned": 1, "limit": 50}
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()

        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Earlier page", "Tail"])
        XCTAssertEqual(viewModel.messagesOffset, 49)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testReloadPreservesCachedOptimisticUserMessageWhenServerTemporarilyOmitsIt() async throws {
        let context = try makeContext()
        let fabricator = ScriptedGatewayFabricator()
        let sendingViewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await sendingViewModel.sendMessage("Keep working", modelContext: context)

        XCTAssertTrue(didStart)
        XCTAssertEqual(sendingViewModel.messages.compactMap(\.content), ["Keep working"])
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Keep working"]
        )

        let reopenedViewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "message_count": 1
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {
                      "role": "assistant",
                      "content": "Recovered transcript.",
                      "timestamp": 1770000100,
                      "message_id": "assistant-1"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await reopenedViewModel.loadMessages(modelContext: context)

        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.content), ["Keep working", "Recovered transcript."])
    }

    @MainActor
    func testLoadMessagesKeepsTranscriptEmptyDuringNetworkWhenCacheIsEmpty() async throws {
        let context = try makeContext()

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions/session-abc":
                sessionRequestStarted.fulfill()
                XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Fresh planning",
                  "message_count": 1
                }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {
                      "role": "user",
                      "content": "Fresh question",
                      "timestamp": 1770000100,
                      "message_id": "fresh-user"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.isLoading)

        releaseSessionResponse.signal()
        await loadTask.value

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question"])
    }

    // MARK: - Attachment upload / workspace

    @MainActor
    func testUploadAttachmentRejectsOversizedFileBeforeRequest() async throws {
        var didRequestUpload = false
        let viewModel = try makeViewModel { request in
            didRequestUpload = true
            XCTFail("Oversized attachment should not reach \(request.url?.path ?? "unknown path")")
            throw URLError(.badURL)
        }

        await viewModel.uploadAttachment(
            data: Data(count: PendingAttachment.maximumUploadBytes + 1),
            filename: "too-large.mov"
        )

        XCTAssertFalse(didRequestUpload)
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
        XCTAssertEqual(
            viewModel.uploadAttachmentErrorMessage,
            "too-large.mov is too large. Attachments must be 20 MB or smaller."
        )
    }

    @MainActor
    func testUploadAttachmentDownsamplesImagePreviewButUploadsOriginalData() async throws {
        let originalData = try makeJPEGData(size: CGSize(width: 1_600, height: 1_200))
        var uploadedBody: Data?
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadedBody = try XCTUnwrap(apiTestBodyData(from: request))
            return apiTestJSONResponse("""
            {
              "ok": true,
              "path": "/tmp/workspace/large.jpg",
              "entry": {
                "name": "large.jpg",
                "path": "/tmp/workspace/large.jpg",
                "size": \(originalData.count),
                "mime_type": "image/jpeg"
              }
            }
            """, for: request)
        }

        await viewModel.uploadAttachment(data: originalData, filename: "large.jpg", previewData: originalData)

        let attachment = try XCTUnwrap(viewModel.pendingAttachments.first)
        let thumbnailData = try XCTUnwrap(attachment.thumbnailData)
        XCTAssertNotNil(uploadedBody)
        XCTAssertTrue(try XCTUnwrap(uploadedBody).range(of: originalData) != nil)
        XCTAssertNotEqual(thumbnailData, originalData)
        XCTAssertGreaterThan(try maxPixelDimension(in: originalData), ImagePreviewDownsampler.attachmentMaxPixelSize)
        XCTAssertLessThanOrEqual(
            try maxPixelDimension(in: thumbnailData),
            ImagePreviewDownsampler.attachmentMaxPixelSize
        )
    }

    func testImagePreviewDownsamplerSkipsWorkWhenCallerIsCancelled() async throws {
        let originalData = try makeJPEGData(size: CGSize(width: 1_600, height: 1_200))
        let task = Task<Data?, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }

            return await ImagePreviewDownsampler.previewDataAsync(
                from: originalData,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            )
        }

        task.cancel()

        let thumbnailData = await task.value

        XCTAssertNil(thumbnailData)
    }

    @MainActor
    func testUploadAttachmentFailurePreservesExistingPendingAttachment() async throws {
        var uploadCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadCount += 1

            if uploadCount == 1 {
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "path": "/tmp/workspace/notes.txt",
                  "entry": {
                    "name": "notes.txt",
                    "path": "/tmp/workspace/notes.txt",
                    "size": 5,
                    "mime_type": "text/plain"
                  }
                }
                """, for: request)
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 413,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )
            return (try XCTUnwrap(response), Data("too large".utf8))
        }

        await viewModel.uploadAttachment(data: Data("hello".utf8), filename: "notes.txt")
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)

        await viewModel.uploadAttachment(data: Data("large".utf8), filename: "large.bin")

        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertEqual(viewModel.pendingAttachments.first?.name, "notes.txt")
        XCTAssertNotNil(viewModel.uploadAttachmentErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testDuplicateUploadFilenamesUseDistinctServerPathsAndLocalPreviews() async throws {
        let imageA = try makeJPEGData(size: CGSize(width: 12, height: 12))
        let imageB = try makeJPEGData(size: CGSize(width: 16, height: 12))
        var uploadedFilenames: [String] = []
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            switch request.url?.path {
            case "/api/upload":
                let filename = try apiTestMultipartFilename(from: request)
                uploadedFilenames.append(filename)
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "path": "/tmp/workspace/\(filename)",
                  "entry": {
                    "name": "\(filename)",
                    "path": "/tmp/workspace/\(filename)",
                    "size": 4,
                    "mime_type": "image/jpeg"
                  }
                }
                """, for: request)
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(data: Data("image-a".utf8), filename: "shared-image.jpg", previewData: imageA)
        await viewModel.uploadAttachment(data: Data("image-b".utf8), filename: "shared-image.jpg", previewData: imageB)

        XCTAssertEqual(uploadedFilenames.count, 2)
        XCTAssertEqual(uploadedFilenames[0], "shared-image.jpg")
        XCTAssertTrue(uploadedFilenames[1].hasPrefix("shared-image-"))
        XCTAssertTrue(uploadedFilenames[1].hasSuffix(".jpg"))
        XCTAssertNotEqual(uploadedFilenames[0], uploadedFilenames[1])
        XCTAssertEqual(viewModel.pendingAttachments.map(\.name), ["shared-image.jpg", "shared-image.jpg"])
        XCTAssertEqual(Set(viewModel.pendingAttachments.map(\.path)).count, 2)

        let didStart = await viewModel.sendMessage("Compare these")

        XCTAssertTrue(didStart)
        let message = try XCTUnwrap(viewModel.messages.first)
        let messageID = try XCTUnwrap(message.messageId)
        let paths = try XCTUnwrap(message.attachments?.compactMap(\.path))
        let previews = try XCTUnwrap(viewModel.localAttachmentPreviews[messageID])
        XCTAssertEqual(Set(previews.keys), Set(paths))
        XCTAssertEqual(previews[paths[0]], imageA)
        XCTAssertEqual(previews[paths[1]], imageB)
    }

    func testChatMessageTextStillAppendsAttachedFilesSuffixForFileUploads() {
        let file = PendingAttachment(
            name: "report.pdf",
            path: "/tmp/workspace/report.pdf",
            mime: "application/pdf",
            size: 1234,
            isImage: false,
            thumbnailData: nil
        )

        let text = PendingAttachment.chatMessageText(draft: "Summarize this", attachments: [file])

        XCTAssertEqual(text, "Summarize this\n\n[Attached files: /tmp/workspace/report.pdf]")
    }

    // MARK: - Slash commands

    @MainActor
    func testBareResumeSlashCommandFallsThroughToNormalSendPath() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": []}"#, for: request)
            case "/api/auth/ws-ticket":
                XCTFail("Executor fallthrough should let ChatView perform the normal send later.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/resume", viewModel: viewModel)

        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testUnknownNonBlockedSlashCommandFallsThroughToNormalSendPath() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": []}"#, for: request)
            case "/api/auth/ws-ticket":
                XCTFail("Executor fallthrough should let ChatView perform the normal send later.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/unknown-slash keep going", viewModel: viewModel)

        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testKnownUnsupportedSlashCommandStaysBlockedWithoutSkillLookup() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestedPaths.append(request.url?.path ?? "nil")
            XCTFail("Known unsupported commands should not request skills or start chat.")
            throw URLError(.badURL)
        }

        let result = await SlashCommandExecutor.execute(text: "/terminal", viewModel: viewModel)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Terminal is not available in the mobile app."))
        XCTAssertEqual(requestedPaths, [])
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSkillShortcutExecutesBeforeUnknownCommandFallthrough() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/spotify check songs", viewModel: viewModel)

        XCTAssertEqual(result, .executed(message: nil))
        let gateway = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(gateway.submittedPrompts.map(\.text), ["/spotify check songs"])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    func testSkillShortcutWithoutArgsReturnsLocalSkillInfoWithoutStartingChat() async throws {
        var didRequestSkills = false
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/skills":
                didRequestSkills = true
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/auth/ws-ticket":
                XCTFail("Skill shortcut without args should not start chat.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "")

        XCTAssertTrue(didRequestSkills)
        guard case .executed(let message) = result else {
            XCTFail("Expected local skill detail response.")
            return
        }
        let unwrappedMessage = try XCTUnwrap(message)
        XCTAssertTrue(unwrappedMessage.contains("### `/spotify`"))
        XCTAssertTrue(unwrappedMessage.contains("Control Spotify playback."))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSkillShortcutWithArgsStartsChatMessage() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "check songs")

        XCTAssertEqual(result, .executed(message: nil))
        let gateway = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(gateway.submittedPrompts.map(\.text), ["/spotify check songs"])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    func testClearSlashCommandClearsLocalTranscriptWithoutServerRequest() async throws {
        var requestCount = 0
        let viewModel = try makeViewModel { request in
            requestCount += 1
            switch request.url?.path {
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                { "id": "session-abc", "title": "Planning", "message_count": 2 }
                """, for: request)
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "messages": [
                    {"role": "user", "content": "Question", "timestamp": 1, "message_id": "u-1"},
                    {"role": "assistant", "content": "Answer", "timestamp": 2, "message_id": "a-2"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Clear should not call \(request.url?.path ?? "unknown path").")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "clear")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testQueuedSlashMessageFailureDoesNotRetryInTightLoop() async throws {
        let fabricator = ScriptedGatewayFabricator()
        var ticketCount = 0
        // The FIRST gateway establishes the live stream (submit succeeds); every
        // gateway made afterwards (the drain's send) fails submit persistently.
        fabricator.onMake = { gateway, index in
            if index >= 2 {
                gateway.submitError = URLError(.cannotConnectToHost)
            }
        }
        let viewModel = try makeViewModel(gatewayFabricator: fabricator.fabricator) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            ticketCount += 1
            return apiTestJSONResponse("{\"ticket\": \"ticket-\(ticketCount)\"}", for: request)
        }

        // 1. Establish a live stream so the queued message waits behind it.
        let didStart = await viewModel.sendMessage("first message")
        XCTAssertTrue(didStart)
        let firstGateway = try XCTUnwrap(fabricator.instances.first)

        // 2. Queue one slash message behind the active stream.
        let queueCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "queue"))
        let queued = await viewModel.executeSlashCommand(queueCommand, args: "retry-me")
        XCTAssertEqual(queued, .executed(message: "Queued for next turn (#1)."))

        // 3. Finishing the stream (via messageInterrupted → finishStream) is the
        //    natural drain trigger. The drained send fails persistently
        //    (submitError) and must not retry in a tight loop.
        firstGateway.deliver(GatewayEventFixture.interrupted(sessionID: "session-abc"))
        XCTAssertNil(viewModel.activeStreamID)

        // 4. Let the drain (and any retry loop) fully quiesce. MockURLProtocol
        //    resolves synchronously, so once the gateway count is stable the send
        //    attempts are done.
        var lastSeen = fabricator.makeCount
        var stablePolls = 0
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if fabricator.makeCount == lastSeen {
                stablePolls += 1
                if stablePolls >= 3 { break }
            } else {
                stablePolls = 0
                lastSeen = fabricator.makeCount
            }
        }

        // The drain ran exactly once: exactly one new gateway epoch after the live
        // stream's, with exactly one submit attempt (the failed queued send).
        let drainedInstances = Array(fabricator.instances.dropFirst())
        XCTAssertEqual(drainedInstances.count, 1, "A failed queued send should be attempted exactly once, not retried in a loop")
        XCTAssertEqual(drainedInstances.first?.submittedPrompts.count, 1)

        // The message remains queued for a later natural trigger instead of being dropped.
        let status = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "status")))
        guard case let .executed(message) = status, let statusText = message else {
            return XCTFail("Expected /status to return an executed message, got \(status).")
        }
        XCTAssertTrue(
            statusText.contains("Queued messages: 1"),
            "The failed queued message should still be queued. Status was:\n\(statusText)"
        )
    }

    // MARK: - Composer configuration (REST-only paths)

    @MainActor
    func testSelectingComposerModelWithNilSessionIDIsBlocked() async throws {
        let session = SessionSummary(
            sessionId: nil,
            title: "Planning",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            modelProvider: "openai",
            profile: "work"
        )
        let viewModel = try makeViewModel(sessionSummary: session) { request in
            XCTFail("Selecting a composer model without a session ID must not call \(request.url?.path ?? "nil").")
            throw URLError(.badURL)
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(viewModel.composerConfigurationErrorMessage, "The server did not provide a session ID.")
    }

    @MainActor
    func testSelectingCustomComposerModelWhileStreamingIsBlocked() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let viewModel = try makeViewModel(
            gatewayFabricator: fabricator.fabricator,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Start streaming")
        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        ))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(
            viewModel.composerConfigurationErrorMessage,
            "Wait for the current response to finish before changing models."
        )
    }

    @MainActor
    func testLoadComposerConfigurationLoadsSessionProfileDefault() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: nil, modelProvider: nil, profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/profiles/active":
                return apiTestJSONResponse(#"{"active": "work"}"#, for: request)
            case "/api/model/options":
                return apiTestJSONResponse("""
                {
                  "model": "\(openRouterModel)",
                  "provider": "openrouter",
                  "providers": [
                    {
                      "slug": "openrouter",
                      "name": "OpenRouter",
                      "models": ["\(openRouterModel)"],
                      "capabilities": { "\(openRouterModel)": { "reasoning": true } }
                    }
                  ]
                }
                """, for: request)
            case "/api/fs/default-cwd":
                return apiTestJSONResponse(#"{"cwd": "/tmp/workspace"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()

        XCTAssertEqual(viewModel.selectedModelID, openRouterModel)
        XCTAssertEqual(viewModel.selectedProfileTitle, "work")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/workspace")
    }

    // MARK: - Reasoning / misc pure helpers

    func testDeduplicatedReasoningTextsRemovesIdenticalThinkingBodies() {
        let texts = ChatViewModel.deduplicatedReasoningTexts([
            "  **Reading workout profile**\nChecking the user's profile and workout log.  ",
            "\n**Reading workout profile**\nChecking the user's profile and workout log.\n",
            "Checking a different source.",
            "   "
        ])

        XCTAssertEqual(
            texts,
            [
                "**Reading workout profile**\nChecking the user's profile and workout log.",
                "Checking a different source."
            ]
        )
    }

    // MARK: - Device-local Listen (AVSpeechSynthesizer)

    @MainActor
    func testOpeningSessionDoesNotCreateSpeechSynthesizer() throws {
        var createdSynthesizers = 0

        _ = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return SpySpeechSynthesizer()
            }
        ) { request in
            XCTFail("Opening a session should not request network work in this test.")
            return apiTestJSONResponse("{}", for: request)
        }

        XCTAssertEqual(createdSynthesizers, 0)
    }

    @MainActor
    func testListenCreatesSpeechSynthesizerOnlyWhenRequested() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var createdSynthesizers = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return speechSynthesizer
            }
        ) { request in
            XCTFail("Device-local Listen must not make network requests: \(request.url?.path ?? "nil")")
            return apiTestJSONResponse("{}", for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Playback should be explicit.",
                timestamp: 1_770_000_001,
                messageId: "assistant-1"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-1")

        XCTAssertEqual(createdSynthesizers, 1)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Playback should be explicit."])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-1")
    }

    func testListenAudioSessionRoutesToSpeakerNotEarpiece() {
        XCTAssertEqual(ListenAudioSessionConfiguration.category, .playback)
        XCTAssertEqual(ListenAudioSessionConfiguration.mode, .spokenAudio)
        XCTAssertTrue(
            ListenAudioSessionConfiguration.deactivationOptions.contains(.notifyOthersOnDeactivation)
        )
    }

    @MainActor
    func testListenActivatesAudioSessionBeforeSpeaking() async throws {
        let recorder = ListenCallRecorder()
        let speechSynthesizer = SpySpeechSynthesizer(recorder: recorder)
        let audioSession = SpyListenAudioSession(recorder: recorder)
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            XCTFail("Device-local Listen must not make network requests: \(request.url?.path ?? "nil")")
            return apiTestJSONResponse("{}", for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Out loud, please.",
                timestamp: 1_770_000_002,
                messageId: "assistant-2"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        XCTAssertEqual(audioSession.activateCount, 0)
        await drainMainActor()

        XCTAssertEqual(audioSession.activateCount, 1)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Out loud, please."])
        let activateIndex = try XCTUnwrap(recorder.events.firstIndex(of: "activate"))
        let speakIndex = try XCTUnwrap(recorder.events.firstIndex(of: "speak"))
        XCTAssertLessThan(activateIndex, speakIndex)
    }

    @MainActor
    func testStaleCancelAfterSwitchingMessagesKeepsNewListenActive() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let audioSession = SpyListenAudioSession()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            XCTFail("Device-local Listen must not make network requests: \(request.url?.path ?? "nil")")
            return apiTestJSONResponse("{}", for: request)
        }
        func makeContext(_ id: String, _ text: String, _ timestamp: Double) throws -> MessageActionContext {
            try XCTUnwrap(MessageActionContext(
                message: ChatMessage(role: "assistant", content: text, timestamp: timestamp, messageId: id),
                visibleIndex: 0,
                messagesOffset: 0
            ))
        }

        viewModel.toggleListening(to: try makeContext("assistant-A", "First message.", 1_770_000_010))
        await drainMainActor()
        let utteranceA = try XCTUnwrap(speechSynthesizer.spokenUtterances.first)
        viewModel.toggleListening(to: try makeContext("assistant-B", "Second message.", 1_770_000_011))
        await drainMainActor()

        XCTAssertEqual(viewModel.listeningMessageID, "assistant-B")
        let deactivationsBeforeStaleCallback = audioSession.deactivateCount

        // A's cancel callback now arrives late, after B has started speaking. It
        // must be ignored so it can't clear B's "now playing" state.
        speechSynthesizer.fireDidCancel(utteranceA)
        await drainMainActor()

        XCTAssertEqual(viewModel.listeningMessageID, "assistant-B")
        XCTAssertEqual(audioSession.deactivateCount, deactivationsBeforeStaleCallback)

        // A matching completion (for the live utterance B) still tears down cleanly.
        let utteranceB = try XCTUnwrap(speechSynthesizer.spokenUtterances.last)
        speechSynthesizer.fireDidCancel(utteranceB)
        await drainMainActor()

        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertEqual(audioSession.deactivateCount, deactivationsBeforeStaleCallback + 1)
    }

    @MainActor
    func testStoppingListeningReleasesAudioSession() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let audioSession = SpyListenAudioSession()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            XCTFail("Device-local Listen must not make network requests: \(request.url?.path ?? "nil")")
            return apiTestJSONResponse("{}", for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Stop me cleanly.",
                timestamp: 1_770_000_003,
                messageId: "assistant-3"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await drainMainActor()
        let deactivationsAfterStart = audioSession.deactivateCount

        viewModel.stopListening()

        XCTAssertGreaterThan(audioSession.deactivateCount, deactivationsAfterStart)
        XCTAssertNil(viewModel.listeningMessageID)
    }

    // MARK: - Log helpers

    /// Lets a `Task { @MainActor … }` enqueued by a delegate callback run to completion
    /// before assertions. Same-actor tasks run FIFO, so awaiting a task enqueued *after*
    /// the callback's drains it; the leading yields add slack.
    @MainActor
    private func drainMainActor() async {
        for _ in 0..<3 { await Task.yield() }
        await Task { @MainActor in }.value
    }

    @MainActor
    private func makeViewModel(
        gatewayFabricator: (@MainActor (URL, String, String?) -> any GatewayClientProviding)? = nil,
        sessionSummary: SessionSummary? = nil,
        liveActivityManager: (any AgentLiveActivityManaging)? = nil,
        pollingIntervals: ChatPollingIntervals = .standard,
        streamingScrollCoalescingDelayNanoseconds: UInt64 = 16_000_000,
        streamingWordRevealCadenceNanoseconds: UInt64 = 48_000_000,
        speechSynthesizerFactory: @escaping () -> any ChatSpeechSynthesizing = { AVSpeechSynthesizer() },
        listenAudioSession: (any ListenAudioSessionControlling)? = nil,
        userDefaults: UserDefaults = .standard,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)
        let summary: SessionSummary
        if let sessionSummary {
            summary = sessionSummary
        } else {
            summary = try makeSession()
        }

        let resolvedFabricator = gatewayFabricator ?? { baseURL, ticket, profile in
            ScriptedGatewayClient()
        }

        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            liveActivityManager: liveActivityManager,
            pollingIntervals: pollingIntervals,
            streamingScrollCoalescingDelayNanoseconds: streamingScrollCoalescingDelayNanoseconds,
            streamingWordRevealCadenceNanoseconds: streamingWordRevealCadenceNanoseconds,
            speechSynthesizerFactory: speechSynthesizerFactory,
            // Default to a spy so unit tests never drive the live shared AVAudioSession.
            listenAudioSession: listenAudioSession ?? SpyListenAudioSession(),
            userDefaults: userDefaults,
            gatewayFabricator: resolvedFabricator
        )

        return viewModel
    }

    private func makeSession(
        title: String = "Planning",
        model: String? = "gpt-5.4",
        modelProvider: String? = nil,
        profile: String? = nil
    ) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let modelJSON = model.map { ",\n              \"model\": \"\($0)\"" } ?? ""
        let modelProviderJSON = modelProvider.map { ",\n              \"model_provider\": \"\($0)\"" } ?? ""
        let profileJSON = profile.map { ",\n              \"profile\": \"\($0)\"" } ?? ""
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "\(title)",
              "workspace": "/tmp/workspace"\(modelJSON)\(modelProviderJSON)\(profileJSON)
            }
            """.utf8)
        )
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func makeJPEGData(size: CGSize) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }

        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func maxPixelDimension(in data: Data) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        return max(width, height)
    }

    @MainActor
    private func waitForStreamingContent(
        _ viewModel: ChatViewModel,
        toSatisfy predicate: (String?) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if predicate(viewModel.messages.last?.content) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(
            predicate(viewModel.messages.last?.content),
            file: file,
            line: line
        )
    }
}

@MainActor
private final class SpyChatLiveActivityManager: AgentLiveActivityManaging {
    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {}

    func update(_ event: AgentLiveActivityEvent) {}

    func markStale() {}

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }

    func orphanedActivities() -> [OrphanedLiveActivity] { [] }
    func endOrphanedActivity(streamID: String, status: AgentRunActivityStatus, activity: String) async -> Bool { false }
}

/// Shared, interleaved call log so tests can prove ordering ACROSS the audio-session
/// spy and the speech-synthesizer spy in one timeline — not two independent logs.
private final class ListenCallRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private final class SpySpeechSynthesizer: ChatSpeechSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    private(set) var spokenStrings: [String] = []
    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private let recorder: ListenCallRecorder?

    init(recorder: ListenCallRecorder? = nil) {
        self.recorder = recorder
    }

    func speak(_ utterance: AVSpeechUtterance) {
        spokenStrings.append(utterance.speechString)
        spokenUtterances.append(utterance)
        isSpeaking = true
        recorder?.record("speak")
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopBoundaries.append(boundary)
        isSpeaking = false
        isPaused = false
        return true
    }

    /// Drives the production delegate's `didCancel` exactly as `AVSpeechSynthesizer`
    /// would after `stopSpeaking(at:)` — late, via the delegate's `@MainActor` hop.
    func fireDidCancel(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }
}

@MainActor
private final class SpyListenAudioSession: ListenAudioSessionControlling {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private let recorder: ListenCallRecorder?

    init(recorder: ListenCallRecorder? = nil) {
        self.recorder = recorder
    }

    func activate() {
        activateCount += 1
        recorder?.record("activate")
    }

    func deactivate() {
        deactivateCount += 1
        recorder?.record("deactivate")
    }
}
