import SwiftData
import XCTest
@testable import HermesMobile

/// Contract tests for the riskiest gateway reconnect paths. The SSE-era
/// replay/`after_seq` journal has no gateway equivalent: `session.resume`
/// returns the durable transcript plus any in-flight projection. So the
/// reconnect contract here is expressed in gateway terms —
///
///   1. a disconnect/suspend reconnect mints a NEW single-use ticket and NEW
///      client (fresh connection epoch);
///   2. events delivered on a superseded (pre-reconnect) client are rejected as
///      stale-epoch;
///   3. a resumed live turn applies `inflightAssistantText` as a visible-stream
///      prefix exactly once — session-info echoes never re-apply it.
///
/// Each test drives a real `ChatStreamCoordinator` through the shared
/// `ScriptedGatewayFabricator`/`ScriptedGatewayClient`/`GatewayEventFixture`
/// doubles and a faithful delegate spy (which mimics the view model dropping
/// the streaming anchor when it reloads the transcript on reconnect).
final class StreamReconnectContractTests: APIClientTestCase {
    // MARK: - Fresh-ticket reconnect

    @MainActor
    func testDisconnectReconnectMintsFreshTicketAndFreshClient() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let delegate = ReconnectDelegateSpy()
        let issuer = TicketIssuer()
        let coordinator = makeCoordinator(
            fabricator: fabricator,
            delegate: delegate,
            handler: ticketHandler(issuer: issuer)
        )

        await coordinator.start(streamID: "session-abc")

        XCTAssertEqual(fabricator.makeCount, 1)
        XCTAssertEqual(fabricator.tickets.count, 1)
        let firstClient = try XCTUnwrap(fabricator.instances.first)
        XCTAssertEqual(firstClient.connectCount, 1)
        XCTAssertEqual(firstClient.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
        XCTAssertFalse(coordinator.isConnectionSuspended)

        // Disconnect tears down the current transport, then reconnect must open a
        // brand-new epoch: fresh single-use ticket + fresh client.
        coordinator.suspendActiveStreamConnection()
        XCTAssertEqual(firstClient.disconnectCount, 1)

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(fabricator.makeCount, 2)
        XCTAssertEqual(fabricator.tickets.count, 2)
        XCTAssertNotEqual(
            try XCTUnwrap(fabricator.tickets.first),
            try XCTUnwrap(fabricator.tickets.last),
            "Reconnect must mint a fresh single-use ticket, not reuse the consumed one"
        )
        XCTAssertEqual(fabricator.baseURLs.count, 2)
        let secondClient = try XCTUnwrap(fabricator.instances.last)
        XCTAssertNotIdentical(firstClient, secondClient)
        XCTAssertEqual(secondClient.connectCount, 1)
        XCTAssertEqual(secondClient.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
        XCTAssertFalse(coordinator.isConnectionSuspended)
    }

    // MARK: - Stale-epoch rejection

    @MainActor
    func testEventFromPreReconnectClientIsIgnoredAfterReconnect() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let delegate = ReconnectDelegateSpy()
        let coordinator = makeCoordinator(
            fabricator: fabricator,
            delegate: delegate,
            handler: ticketHandler(issuer: TicketIssuer())
        )

        await coordinator.start(streamID: "session-abc")
        let firstClient = try XCTUnwrap(fabricator.instances.first)
        firstClient.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Hello "))
        XCTAssertEqual(delegate.appendTokens, ["Hello "])

        coordinator.suspendActiveStreamConnection()
        await coordinator.reconnectIfNeeded()

        let secondClient = try XCTUnwrap(fabricator.instances.last)
        XCTAssertEqual(fabricator.makeCount, 2)
        XCTAssertEqual(secondClient.connectCount, 1)

        // A late event on the discarded epoch — delta or terminal — must be
        // dropped entirely: no token append, no premature stream finalize.
        firstClient.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "STALE"))
        firstClient.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: "STALE-COMPLETE"))
        XCTAssertEqual(delegate.appendTokens, ["Hello "])
        XCTAssertEqual(coordinator.activeStreamID, "session-abc")
        XCTAssertNil(delegate.completedRefreshValues.last)

        // The fresh epoch still routes events normally.
        secondClient.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "World"))
        XCTAssertEqual(delegate.appendTokens, ["Hello ", "World"])
    }

    // MARK: - In-flight prefix applied exactly once

    @MainActor
    func testReconnectAppliesInflightAssistantPrefixExactlyOnce() async throws {
        let fabricator = ScriptedGatewayFabricator()
        // Only the reconnect-time client (second made) resumes a live turn with
        // an in-flight assistant projection.
        fabricator.onMake = { instance, index in
            if index == 2 {
                instance.resumeResultFactory = { sessionID in
                    .withInflight(sessionID: sessionID, inflightText: "Partial answer")
                }
            }
        }
        let delegate = ReconnectDelegateSpy()
        let coordinator = makeCoordinator(
            fabricator: fabricator,
            delegate: delegate,
            handler: ticketHandler(issuer: TicketIssuer())
        )

        // First epoch (no live projection): stream some deltas.
        await coordinator.start(streamID: "session-abc")
        let firstClient = try XCTUnwrap(fabricator.instances.first)
        firstClient.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Alpha"))
        XCTAssertEqual(delegate.appendTokens, ["Alpha"])

        // Disconnect + reconnect: the transcript reload drops the streaming
        // anchor, so the resume projection attaches as the prefix.
        coordinator.suspendActiveStreamConnection()
        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(fabricator.makeCount, 2)
        let secondClient = try XCTUnwrap(fabricator.instances.last)
        XCTAssertEqual(secondClient.resumeSessionIDs, ["session-abc"])
        XCTAssertEqual(
            delegate.appendTokens,
            ["Alpha", "Partial answer"],
            "The resumed turn's in-flight projection must attach as the streaming prefix"
        )

        // New deltas append after the prefix — the prefix is NOT re-sent.
        secondClient.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: " continues"))
        XCTAssertEqual(delegate.appendTokens, ["Alpha", "Partial answer", " continues"])

        // A `sessionInfo` echo that carries the same in-flight projection must
        // NOT re-apply the prefix (the once-guarantee is keyed to the visible
        // streaming message, not to every snapshot echo).
        secondClient.deliver(GatewayEventFixture.info(
            sessionID: "session-abc",
            running: true,
            inflightText: "Partial answer"
        ))
        XCTAssertEqual(delegate.appendTokens, ["Alpha", "Partial answer", " continues"])
    }

    // MARK: - Interrupt / cancel

    @MainActor
    func testCancelActiveStreamInterruptsCurrentEpochAndFinalizes() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let delegate = ReconnectDelegateSpy()
        let liveActivity = ReconnectSpyLiveActivityManager()
        let coordinator = makeCoordinator(
            fabricator: fabricator,
            delegate: delegate,
            liveActivityManager: liveActivity,
            handler: ticketHandler(issuer: TicketIssuer())
        )

        await coordinator.start(streamID: "session-abc")
        let client = try XCTUnwrap(fabricator.instances.first)
        XCTAssertEqual(client.connectCount, 1)

        _ = try await coordinator.cancelActiveStream()

        XCTAssertEqual(client.interruptedSessionIDs, ["session-abc"])
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(liveActivity.ends.last?.status, .cancelled)
        XCTAssertEqual(client.disconnectCount, 1)
    }

    // MARK: - Helpers

    private func ticketHandler(
        issuer: TicketIssuer
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let ticket = issuer.next()
            return apiTestJSONResponse(
                "{\"ticket\": \"\(ticket)\"}",
                for: request
            )
        }
    }

    /// A reference-type ticket sequence so the URLProtocol handler can issue a
    /// distinct single-use ticket per mint without mutating an actor-isolated
    /// variable from a nonisolated callback.
    private final class TicketIssuer {
        private var serial = 0

        func next() -> String {
            serial += 1
            return "gateway-ticket-\(serial)"
        }
    }

    @MainActor
    private func makeCoordinator(
        fabricator: ScriptedGatewayFabricator,
        delegate: ReconnectDelegateSpy,
        liveActivityManager: ReconnectSpyLiveActivityManager? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> ChatStreamCoordinator {
        let resolvedLiveActivityManager = liveActivityManager ?? ReconnectSpyLiveActivityManager()
        let coordinator = ChatStreamCoordinator(
            client: makeClient(handler: handler),
            liveActivityManager: resolvedLiveActivityManager,
            showsLiveActivityResponseExcerpts: false,
            gatewayFabricator: fabricator.fabricator
        )
        coordinator.attach(delegate: delegate)
        return coordinator
    }
}

@MainActor
private final class ReconnectDelegateSpy: ChatStreamCoordinatorDelegate {
    var streamCoordinatorSessionID: String? = "session-abc"
    var streamCoordinatorDisplayTitle = "Planning"
    var streamCoordinatorHasRunningLiveToolCall = false
    var streamCoordinatorHasPendingPrompt = false
    var latestServerLoadHadAssistantResponseAfterLatestUser = false
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool {
        latestServerLoadHadAssistantResponseAfterLatestUser
    }
    var streamCoordinatorStreamingAssistantMessageID: String?

    /// Recorded token appends (across all connection epochs).
    private(set) var appendTokens: [String] = []
    private(set) var loadMessagesCount = 0
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringClearPromptValues: [Bool] = []
    private(set) var saveSnapshotCount = 0
    private(set) var removedSnapshotStreamIDs: [String?] = []
    private(set) var finishCount = 0
    private(set) var errorMessages: [String] = []
    private(set) var recoveryErrorDescriptions: [String] = []
    private(set) var startConnectionReplayValues: [Bool] = []
    private(set) var resetRecoveryCount = 0
    private(set) var completedRefreshValues: [Bool] = []
    var onLoadMessages: (() async -> Void)?

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        loadMessagesCount += 1
        // Mimic the view model's reconnect load: the roaming streaming anchor is
        // dropped so a live resume projection can attach as the prefix.
        streamCoordinatorStreamingAssistantMessageID = nil
        await onLoadMessages?()
    }

    func streamCoordinatorLatestAssistantMessageID() -> String? {
        nil
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
        nil
    }

    func streamCoordinatorRemoveSnapshot(streamID: String?) {
        removedSnapshotStreamIDs.append(streamID)
    }

    func streamCoordinatorFlushPinnedLocalNoticesToTranscript() {
        // No-op for this spy.
    }

    func streamCoordinatorDrainQueuedSlashMessageIfIdle() {
        // No-op for this spy.
    }

    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded() {
        // No-op for this spy.
    }

    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool) {
        completedRefreshValues.append(needsTranscriptRefresh)
    }

    func streamCoordinatorDidFinishStream() {
        finishCount += 1
    }

    func streamCoordinatorDidReceiveErrorMessage(_ message: String) {
        errorMessages.append(message)
    }

    func streamCoordinatorDidReceiveRecoveryError(_ error: Error) {
        recoveryErrorDescriptions.append(error.localizedDescription)
    }

    func streamCoordinatorDidStartConnection(isReplay: Bool) {
        startConnectionReplayValues.append(isReplay)
    }

    func streamCoordinatorDidResetRecoveryState() {
        resetRecoveryCount += 1
    }

    func streamCoordinatorAppendToken(_ text: String) -> Bool {
        appendTokens.append(text)
        // Mimic `ensureStreamingAssistantMessage`: the first appended token in a
        // turn creates the visible streaming assistant message.
        if streamCoordinatorStreamingAssistantMessageID == nil {
            streamCoordinatorStreamingAssistantMessageID = "stream-1"
        }
        return true
    }

    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        payload.text?.isEmpty == false
    }

    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        !text.isEmpty
    }

    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        true
    }

    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        true
    }

    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        payload.title?.isEmpty == false
    }

    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        false
    }

    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse) {
        // No-op for this spy.
    }

    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse) {
        // No-op for this spy.
    }

    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
private final class ReconnectSpyLiveActivityManager: AgentLiveActivityManaging {
    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [(sessionID: String, sessionTitle: String, streamID: String?)] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var markStaleCount = 0
    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        starts.append((sessionID, sessionTitle, streamID))
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
