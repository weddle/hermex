import SwiftData
import XCTest
@testable import HermesMobile

/// Gateway-era coordinator tests for the Hermes Agent transport.
///
/// These drive `ChatStreamCoordinator` through `ScriptedGatewayClient`/
/// `ScriptedGatewayFabricator` (injected via `gatewayFabricator`), so the
/// coordinator lifecycle — mint ticket → connect → resume → submit → event
/// routing → epoch rejection → in-flight projection — is exercised exactly as
/// the native dashboard stream does it. There is no SSE stream/URL/replay
/// concept here: activeStreamID holds the gateway session id of the live turn.
final class ChatStreamCoordinatorTests: APIClientTestCase {
    // MARK: - Connect → resume → submit → delegate routing

    @MainActor
    func testBeginTurnConnectsResumesSubmitsAndRoutesStreamEvents() async throws {
        var ticketCounter = 0
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator { request in
            ticketCounter += 1
            return apiTestJSONResponse("{\"ticket\": \"ticket-\(ticketCounter)\"}", for: request)
        }

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")

        let gateway = try XCTUnwrap(fabricator.latest)
        // One fresh gateway per connection epoch: connect → resume → submit.
        XCTAssertEqual(fabricator.makeCount, 1)
        XCTAssertEqual(fabricator.tickets, ["ticket-1"])
        XCTAssertEqual(gateway.connectCount, 1)
        XCTAssertEqual(gateway.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.sessionID), ["session-abc"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.text), ["Hello"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.rewindOrdinal), [nil])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
        XCTAssertEqual(delegate.startMonitoringCount, 1)
        XCTAssertEqual(liveActivityManager.starts, [
            CoordinatorSpyLiveActivityManager.Start(
                sessionID: "session-abc",
                sessionTitle: "Planning",
                streamID: "session-abc"
            )
        ])

        // Delta + reasoning deltas route into the append paths.
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Hello "))
        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "thinking…"))
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "world"))
        XCTAssertEqual(delegate.tokens, ["Hello ", "world"])
        XCTAssertEqual(liveActivityManager.updates, [.reasoning("thinking…")])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")

        // Completion flushes final content and finalizes the run.
        gateway.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: " world"))
        XCTAssertEqual(delegate.tokens, ["Hello ", "world", " world"])
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues, [true])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .complete)
    }

    @MainActor
    func testBeginTurnUsesRuntimeSessionIDReturnedByResume() async throws {
        let fabricator = ScriptedGatewayFabricator()
        fabricator.onMake = { gateway, _ in
            gateway.resumeResultFactory = { _ in .empty(sessionID: "runtime-123") }
        }
        let (coordinator, _, delegate, _) = makeCoordinator(fabricator: fabricator)

        try await coordinator.beginTurn(sessionID: "stored-abc", prompt: "Hello")

        let gateway = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(gateway.resumeSessionIDs, ["stored-abc"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.sessionID), ["runtime-123"])
        XCTAssertEqual(coordinator.activeStreamID, "runtime-123")

        gateway.deliver(GatewayEventFixture.delta(sessionID: "runtime-123", text: "Works"))
        XCTAssertEqual(delegate.tokens, ["Works"])
    }

    @MainActor
    func testBeginTurnRewindOrdinalReroutesToSubmitPrompt() async throws {
        let (coordinator, _, _, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(
            sessionID: "session-abc",
            prompt: "Rewrite that",
            rewindOrdinal: 3
        )

        let gateway = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(gateway.submittedPrompts.map(\.text), ["Rewrite that"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.rewindOrdinal), [3])
        // No stream-ID replay on the gateway: resume replaces after_seq entirely.
        XCTAssertNil(coordinator.lastEventID)
    }

    @MainActor
    func testToolStartedAndCompletedRouteToDelegate() async throws {
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "List files")
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.toolStarted(
            sessionID: "session-abc",
            name: "bash",
            input: .object(["cmd": .string("ls")])
        ))
        gateway.deliver(GatewayEventFixture.toolCompleted(
            sessionID: "session-abc",
            name: "bash",
            output: .string("file.txt")
        ))

        XCTAssertEqual(delegate.toolCalls, [
            ToolStreamEvent(
                eventType: nil,
                name: "bash",
                preview: nil,
                args: ["cmd": .string("ls")],
                duration: nil,
                isError: nil
            )
        ])
        XCTAssertEqual(delegate.completedToolCalls, [
            ToolStreamEvent(
                eventType: nil,
                name: "bash",
                preview: "file.txt",
                args: nil,
                duration: nil,
                isError: nil
            )
        ])
        XCTAssertEqual(liveActivityManager.updates, [.toolStarted(name: "bash"), .toolCompleted])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
    }

    @MainActor
    func testTitleEventUpdatesDelegateAndAdvancesProgress() async throws {
        let (coordinator, _, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.title(sessionID: "session-abc", title: "Renamed Session"))

        XCTAssertEqual(delegate.titles, [TitleStreamEvent(sessionId: "session-abc", title: "Renamed Session")])
        XCTAssertNotNil(coordinator.lastProgressDate)
    }

    @MainActor
    func testApprovalEventRoutesPendingUpdate() async throws {
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Run it")
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.approval(
            sessionID: "session-abc",
            command: "sudo rm -rf /tmp/x",
            description: "Delete directory",
            choices: ["allow", "deny"]
        ))

        XCTAssertEqual(delegate.approvalUpdates, [
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: nil,
                    command: "sudo rm -rf /tmp/x",
                    description: "Delete directory",
                    patternKey: nil,
                    patternKeys: ["allow", "deny"]
                ),
                pendingCount: 1
            )
        ])
        XCTAssertEqual(liveActivityManager.updates, [.waitingForApproval])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
    }

    @MainActor
    func testClarificationEventRoutesPendingUpdate() async throws {
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Do the thing")
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.clarification(
            sessionID: "session-abc",
            requestID: "clar-42",
            question: "Which environment?",
            choices: [("production", "prod"), ("development", "dev")]
        ))

        XCTAssertEqual(delegate.clarificationUpdates, [
            ClarificationPendingResponse(
                pending: PendingClarification(
                    clarifyId: "clar-42",
                    question: "Which environment?",
                    choicesOffered: ["production", "development"],
                    sessionId: "session-abc",
                    kind: nil,
                    requestedAt: nil,
                    timeoutSeconds: nil,
                    expiresAt: nil
                ),
                pendingCount: 1
            )
        ])
        XCTAssertEqual(liveActivityManager.updates, [.waitingForClarification])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
    }

    @MainActor
    func testMessageErrorSurfacesAndFinalizesFailed() async throws {
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.error(sessionID: "session-abc", message: "server failed"))

        XCTAssertEqual(delegate.errorMessages, ["server failed"])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    @MainActor
    func testMessageInterruptedFinalizesCancelled() async throws {
        let (coordinator, liveActivityManager, _, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.interrupted(sessionID: "session-abc"))

        XCTAssertEqual(liveActivityManager.ends.last?.status, .cancelled)
        XCTAssertNil(coordinator.activeStreamID)
    }

    // MARK: - Cancel / suspend

    @MainActor
    func testCancelSendsInterruptAndFinalizesCancelled() async throws {
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
        let gateway = try XCTUnwrap(fabricator.latest)

        let response = try await coordinator.cancelActiveStream()

        XCTAssertEqual(gateway.interruptedSessionIDs, ["session-abc"])
        XCTAssertNil(response?.ok)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .cancelled)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    @MainActor
    func testSuspendDisconnectsGatewayAndMarksStale() async throws {
        let (coordinator, liveActivityManager, delegate, fabricator) = makeCoordinator()

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
        let gateway = try XCTUnwrap(fabricator.latest)

        coordinator.suspendActiveStreamConnection()

        XCTAssertEqual(gateway.disconnectCount, 1)
        XCTAssertTrue(coordinator.isConnectionSuspended)
        XCTAssertEqual(delegate.saveSnapshotCount, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues, [true])
        XCTAssertEqual(liveActivityManager.markStaleCount, 1)
    }

    // MARK: - Fresh-ticket reconnect

    @MainActor
    func testReconnectMintsFreshTicketPerConnectionAndResumesInOrder() async throws {
        var ticketCounter = 0
        let (coordinator, _, delegate, fabricator) = makeCoordinator { request in
            ticketCounter += 1
            return apiTestJSONResponse("{\"ticket\": \"ticket-\(ticketCounter)\"}", for: request)
        }

        try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
        let first = try XCTUnwrap(fabricator.instances.first)
        coordinator.suspendActiveStreamConnection()
        XCTAssertEqual(first.disconnectCount, 1)

        // Foreground reconnect reloads the transcript, then starts a brand-new
        // epoch with a fresh single-use ticket and a fresh client.
        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(fabricator.makeCount, 2)
        XCTAssertEqual(fabricator.tickets, ["ticket-1", "ticket-2"])
        XCTAssertEqual(fabricator.baseURLs, [
            URL(string: "https://example.test")!,
            URL(string: "https://example.test")!
        ])
        XCTAssertEqual(fabricator.profiles, [nil, nil])
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")

        let second = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(second.connectCount, 1)
        XCTAssertEqual(second.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(second.submittedPrompts.map(\.text), [])
        XCTAssertEqual(delegate.startConnectionReplayValues, [false, false])
    }

    // MARK: - Stale-epoch rejection

    @MainActor
    func testStaleEpochEventsAreIgnoredAfterNewConnection() async throws {
        let (coordinator, _, delegate, fabricator) = makeCoordinator()

        await coordinator.start(streamID: "session-abc")
        await coordinator.start(streamID: "session-abc")

        XCTAssertEqual(fabricator.makeCount, 2)
        let stale = fabricator.instances[0]
        let fresh = fabricator.instances[1]

        // Events delivered through the old epoch's client are discarded.
        stale.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "stale delta"))
        stale.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: "stale complete"))
        XCTAssertTrue(delegate.tokens.isEmpty)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")

        // The current epoch's client still routes.
        fresh.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "fresh"))
        XCTAssertEqual(delegate.tokens, ["fresh"])
    }

    @MainActor
    func testStaleEpochDisconnectIsIgnored() async throws {
        let (coordinator, _, delegate, fabricator) = makeCoordinator()

        await coordinator.start(streamID: "session-abc")
        await coordinator.start(streamID: "session-abc")

        let stale = fabricator.instances[0]
        stale.simulateTransportDisconnect()
        // The disconnect callback hops through a Task; yield so it has run before
        // we assert the stale epoch's disconnect was ignored.
        await Task.yield()

        // The stale client's disconnect must not suspend the current epoch.
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
        XCTAssertEqual(delegate.saveSnapshotCount, 0)
    }

    // MARK: - In-flight prefix applied once

    @MainActor
    func testInflightPrefixAppliedOnceOnResumeAndNotDuplicated() async throws {
        let fabricator = ScriptedGatewayFabricator()
        fabricator.onMake = { instance, _ in
            instance.resumeResultFactory = { sessionID in
                .withInflight(sessionID: sessionID, inflightText: "Partial answer")
            }
        }
        let (coordinator, _, delegate, _) = makeCoordinator(fabricator: fabricator)

        await coordinator.start(streamID: "session-abc")

        // Fresh resume: the in-flight projection is appended exactly once to the
        // visible streaming message.
        XCTAssertEqual(delegate.tokens, ["Partial answer"])
        XCTAssertEqual(delegate.tokens.count, 1)

        // Subsequent deltas append after the prefix rather than duplicating it.
        let gateway = try XCTUnwrap(fabricator.latest)
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: " continues"))
        XCTAssertEqual(delegate.tokens, ["Partial answer", " continues"])

        // Reconnect with the same projection: the visible streaming message
        // already carries the prefix (the delegate reports a live message ID),
        // so the resume must NOT prepend it a second time.
        delegate.streamCoordinatorStreamingAssistantMessageID = "assistant-live"
        await coordinator.start(streamID: "session-abc")
        XCTAssertEqual(fabricator.makeCount, 2)
        XCTAssertEqual(delegate.tokens, ["Partial answer", " continues"])
    }

    // MARK: - Submit failure cleanup

    @MainActor
    func testBeginTurnSubmitFailureTearsDownAndThrows() async throws {
        let fabricator = ScriptedGatewayFabricator()
        fabricator.onMake = { instance, _ in
            instance.submitError = TestGatewayError(message: "submit failed")
        }
        let (coordinator, _, _, _) = makeCoordinator(fabricator: fabricator)

        do {
            try await coordinator.beginTurn(sessionID: "session-abc", prompt: "Hello")
            XCTFail("beginTurn must throw when the prompt submit fails")
        } catch let error as TestGatewayError {
            XCTAssertEqual(error.message, "submit failed")
        }

        let gateway = try XCTUnwrap(fabricator.latest)
        XCTAssertEqual(gateway.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(gateway.submittedPrompts.map(\.text), ["Hello"])
        // Clean teardown: the gateway is disconnected and the turn is closed so a
        // later reconnect resumes the session without the failed prompt.
        XCTAssertEqual(gateway.disconnectCount, 1)
        XCTAssertNil(coordinator.activeStreamID)
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(
        liveActivityManager: CoordinatorSpyLiveActivityManager? = nil,
        delegate: CoordinatorDelegateSpy? = nil,
        timing: ChatStreamCoordinatorTiming = .standard,
        fabricator: ScriptedGatewayFabricator? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }
    ) -> (
        coordinator: ChatStreamCoordinator,
        liveActivityManager: CoordinatorSpyLiveActivityManager,
        delegate: CoordinatorDelegateSpy,
        fabricator: ScriptedGatewayFabricator
    ) {
        let liveActivityManager = liveActivityManager ?? CoordinatorSpyLiveActivityManager()
        let delegate = delegate ?? CoordinatorDelegateSpy()
        let fabricator = fabricator ?? ScriptedGatewayFabricator()
        let coordinator = ChatStreamCoordinator(
            client: makeClient(handler: handler),
            liveActivityManager: liveActivityManager,
            showsLiveActivityResponseExcerpts: false,
            timing: timing,
            gatewayFabricator: fabricator.fabricator
        )
        coordinator.attach(delegate: delegate)
        return (coordinator, liveActivityManager, delegate, fabricator)
    }
}

private struct TestGatewayError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
private final class CoordinatorDelegateSpy: ChatStreamCoordinatorDelegate {
    var streamCoordinatorSessionID: String? = "session-abc"
    var streamCoordinatorDisplayTitle = "Planning"
    var streamCoordinatorHasRunningLiveToolCall = false
    var streamCoordinatorHasPendingPrompt = false
    var latestServerLoadHadAssistantResponseAfterLatestUser = false
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool {
        latestServerLoadHadAssistantResponseAfterLatestUser
    }
    var streamCoordinatorStreamingAssistantMessageID: String?

    private(set) var loadMessagesCount = 0
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringClearPromptValues: [Bool] = []
    private(set) var saveSnapshotCount = 0
    private(set) var restoredSnapshotStreamIDs: [String] = []
    private(set) var removedSnapshotStreamIDs: [String?] = []
    private(set) var flushedNoticeCount = 0
    private(set) var drainQueueCount = 0
    private(set) var refreshTitleCount = 0
    private(set) var completedNeedsTranscriptRefreshValues: [Bool] = []
    private(set) var finishCount = 0
    private(set) var errorMessages: [String] = []
    private(set) var recoveryErrors: [String] = []
    private(set) var startConnectionReplayValues: [Bool] = []
    private(set) var resetRecoveryCount = 0
    private(set) var tokens: [String] = []
    private(set) var titles: [TitleStreamEvent] = []
    private(set) var toolCalls: [ToolStreamEvent] = []
    private(set) var completedToolCalls: [ToolStreamEvent] = []
    private(set) var approvalUpdates: [ApprovalPendingResponse] = []
    private(set) var clarificationUpdates: [ClarificationPendingResponse] = []
    private(set) var donePayloads: [DoneStreamEvent] = []
    private(set) var pendingSteerLeftovers: [String] = []
    var latestAssistantMessageID: String? = "assistant-latest"
    var restoredSnapshotEventID: String?
    var appendTokenResult = true
    var doneHasCompletedTranscript = false
    var onLoadMessages: (() async -> Void)?

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        loadMessagesCount += 1
        await onLoadMessages?()
    }

    func streamCoordinatorLatestAssistantMessageID() -> String? {
        latestAssistantMessageID
    }

    func streamCoordinatorStartAuxiliaryMonitoring() {
        startMonitoringCount += 1
    }

    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool) {
        stopMonitoringClearPromptValues.append(clearPrompt)
    }

    func streamCoordinatorSaveSnapshotIfNeeded() {
        saveSnapshotCount += 1
    }

    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String? {
        restoredSnapshotStreamIDs.append(streamID)
        return restoredSnapshotEventID
    }

    func streamCoordinatorRemoveSnapshot(streamID: String?) {
        removedSnapshotStreamIDs.append(streamID)
    }

    func streamCoordinatorFlushPinnedLocalNoticesToTranscript() {
        flushedNoticeCount += 1
    }

    func streamCoordinatorDrainQueuedSlashMessageIfIdle() {
        drainQueueCount += 1
    }

    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded() {
        refreshTitleCount += 1
    }

    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool) {
        completedNeedsTranscriptRefreshValues.append(needsTranscriptRefresh)
    }

    func streamCoordinatorDidFinishStream() {
        finishCount += 1
    }

    func streamCoordinatorDidReceiveErrorMessage(_ message: String) {
        errorMessages.append(message)
    }

    func streamCoordinatorDidReceiveRecoveryError(_ error: Error) {
        recoveryErrors.append(error.localizedDescription)
    }

    func streamCoordinatorDidStartConnection(isReplay: Bool) {
        startConnectionReplayValues.append(isReplay)
    }

    func streamCoordinatorDidResetRecoveryState() {
        resetRecoveryCount += 1
    }

    func streamCoordinatorAppendToken(_ text: String) -> Bool {
        tokens.append(text)
        return appendTokenResult
    }

    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        payload.text?.isEmpty == false
    }

    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        !text.isEmpty
    }

    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        toolCalls.append(payload)
        return true
    }

    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        completedToolCalls.append(payload)
        return true
    }

    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        titles.append(payload)
        return payload.title?.isEmpty == false
    }

    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        donePayloads.append(payload)
        return doneHasCompletedTranscript
    }

    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse) {
        approvalUpdates.append(update)
    }

    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse) {
        clarificationUpdates.append(update)
    }

    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pendingSteerLeftovers.append(trimmed)
        return true
    }
}

@MainActor
private final class CoordinatorSpyLiveActivityManager: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let sessionTitle: String
        let streamID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [Start] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var markStaleCount = 0
    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        markStaleCount += 1
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}
