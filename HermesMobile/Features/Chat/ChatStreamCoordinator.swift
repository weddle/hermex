import Foundation
import Observation
import OSLog
import SwiftData

private let chatStreamCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatStreamCoordinator"
)

struct ChatStreamCoordinatorTiming: Equatable {
    let checkingInterval: TimeInterval
    let reconnectInterval: TimeInterval
    let runningToolReconnectInterval: TimeInterval
    let statusPollCooldown: TimeInterval
    // Transport quieter than this is treated as provably alive; must sit above
    // the server's ~5s heartbeat cadence and below reconnectInterval (#227).
    let transportFreshInterval: TimeInterval

    static let standard = ChatStreamCoordinatorTiming(
        checkingInterval: 5,
        reconnectInterval: 18,
        runningToolReconnectInterval: 25,
        statusPollCooldown: 4,
        transportFreshInterval: 12
    )
}

struct ChatStreamLoadPreparation: Equatable {
    let activeStreamIDBeforeLoad: String?
    let shouldPrepareSuspendedStreamResume: Bool
}

@MainActor
protocol ChatStreamCoordinatorDelegate: AnyObject {
    var streamCoordinatorSessionID: String? { get }
    var streamCoordinatorDisplayTitle: String { get }
    var streamCoordinatorHasRunningLiveToolCall: Bool { get }
    var streamCoordinatorHasPendingPrompt: Bool { get }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool { get }
    var streamCoordinatorStreamingAssistantMessageID: String? { get set }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async
    func streamCoordinatorLatestAssistantMessageID() -> String?
    func streamCoordinatorStartAuxiliaryMonitoring()
    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool)
    func streamCoordinatorSaveSnapshotIfNeeded()
    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String?
    func streamCoordinatorRemoveSnapshot(streamID: String?)
    func streamCoordinatorFlushPinnedLocalNoticesToTranscript()
    func streamCoordinatorDrainQueuedSlashMessageIfIdle()
    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool)
    func streamCoordinatorDidFinishStream()
    func streamCoordinatorDidReceiveErrorMessage(_ message: String)
    func streamCoordinatorDidReceiveRecoveryError(_ error: Error)
    func streamCoordinatorDidStartConnection(isReplay: Bool)
    func streamCoordinatorDidResetRecoveryState()

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool
    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse)
    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse)
    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool
}

/// Coordinates a single chat life cycle against the Hermes Agent gateway.
///
/// The coordinator owns one persistent `HermesGatewayClient` per connection
/// epoch: it mints a fresh single-use WebSocket ticket, connects, resumes the
/// active session, submits prompts, and maps gateway stream events onto the
/// same transport-agnostic `ChatStreamCoordinatorDelegate` the SSE flow used.
/// On disconnect or foreground recovery it mints a NEW ticket and client,
/// discarding callbacks from earlier epochs.
///
/// The SSE concept of a server-issued `streamID` has no gateway equivalent: the
/// session IS the stream. `activeStreamID` therefore holds the gateway session
/// id of the live turn (it is what Hermex's `SessionSummary.activeStreamId`
/// carried). Replay/`after_seq` is replaced by `session.resume`, which returns
/// the durable transcript (including any in-flight projection).
/// Factory for the persistent gateway client a chat connection uses. The real
/// app hands back a `HermesGatewayClient`; tests substitute a scripted gateway
/// so coordinator lifecycle (connect, resume, prompt.submit, event routing,
/// epoch rejection) is exercised without a live WebSocket.
@MainActor
protocol GatewayClientProviding: AnyObject {
    var isConnected: Bool { get }
    var onEvent: ((GatewayEvent) -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }

    func connect() async throws
    func disconnect()
    func resumeSession(_ sessionID: String) async throws -> GatewayResumeResult
    func submitPrompt(sessionID: String, text: String, rewindOrdinal: Int?) async throws
    func interrupt(sessionID: String) async throws
}

extension HermesGatewayClient: GatewayClientProviding {}

@MainActor
@Observable
final class ChatStreamCoordinator {
    @ObservationIgnored private weak var delegate: (any ChatStreamCoordinatorDelegate)?
    private let client: APIClient
    private let liveActivityManager: any AgentLiveActivityManaging
    private let timing: ChatStreamCoordinatorTiming
    private var showsLiveActivityResponseExcerpts: Bool

    // Gateway connection state.
    @ObservationIgnored private var gatewayClient: (any GatewayClientProviding)?
    private var connectionEpoch = 0
    private var reconnectTask: Task<Void, Never>?
    /// Builds a gateway client for a fresh connection epoch. Production uses
    /// `HermesGatewayClient`; tests inject a scripted gateway. The fabricator
    /// lives here (not in `APIClient`) so reconnects mint a fresh client and
    /// so unit tests can observe the single-use-ticket → connect lifecycle.
    private let gatewayFabricator: @MainActor (URL, String, String?) -> any GatewayClientProviding

    // Observable state (kept compatible with ChatViewModel).
    private(set) var activeStreamID: String?
    private(set) var recoveryState: ActiveStreamRecoveryState = .idle
    private(set) var isConnectionSuspended = false
    private(set) var hasCompletedCurrentResponse = false
    private(set) var lastEventID: String?
    private(set) var lastProgressDate: Date?
    private(set) var lastTransportActivityDate: Date?
    private(set) var liveTokensPerSecond: Double?
    private var lastRecoveryStatusCheckDate: Date?
    private(set) var isReplayConnection = false
    /// In-flight assistant text from the resume projection, applied once on a
    /// resumed live turn so new deltas append to it rather than duplicate it.
    private var inflightAssistantText: String?
    private var runGeneration = 0

    init(
        client: APIClient,
        liveActivityManager: any AgentLiveActivityManaging,
        showsLiveActivityResponseExcerpts: Bool,
        timing: ChatStreamCoordinatorTiming = .standard,
        gatewayFabricator: @escaping @MainActor (URL, String, String?) -> any GatewayClientProviding = { baseURL, ticket, profile in
            HermesGatewayClient(baseURL: baseURL, ticket: ticket, profile: profile, customHeaders: [])
        }
    ) {
        self.client = client
        self.liveActivityManager = liveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.timing = timing
        self.gatewayFabricator = gatewayFabricator
    }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        if !shows, activeStreamID != nil {
            liveActivityManager.update(.clearResponseExcerpt)
        }
    }

    func prepareForNewResponse() {
        hasCompletedCurrentResponse = false
        isConnectionSuspended = false
        liveTokensPerSecond = nil
        inflightAssistantText = nil
    }

    // MARK: - Connection lifecycle

    /// Begins (or resumes) a gateway connection for the given session.
    ///
    /// `sessionID` is the gateway session id of the turn to stream. A fresh
    /// ticket is minted and a new epoch begins; callbacks from any earlier epoch
    /// are discarded when a reconnect supersedes them.
    func start(streamID sessionID: String) async {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil
        runGeneration &+= 1
        inflightAssistantText = nil
        connectionEpoch &+= 1
        let epoch = connectionEpoch

        activeStreamID = sessionID
        isConnectionSuspended = false
        lastEventID = nil

        markConnectionStarted(isReplay: false, recoveryState: .idle)
        startLiveActivity(sessionID: sessionID)

        delegate?.streamCoordinatorStartAuxiliaryMonitoring()

        do {
            let ticket = try await client.mintWebSocketTicket(profile: profileName)
            // Discard a stale epoch's connection if a newer one superseded us.
            guard epoch == connectionEpoch else { return }

            let gateway = gatewayFabricator(client.baseURL, ticket, profileName)
            gateway.onEvent = { [weak self] event in
                self?.handleGatewayEvent(event, epoch: epoch)
            }
            gateway.onDisconnected = { [weak self] in
                Task { @MainActor in
                    self?.handleGatewayDisconnect(epoch: epoch)
                }
            }
            gatewayClient = gateway
            try await gateway.connect()

            // Resume the session so the gateway streams the live turn's events.
            let resume = try await gateway.resumeSession(sessionID)
            guard epoch == connectionEpoch else { return }

            applyResumePayload(resume)
        } catch {
            guard epoch == connectionEpoch else { return }
            delegate?.streamCoordinatorDidReceiveRecoveryError(error)
            handleGatewayError(epoch: epoch)
        }
    }

    /// Begins a fresh user turn over the gateway: connects (minting a new
    /// ticket and epoch), resumes the session, submits the prompt via
    /// `prompt.submit`, and streams events into the delegate seam.
    ///
    /// `rewindOrdinal`, when set, is the 0-based user-turn ordinal for a
    /// rewind/edit/regenerate: the gateway drops that user turn and everything
    /// after it before running `prompt` (see `HermesGatewayClient.submitPrompt`).
    ///
    /// Throws on any connect/resume/submit failure so the caller can roll back
    /// its optimistic user message; the coordinator tears down cleanly either
    /// way, so a later reconnect resumes the session without the failed prompt.
    func beginTurn(
        sessionID: String,
        prompt: String,
        rewindOrdinal: Int? = nil
    ) async throws {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil
        runGeneration &+= 1
        inflightAssistantText = nil
        connectionEpoch &+= 1
        let epoch = connectionEpoch

        activeStreamID = sessionID
        isConnectionSuspended = false
        lastEventID = nil

        markConnectionStarted(isReplay: false, recoveryState: .idle)
        startLiveActivity(sessionID: sessionID)
        delegate?.streamCoordinatorStartAuxiliaryMonitoring()

        do {
            let gateway = try await makeConnectedGateway()
            let resume = try await gateway.resumeSession(sessionID)
            guard epoch == connectionEpoch else { throw CancellationError() }
            applyResumePayload(resume)
            try await gateway.submitPrompt(sessionID: sessionID, text: prompt, rewindOrdinal: rewindOrdinal)
            // If a stray idle `sessionInfo` event finalized the snapshot between
            // resume and submit, re-open the turn so the incoming stream's
            // deltas keep routing to the delegate.
            if activeStreamID == nil {
                activeStreamID = sessionID
                hasCompletedCurrentResponse = false
                isConnectionSuspended = false
                liveTokensPerSecond = nil
                delegate?.streamCoordinatorStartAuxiliaryMonitoring()
                delegate?.streamCoordinatorDidStartConnection(isReplay: false)
            }
        } catch {
            guard epoch == connectionEpoch else { throw CancellationError() }
            if hasCompletedCurrentResponse {
                finishStream()
            } else {
                delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
                teardownGateway()
                inflightAssistantText = nil
                activeStreamID = nil
                lastEventID = nil
                liveTokensPerSecond = nil
                delegate?.streamCoordinatorStreamingAssistantMessageID = nil
                resetRecoveryState()
            }
            throw error
        }
    }

    /// Applies the resume snapshot's in-flight projection to the visible
    /// streaming message once, so new deltas append to it rather than
    /// duplicate it.
    private func applyResumePayload(_ resume: GatewayResumeResult) {
        self.inflightAssistantText = resume.snapshot.inflightAssistantText
        let inflight = resume.snapshot.inflightAssistantText
        if resume.snapshot.hasLiveProjection, !inflight.isEmpty,
           delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
            // Attach the in-flight prefix to the visible streaming message once.
            _ = delegate?.streamCoordinatorAppendToken(inflight)
        }
    }

    /// Cancels the active turn with `session.interrupt`.
    func cancelActiveStream() async throws -> ChatCancelResponse? {
        guard let activeStreamID else { return nil }

        do {
            try await gatewayCommand { gateway in
                try await gateway.interrupt(sessionID: activeStreamID)
            }
        } catch {
            // Still finalize locally even if the interrupt RPC failed.
        }

        liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        finishStream()
        return nil
    }

    func suspendActiveStreamConnection() {
        guard activeStreamID != nil, !hasCompletedCurrentResponse, !isConnectionSuspended else { return }

        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        teardownGateway()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
    }

    // MARK: - Session load reconciliation

    func prepareForSessionLoad() -> ChatStreamLoadPreparation {
        liveTokensPerSecond = nil
        let activeStreamIDBeforeLoad = activeStreamID
        if activeStreamIDBeforeLoad != nil, !hasCompletedCurrentResponse {
            delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        }

        return ChatStreamLoadPreparation(
            activeStreamIDBeforeLoad: activeStreamIDBeforeLoad,
            shouldPrepareSuspendedStreamResume: activeStreamID == nil || isConnectionSuspended
        )
    }

    func reconcileSessionLoad(
        loadedActiveStreamID rawLoadedActiveStreamID: String?,
        preparation: ChatStreamLoadPreparation,
        usedCacheFallback: Bool
    ) {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil

        if usedCacheFallback {
            activeStreamID = nil
            isConnectionSuspended = false
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            resetRecoveryState()
            return
        }

        let loadedActiveStreamID = rawLoadedActiveStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparation.shouldPrepareSuspendedStreamResume {
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            if let streamID = loadedActiveStreamID, !streamID.isEmpty {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                isConnectionSuspended = true
                restoreSnapshotIfAvailable(streamID: streamID)
            } else {
                activeStreamID = nil
                isConnectionSuspended = false
                resetRecoveryState()
            }
        } else {
            let streamID = loadedActiveStreamID?.isEmpty == false
                ? loadedActiveStreamID
                : preparation.activeStreamIDBeforeLoad
            if let streamID {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                restoreSnapshotIfAvailable(streamID: streamID)
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
            }
            isConnectionSuspended = false
        }
    }

    // MARK: - Reconnect

    func reconnectIfNeeded(modelContext: ModelContext? = nil) async {
        guard let activeStreamID, isConnectionSuspended else { return }
        let generation = runGeneration

        // Reload the durable transcript first, then resume the gateway so any
        // in-flight assistant text is picked up by the resume projection.
        await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
        guard canFinalizeRunAfterLoad(streamID: activeStreamID, capturedGeneration: generation),
              activeStreamID != nil else { return }

        isConnectionSuspended = false
        await start(streamID: activeStreamID)
        // If the server already finished the run, resume returns no live turn and
        // the coordinator settles into an idle, connected state.
    }

    func refreshTranscriptIfCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            try await gatewayCommand { gateway in
                _ = try await gateway.resumeSession(expectedStreamID)
            }
            // The gateway is the live owner of the turn; if it resumed and there
            // is no active projection, the run may already be complete.
            guard delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true else {
                return
            }
            await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
            guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation) else { return }
            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: expectedStreamID)
        } catch {
            chatStreamCoordinatorLogger.warning(
                "Gateway status refresh failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    func recoverStaleStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        guard let activeStreamID,
              !isConnectionSuspended,
              !hasCompletedCurrentResponse
        else {
            recoveryState = .idle
            return
        }

        guard delegate?.streamCoordinatorHasPendingPrompt != true else {
            recoveryState = .idle
            return
        }

        let reconnectInterval = delegate?.streamCoordinatorHasRunningLiveToolCall == true
            ? timing.runningToolReconnectInterval
            : timing.reconnectInterval
        guard let lastProgressDate else {
            guard let lastTransportActivityDate,
                  now.timeIntervalSince(lastTransportActivityDate) >= reconnectInterval
            else {
                recoveryState = .idle
                return
            }

            recoveryState = .checking
            lastRecoveryStatusCheckDate = now
            await recoverStaleStream(
                streamID: activeStreamID,
                modelContext: modelContext
            )
            return
        }

        let elapsed = now.timeIntervalSince(lastProgressDate)
        guard elapsed >= timing.checkingInterval else {
            recoveryState = .idle
            return
        }

        let transportElapsed = now.timeIntervalSince(lastTransportActivityDate ?? lastProgressDate)
        guard transportElapsed >= timing.transportFreshInterval else {
            recoveryState = .idle
            return
        }

        recoveryState = .checking
        lastRecoveryStatusCheckDate = now
        await recoverStaleStream(
            streamID: activeStreamID,
            modelContext: modelContext
        )
    }

    func markProgress(now: Date = Date()) {
        lastProgressDate = now
        lastTransportActivityDate = now
        lastRecoveryStatusCheckDate = nil
        recoveryState = .idle
    }

    func clearReplayConnection() {
        isReplayConnection = false
    }

    nonisolated static func runJournalReplayAfterSeq(from eventID: String?) -> Int? {
        // The gateway has no journal replay sequence; resume always returns the
        // durable transcript. Retained so existing callers compile unchanged.
        nil
    }

    // MARK: - Gateway event handling

    private func handleGatewayEvent(_ event: GatewayEvent, epoch: Int) {
        guard epoch == connectionEpoch, let activeStreamID else { return }

        lastTransportActivityDate = Date()

        switch event {
        case .messageDelta(let sessionID, let text):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            if showsLiveActivityResponseExcerpts {
                liveActivityManager.update(.token(text))
            }
            if delegate?.streamCoordinatorAppendToken(text) == true {
                markProgress()
            }
        case .reasoningDelta(let sessionID, let text):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            liveActivityManager.update(.reasoning(text))
            if delegate?.streamCoordinatorAppendReasoning(text) == true {
                markProgress()
            }
        case .messageComplete(let sessionID, _, let content, _):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            if let content, !content.isEmpty {
                _ = delegate?.streamCoordinatorAppendToken(content)
            }
            completeCurrentResponse(needsTranscriptRefresh: true)
        case .messageError(let sessionID, let message):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        case .messageInterrupted(let sessionID):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
            finishStream()
        case .sessionBusy(let sessionID, let busy):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            if !busy, !hasCompletedCurrentResponse {
                // Gateway reports the busy flag cleared; a resume may still own
                // the final completion, so let the transcript reload decide.
            }
        case .sessionInfo(let sessionID, let snapshot):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            applySnapshot(snapshot)
        case .sessionTitle(let sessionID, let title):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            _ = delegate?.streamCoordinatorUpdateTitle(TitleStreamEvent(sessionId: sessionID, title: title))
            markProgress()
        case .toolStarted(let sessionID, let name, let input):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            liveActivityManager.update(.toolStarted(name: name))
            let args = input.flatMap { gatewayObjectToJSONValue($0) }
            if delegate?.streamCoordinatorAppendToolCall(ToolStreamEvent(eventType: nil, name: name, preview: nil, args: args, duration: nil, isError: nil)) == true {
                markProgress()
            }
        case .toolCompleted(let sessionID, let name, let output):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            liveActivityManager.update(.toolCompleted)
            let outputText = output?.descriptiveStringValue
            if delegate?.streamCoordinatorCompleteToolCall(ToolStreamEvent(eventType: nil, name: name, preview: outputText, args: nil, duration: nil, isError: nil)) == true {
                markProgress()
            }
        case .clarification(let sessionID, let requestID, let question, let choices):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            liveActivityManager.update(.waitingForClarification)
            let update = ClarificationPendingResponse(
                pending: PendingClarification(
                    clarifyId: requestID,
                    question: question,
                    choicesOffered: choices.map { $0.label },
                    sessionId: sessionID,
                    kind: nil,
                    requestedAt: nil,
                    timeoutSeconds: nil,
                    expiresAt: nil
                ),
                pendingCount: 1
            )
            delegate?.streamCoordinatorApplyClarificationUpdate(update)
            markProgress()
        case .approval(let sessionID, let command, let description, let choices):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            liveActivityManager.update(.waitingForApproval)
            let update = ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: nil,
                    command: command,
                    description: description,
                    patternKey: nil,
                    patternKeys: choices
                ),
                pendingCount: 1
            )
            delegate?.streamCoordinatorApplyApprovalUpdate(update)
            markProgress()
        case .context(let sessionID, _, _, _):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
            // Context percentage is reflected via done/session info; no delegate
            // member to push it to live.
        case .model(let sessionID, _, _):
            guard sessionID == activeStreamID || sessionID.isEmpty else { return }
        case .ignored:
            break
        }
    }

    private func handleGatewayDisconnect(epoch: Int) {
        guard epoch == connectionEpoch else { return }
        gatewayClient = nil
        guard activeStreamID != nil, !hasCompletedCurrentResponse else {
            finishStream()
            return
        }
        guard !isConnectionSuspended else { return }

        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.timing.checkingInterval ?? 5) * 1_000_000_000))
            guard let self, self.isConnectionSuspended else { return }
            await self.reconnectIfNeeded()
        }
    }

    /// Local treatment for a connect/resume error: treat it like a transport
    /// failure (suspend + schedule reconnect) while the run is still open, or
    /// finalize if there is nothing to reconnect.
    private func handleGatewayError(epoch: Int) {
        guard epoch == connectionEpoch else { return }
        gatewayClient = nil
        if hasCompletedCurrentResponse {
            finishStream()
            return
        }
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.timing.checkingInterval ?? 5) * 1_000_000_000))
            guard let self, self.isConnectionSuspended else { return }
            await self.reconnectIfNeeded()
        }
    }

    private func recoverStaleStream(
        streamID expectedStreamID: String,
        modelContext: ModelContext?
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            // Resume to check liveness and re-attach.
            try await gatewayCommand { gateway in
                _ = try await gateway.resumeSession(expectedStreamID)
            }
            guard recoveryState == .checking,
                  activeStreamID == expectedStreamID,
                  !isConnectionSuspended else { return }

            // The gateway own a live turn; resume succeeded, so we are connected.
            isConnectionSuspended = false
            markConnectionStarted(isReplay: false, recoveryState: .idle)
        } catch {
            chatStreamCoordinatorLogger.warning(
                "Stale stream recovery failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
            guard recoveryState == .checking, activeStreamID == expectedStreamID else { return }
            await start(streamID: expectedStreamID)
        }
    }

    private func applySnapshot(_ snapshot: GatewayRuntimeSnapshot) {
        let inflight = snapshot.inflightAssistantText
        if !inflight.isEmpty {
            inflightAssistantText = inflight
        }
        if snapshot.running != true, !hasCompletedCurrentResponse {
            // Gateway reports the turn is no longer running.
            if snapshot.hasLiveProjection {
                // Keep waiting for the final message.complete.
            } else {
                completeCurrentResponse(needsTranscriptRefresh: true)
            }
        }
    }

    private func completeCurrentResponse(needsTranscriptRefresh: Bool) {
        runGeneration &+= 1
        liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: activeStreamID)
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        inflightAssistantText = nil
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = true
        delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: needsTranscriptRefresh)
        resetRecoveryState()
    }

    private func completeResponseFromRefreshedTranscriptAndFinishStream(streamID completedStreamID: String?) {
        completeCurrentResponse(needsTranscriptRefresh: false)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: completedStreamID)
        finishStream()
    }

    private func canFinalizeRunAfterLoad(streamID: String, capturedGeneration: Int) -> Bool {
        guard runGeneration == capturedGeneration else { return false }
        return activeStreamID == nil || activeStreamID == streamID
    }

    private func finishStream() {
        runGeneration &+= 1
        let completedNormally = hasCompletedCurrentResponse
        let finishedStreamID = activeStreamID
        teardownGateway()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorRemoveSnapshot(streamID: finishedStreamID)
        inflightAssistantText = nil
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = false
        delegate?.streamCoordinatorDidFinishStream()
        isConnectionSuspended = false
        resetRecoveryState()
        delegate?.streamCoordinatorDrainQueuedSlashMessageIfIdle()
        if completedNormally {
            delegate?.streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
        }
    }

    private func markConnectionStarted(
        isReplay: Bool,
        recoveryState: ActiveStreamRecoveryState
    ) {
        let startedAt = Date()
        lastProgressDate = isReplay ? startedAt : nil
        lastTransportActivityDate = startedAt
        lastRecoveryStatusCheckDate = nil
        self.recoveryState = recoveryState
        isReplayConnection = isReplay
        delegate?.streamCoordinatorDidStartConnection(isReplay: isReplay)
    }

    private func resetRecoveryState() {
        recoveryState = .idle
        lastProgressDate = nil
        lastTransportActivityDate = nil
        lastRecoveryStatusCheckDate = nil
        isReplayConnection = false
        delegate?.streamCoordinatorDidResetRecoveryState()
    }

    private func startLiveActivity(sessionID: String) {
        guard let delegate = delegate else { return }

        liveActivityManager.start(
            sessionID: delegate.streamCoordinatorSessionID ?? "",
            sessionTitle: delegate.streamCoordinatorDisplayTitle.isEmpty
                ? String(localized: "Untitled Session")
                : delegate.streamCoordinatorDisplayTitle,
            streamID: sessionID
        )
    }

    private func restoreSnapshotIfAvailable(streamID: String) {
        lastEventID = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID) ?? lastEventID
    }

    private func teardownGateway() {
        gatewayClient?.disconnect()
        gatewayClient = nil
    }

    private var profileName: String? {
        // Resolve from the delegate's session if it exposes a profile; gateway
        // scoping is otherwise left to the APIClient's configured profile.
        nil
    }

    // MARK: - Gateway command helper

    private func gatewayCommand(_ body: @escaping @MainActor (any GatewayClientProviding) async throws -> Void) async throws {
        if let gatewayClient, gatewayClient.isConnected {
            try await body(gatewayClient)
            return
        }
        // Not connected: mint a fresh ticket and reconnect before issuing.
        let gateway = try await makeConnectedGateway()
        gatewayClient = gateway
        try await body(gateway)
    }

    private func makeConnectedGateway() async throws -> any GatewayClientProviding {
        let ticket = try await client.mintWebSocketTicket(profile: profileName)
        let gateway = gatewayFabricator(client.baseURL, ticket, profileName)
        gateway.onEvent = { [weak self] event in
            self?.handleGatewayEvent(event, epoch: self?.connectionEpoch ?? 0)
        }
        gateway.onDisconnected = { [weak self] in
            Task { @MainActor in
                self?.handleGatewayDisconnect(epoch: self?.connectionEpoch ?? 0)
            }
        }
        gatewayClient = gateway
        try await gateway.connect()
        return gateway
    }

    // MARK: - Conversions

    private func gatewayObjectToJSONValue(_ value: GatewayValue) -> [String: JSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object.mapValues { Self.gatewayValueToJSONValue($0) }
    }

    /// Approximate tool-args conversion from a GatewayValue's native `any`.
    private static func gatewayValueToJSONValue(_ value: GatewayValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map { gatewayValueToJSONValue($0) })
        case .object(let obj): return .object(obj.mapValues { gatewayValueToJSONValue($0) })
        }
    }
}
