import XCTest
@testable import HermesMobile

/// Live Activity tests for the chat run surface.
///
/// The legacy live-activity streaming double plumbing has no gateway
/// equivalent: the session IS the stream, and live events stream in as
/// `GatewayEvent` notifications delivered through the shared
/// `ScriptedGatewayFabricator`/`ScriptedGatewayClient`/`GatewayEventFixture`
/// doubles (`.messageDelta`, `.reasoningDelta`, `.toolStarted`, `.toolCompleted`,
/// `.sessionTitle`, `.sessionInfo`, `.messageComplete`). Pure reducer/sanitizer/
/// reconciler tests are unchanged.
@MainActor
final class LiveActivityTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSanitizesLiveActivityText() {
        let title = AgentRunActivitySanitizer.sessionTitle("  A very long Hermes session title with\nmultiple lines and extra words  ")
        let activity = AgentRunActivitySanitizer.activityLine("Reading /Users/example/project/Secrets.swift\nwith details")
        let excerpt = AgentRunActivitySanitizer.responseExcerpt(String(repeating: "A", count: 180))

        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, AgentRunActivitySanitizer.maximumSessionTitleCharacters)
        XCTAssertFalse(activity.contains("\n"))
        XCTAssertLessThanOrEqual(activity.count, AgentRunActivitySanitizer.maximumActivityCharacters)
        XCTAssertLessThanOrEqual(excerpt.count, AgentRunActivitySanitizer.maximumExcerptCharacters)
    }

    func testMapsToolNamesToSafeStatuses() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityStateReducer.initialState(
            sessionID: "session-abc",
            sessionTitle: "Build fixes",
            startedAt: startedAt
        )

        let command = AgentRunActivityStateReducer.toolStarted(name: "shell_command", state: state)
        XCTAssertEqual(command.status, .runningCommand)
        XCTAssertEqual(command.currentActivity, "Running command")

        let search = AgentRunActivityStateReducer.toolStarted(name: "ripgrep_search", state: state)
        XCTAssertEqual(search.status, .searchingFiles)
        XCTAssertEqual(search.currentActivity, "Searching files")

        let generic = AgentRunActivityStateReducer.toolStarted(name: "apply_patch", state: state)
        XCTAssertEqual(generic.status, .usingTool)
        XCTAssertEqual(generic.currentActivity, "Using apply patch")
    }

    func testElapsedTimeFormatterUsesStableClockLabels() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            "00:00"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 106)
            ),
            "00:06"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 190)
            ),
            "01:30"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 3_761)
            ),
            "1:01:01"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 99)
            ),
            "00:00"
        )
    }

    func testLiveActivityReusePolicyRequiresMatchingSessionAndStream() {
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: " stream-1 ",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: nil,
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "other-session",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
    }

    func testActiveLiveActivityStatesCarryRenderableText() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 106)
        let initial = AgentRunActivityStateReducer.initialState(
            sessionID: "session-abc",
            sessionTitle: "Active render",
            startedAt: startedAt
        )
        let states = [
            initial,
            AgentRunActivityStateReducer.reasoning("Thinking through the plan", state: initial, now: later),
            AgentRunActivityStateReducer.toolStarted(name: "ripgrep_search", state: initial, now: later),
            AgentRunActivityStateReducer.toolCompleted(state: initial, now: later),
            AgentRunActivityStateReducer.waitingForApproval(state: initial, now: later),
            AgentRunActivityStateReducer.waitingForClarification(state: initial, now: later),
            AgentRunActivityStateReducer.appendingToken("Hello", to: initial, now: later),
            AgentRunActivityStateReducer.settingInterimAssistant("Drafting the answer", on: initial, now: later)
        ]

        for state in states {
            XCTAssertFalse(state.isFinal)
            XCTAssertFalse(state.sessionTitle.isEmpty)
            XCTAssertFalse(state.currentActivity.isEmpty)
            XCTAssertGreaterThanOrEqual(state.updatedAt, state.startedAt)
            XCTAssertFalse(
                AgentRunElapsedTimeFormatter.label(
                    startedAt: state.startedAt,
                    updatedAt: state.updatedAt
                ).isEmpty
            )
        }
    }

    func testUpdatingSessionTitlePreservesLiveActivityState() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Untitled Session",
            status: .searchingFiles,
            currentActivity: "Searching files",
            responseExcerpt: "Looking through the repo.",
            startedAt: startedAt,
            updatedAt: startedAt,
            isStale: true
        )

        let updated = AgentRunActivityStateReducer.updatingSessionTitle(
            "Generated repo audit title",
            state: state,
            now: Date(timeIntervalSince1970: 130)
        )

        XCTAssertEqual(updated.sessionTitle, "Generated repo audit title")
        XCTAssertEqual(updated.status, .searchingFiles)
        XCTAssertEqual(updated.currentActivity, "Searching files")
        XCTAssertEqual(updated.responseExcerpt, "Looking through the repo.")
        XCTAssertEqual(updated.startedAt, startedAt)
        XCTAssertEqual(updated.updatedAt, Date(timeIntervalSince1970: 130))
        XCTAssertTrue(updated.isStale)
    }

    func testBuildsAndParsesSessionDeepLink() throws {
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: "session-abc"))
        let scheme = HermesDeepLink.scheme

        XCTAssertEqual(url.scheme, scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(HermesDeepLink.sessionID(from: url), "session-abc")
        XCTAssertEqual(HermesDeepLink.sessionID(from: URL(string: "\(scheme)://session/session-xyz")!), "session-xyz")
        XCTAssertNil(HermesDeepLink.sessionID(from: HermesShareDraft.openURL))
    }

    func testSessionDeepLinkURLPercentEncodesSessionID() throws {
        let sessionID = "session & /?=✓"
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: sessionID))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "id", value: sessionID)])
        XCTAssertFalse(url.absoluteString.contains(sessionID))
    }

    @MainActor
    func testChatViewModelLiveActivityLifecycleUsesInjectedManager() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Run the tests")
        XCTAssertTrue(didStart)
        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "session-abc")
        ])
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "I should inspect failures."))
        gateway.deliver(GatewayEventFixture.toolStarted(sessionID: "session-abc", name: "shell_command"))
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Done."))
        gateway.deliver(GatewayEventFixture.toolCompleted(sessionID: "session-abc", name: "shell_command"))
        gateway.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: nil))

        XCTAssertEqual(manager.updates, [
            .reasoning("I should inspect failures."),
            .toolStarted(name: "shell_command"),
            .toolCompleted
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
    }

    @MainActor
    func testChatViewModelSuppressesLiveActivityResponseExcerptsByDefault() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Keep response text private")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Private token."))
        viewModel.flushPendingStreamingContent()

        XCTAssertTrue(manager.updates.isEmpty)
        XCTAssertTrue(viewModel.messages.contains { $0.content?.contains("Private token.") == true })
    }

    @MainActor
    func testChatViewModelCanOptIntoLiveActivityResponseExcerpts() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager,
            showsLiveActivityResponseExcerpts: true
        )

        let didStart = await viewModel.sendMessage("Show response text")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Visible token."))
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Visible second."))

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .token("Visible second.")
        ])
    }

    @MainActor
    func testDisablingLiveActivityResponseExcerptsClearsActiveExcerpt() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager,
            showsLiveActivityResponseExcerpts: true
        )

        let didStart = await viewModel.sendMessage("Toggle response text")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Visible token."))
        viewModel.setShowsLiveActivityResponseExcerpts(false)

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .clearResponseExcerpt
        ])
    }

    @MainActor
    func testFollowupMessageStartsNewLiveActivityAfterCompletedResponse() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStartFirstResponse = await viewModel.sendMessage("Run the first answer")
        XCTAssertTrue(didStartFirstResponse)
        let gateway = try XCTUnwrap(fabricator.latest)
        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "First answer."))
        gateway.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: nil))

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)

        let didStartFollowup = await viewModel.sendMessage("Follow up")
        XCTAssertTrue(didStartFollowup)

        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "session-abc"),
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "session-abc")
        ])
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    @MainActor
    func testTitleStreamEventUpdatesLiveActivityTitle() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Name this run")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.title(sessionID: "session-abc", title: "Generated Search Plan"))

        XCTAssertEqual(viewModel.displayTitle, "Generated Search Plan")
        XCTAssertEqual(manager.updates, [
            .sessionTitle("Generated Search Plan")
        ])
    }

    /// The gateway carries the generated title as a `session.title` stream
    /// event (not a `done`-payload session), delivered before the turn's
    /// `message.complete`. Both still reach the Live Activity before finalization.
    @MainActor
    func testSessionTitleEventUpdatesLiveActivityBeforeCompletion() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Finish with a generated title")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.title(sessionID: "session-abc", title: "Generated Finish Plan"))
        gateway.deliver(GatewayEventFixture.complete(sessionID: "session-abc", content: nil))

        XCTAssertEqual(viewModel.displayTitle, "Generated Finish Plan")
        XCTAssertEqual(manager.updates, [
            .sessionTitle("Generated Finish Plan")
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
    }

    /// A turn that ends without an explicit `message.complete` still finalizes
    /// the Live Activity: the gateway's `session.info` echo reports the run is
    /// no longer running with no live projection, which completes the response.
    @MainActor
    func testSessionInfoNotRunningCompletesLiveActivity() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Run the tests")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)

        gateway.deliver(GatewayEventFixture.delta(sessionID: "session-abc", text: "Done."))
        gateway.deliver(GatewayEventFixture.info(sessionID: "session-abc", running: false))

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)
    }

    /// A transcript refresh that shows a completed assistant response finalizes
    /// the Live Activity (the gateway `refreshTranscriptIfCompleted` path).
    @MainActor
    func testTranscriptRefreshCompletionEndsLiveActivityFromCompletedTranscript() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(fabricator: fabricator, liveActivityManager: manager) { request in
            switch request.url?.path {
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Live work",
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
                      "content": "Completed from transcript refresh.",
                      "timestamp": 1770000110,
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
        gateway.deliver(GatewayEventFixture.toolStarted(sessionID: "session-abc", name: "shell_command"))

        // Prime the "latest server load has an assistant response" signal, then run
        // the completion check the coordinator exposes for background refresh.
        await viewModel.loadMessages()
        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "session-abc")

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Completed from transcript refresh."
        ])
    }

    /// Without a final assistant message after the latest user message, the
    /// transcript-refresh completion check must NOT finalize the Live Activity.
    @MainActor
    func testTranscriptRefreshWithoutFinalAssistantDoesNotCompleteLiveActivity() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(fabricator: fabricator, liveActivityManager: manager) { request in
            switch request.url?.path {
            case "/api/auth/ws-ticket":
                return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
            case "/api/sessions/session-abc":
                return apiTestJSONResponse("""
                {
                  "id": "session-abc",
                  "title": "Live work",
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
        gateway.deliver(GatewayEventFixture.toolStarted(sessionID: "session-abc", name: "shell_command"))

        await viewModel.loadMessages()
        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "session-abc")

        XCTAssertTrue(manager.ends.isEmpty)
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 0)
    }

    /// Suspending for background marks the Live Activity stale; it is not
    /// finalized (a later reconnect/resume owns the outcome).
    @MainActor
    func testSuspendingForBackgroundMarksLiveActivityStale() async throws {
        let fabricator = ScriptedGatewayFabricator()
        let manager = SpyAgentLiveActivityManager()
        let viewModel = try makeViewModel(
            fabricator: fabricator,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let gateway = try XCTUnwrap(fabricator.latest)
        gateway.deliver(GatewayEventFixture.reasoning(sessionID: "session-abc", text: "Thinking about the final answer."))
        XCTAssertEqual(manager.updates, [.reasoning("Thinking about the final answer.")])

        viewModel.suspendStreamForBackground()

        XCTAssertTrue(manager.didMarkStale)
        XCTAssertTrue(manager.ends.isEmpty)
        XCTAssertEqual(viewModel.activeStreamID, "session-abc")
    }

    func testFinalLiveActivityStateKeepsExcerptVisible() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Live work",
            status: .responding,
            currentActivity: "Writing response",
            responseExcerpt: "Here is the answer.",
            startedAt: startedAt,
            updatedAt: startedAt
        )

        let finalState = AgentRunActivityStateReducer.final(
            status: .complete,
            activity: "Response complete",
            state: state,
            now: Date(timeIntervalSince1970: 120)
        )

        XCTAssertEqual(finalState.status, .complete)
        XCTAssertEqual(finalState.currentActivity, "Response complete")
        XCTAssertEqual(finalState.responseExcerpt, "Here is the answer.")
        XCTAssertTrue(finalState.isFinal)
        XCTAssertFalse(finalState.isStale)
    }

    func testClearingLiveActivityExcerptRemovesRenderableText() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Live work",
            status: .responding,
            currentActivity: "Writing response",
            responseExcerpt: "Sensitive answer text.",
            startedAt: startedAt,
            updatedAt: startedAt
        )

        let cleared = AgentRunActivityStateReducer.clearingResponseExcerpt(
            state: state,
            now: Date(timeIntervalSince1970: 130)
        )

        XCTAssertEqual(cleared.status, .responding)
        XCTAssertEqual(cleared.currentActivity, "Writing response")
        XCTAssertTrue(cleared.responseExcerpt.isEmpty)
        XCTAssertEqual(cleared.startedAt, startedAt)
        XCTAssertEqual(cleared.updatedAt, Date(timeIntervalSince1970: 130))
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        fabricator: ScriptedGatewayFabricator,
        liveActivityManager: SpyAgentLiveActivityManager,
        showsLiveActivityResponseExcerpts: Bool = false,
        handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler ?? { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            return apiTestJSONResponse(#"{"ticket": "ticket-1"}"#, for: request)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)
        let summary = try Self.sessionSummary(id: "session-abc", title: "Live work")

        return ChatViewModel(
            session: summary,
            server: server,
            client: client,
            liveActivityManager: liveActivityManager,
            showsLiveActivityResponseExcerpts: showsLiveActivityResponseExcerpts,
            gatewayFabricator: fabricator.fabricator
        )
    }

    private static func sessionSummary(id: String, title: String) throws -> SessionSummary {
        let data = Data(#"{"session_id":"\#(id)","title":"\#(title)"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionSummary.self, from: data)
    }

    // MARK: - Orphaned activity reconciliation (#246)

    /// Builds a stream-status response for driving the reconciler core. `nil`
    /// `terminalState` omits the `journal` block entirely (the server's shape
    /// when it has no run summary), which the reconciler maps to `.complete`.
    private func statusResponse(active: Bool, terminalState: String? = nil) -> ChatStreamStatusResponse {
        ChatStreamStatusResponse(
            active: active,
            streamId: nil,
            replayAvailable: nil,
            journal: terminalState.map { RunJournalStatus(terminal: true, terminalState: $0) }
        )
    }

    @MainActor
    func testReconcilerEndsOnlyStreamsTheServerReportsInactive() async {
        var ended: [String] = []
        let now = Date(timeIntervalSince1970: 10_000)

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "done", sessionID: "s-done", updatedAt: now),
                OrphanedLiveActivity(streamID: "running", sessionID: "s-running", updatedAt: now),
                OrphanedLiveActivity(streamID: "errored", sessionID: "s-errored", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { streamID in
                switch streamID {
                case "done": self.statusResponse(active: false)   // server says the run is over → end the orphan
                case "running": self.statusResponse(active: true)  // still active → leave it for the reconnect path
                default: nil                                       // status check failed → leave it (no false positives)
                }
            },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { _ in }
        )

        XCTAssertEqual(ended, ["done"])
    }

    @MainActor
    func testReconcilerEndsNothingWhenNoOrphansExist() async {
        var endCount = 0

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [],
            now: Date(timeIntervalSince1970: 10_000),
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in endCount += 1; return true },
            notify: { _ in }
        )

        XCTAssertEqual(endCount, 0)
    }

    // #248: on the cold-launch pass, a recently finished orphan also fires a
    // "response complete" notification once it's ended.
    @MainActor
    func testReconcilerNotifiesRecentlyCompletedOrphanOnColdLaunchPass() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "recent", sessionID: "s-recent", updatedAt: now.addingTimeInterval(-60))
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(notified, ["s-recent"])
    }

    // #248: a completion older than the recency window is finalized silently.
    @MainActor
    func testReconcilerEndsButDoesNotNotifyStaleCompletion() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(
                    streamID: "stale",
                    sessionID: "s-stale",
                    updatedAt: now.addingTimeInterval(-(LiveActivityReconciler.recentCompletionWindow + 1))
                )
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(ended, ["stale"])
        XCTAssertTrue(notified.isEmpty)
    }

    // #248 dedup: if another path already finalized the run, `endOrphan` reports it
    // ended nothing here, so the reconciler must not fire a second notification.
    @MainActor
    func testReconcilerDoesNotNotifyWhenAnotherPathAlreadyFinalized() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "dup", sessionID: "s-dup", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in false },   // already final — nothing transitioned here
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertTrue(notified.isEmpty)
    }

    // #248: the foreground pass ends orphans but never notifies — the in-session
    // completion paths own notifications while the app is alive.
    @MainActor
    func testReconcilerForegroundPassEndsOrphansButNeverNotifies() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "recent", sessionID: "s-recent", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(ended, ["recent"])
        XCTAssertTrue(notified.isEmpty)
    }

    // #248: a future-dated completion (clock skew) is treated as not-recent.
    @MainActor
    func testReconcilerDoesNotNotifyFutureDatedCompletion() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "future", sessionID: "s-future", updatedAt: now.addingTimeInterval(120))
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertTrue(notified.isEmpty)
    }

    // #267: the journal `terminal_state` → Live Activity outcome mapping. The
    // load-bearing rows are `lost-worker-bookkeeping` → `.failed` (a silently
    // dropped run — the bug this issue fixes) and the unknown/missing fallback →
    // `.complete` (never mislabel a genuine completion as a failure).
    @MainActor
    func testReconciledOutcomeMapsTerminalStateToStatus() {
        func status(_ terminalState: String?) -> AgentRunActivityStatus {
            LiveActivityReconciler.reconciledOutcome(forTerminalState: terminalState).status
        }
        XCTAssertEqual(status("completed"), .complete)
        XCTAssertEqual(status("errored"), .failed)
        XCTAssertEqual(status("interrupted-by-crash"), .failed)
        XCTAssertEqual(status("lost-worker-bookkeeping"), .failed)
        XCTAssertEqual(status("interrupted-by-user"), .cancelled)
        XCTAssertEqual(status("running"), .complete)
        XCTAssertEqual(status("unknown"), .complete)
        XCTAssertEqual(status(nil), .complete)
        XCTAssertEqual(status("a-state-we-have-never-seen"), .complete)

        // The widget line reuses the existing localized completion strings.
        XCTAssertEqual(
            LiveActivityReconciler.reconciledOutcome(forTerminalState: "completed").activity,
            String(localized: "Response complete")
        )
        XCTAssertEqual(
            LiveActivityReconciler.reconciledOutcome(forTerminalState: "errored").activity,
            String(localized: "Response failed")
        )
        XCTAssertEqual(
            LiveActivityReconciler.reconciledOutcome(forTerminalState: "interrupted-by-user").activity,
            String(localized: "Response cancelled")
        )
    }

    // #267: the core finalizes each orphan with the outcome mapped from the
    // server journal's terminal_state — not an unconditional `.complete`.
    @MainActor
    func testReconcilerFinalizesOrphanWithMappedOutcome() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var endedWith: [String: AgentRunActivityStatus] = [:]

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "ok", sessionID: "s-ok", updatedAt: now),
                OrphanedLiveActivity(streamID: "lost", sessionID: "s-lost", updatedAt: now),
                OrphanedLiveActivity(streamID: "stopped", sessionID: "s-stopped", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { streamID in
                switch streamID {
                case "ok": self.statusResponse(active: false, terminalState: "completed")
                case "lost": self.statusResponse(active: false, terminalState: "lost-worker-bookkeeping")
                default: self.statusResponse(active: false, terminalState: "interrupted-by-user")
                }
            },
            endOrphan: { orphan, outcome in endedWith[orphan.streamID] = outcome.status; return true },
            notify: { _ in }
        )

        XCTAssertEqual(endedWith["ok"], .complete)
        XCTAssertEqual(endedWith["lost"], .failed)
        XCTAssertEqual(endedWith["stopped"], .cancelled)
    }

    // #267: a recently silently-failed run must still be finalized but must NOT
    // fire a "response complete" notification on the cold-launch pass — only a
    // run that mapped to `.complete` notifies.
    @MainActor
    func testReconcilerNotifiesOnlyCompletedTerminalStateOnColdLaunch() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "failed", sessionID: "s-failed", updatedAt: now.addingTimeInterval(-60)),
                OrphanedLiveActivity(streamID: "done", sessionID: "s-done", updatedAt: now.addingTimeInterval(-60))
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { streamID in
                streamID == "failed"
                    ? self.statusResponse(active: false, terminalState: "errored")
                    : self.statusResponse(active: false, terminalState: "completed")
            },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(ended.sorted(), ["done", "failed"])  // both finalized
        XCTAssertEqual(notified, ["s-done"])                // only the completed one notifies
    }

    // #246 follow-up (PR #266 #3): the orphan reconciler must defer to a stream
    // whose connection is live in this process. The manager tracks that ownership via the
    // lifecycle calls the coordinator already makes — set on `start`, cleared on
    // `markStale` (suspend/trouble) and `end` (finalize) — and
    // `orphanedActivities()` skips the tracked stream. This verifies the
    // ownership lifecycle directly (the ActivityKit-backed list isn't reachable in
    // unit tests, but the gate it consults is).
    @MainActor
    func testActiveConnectedStreamIDTracksLiveConnectionLifecycle() {
        let manager = AgentLiveActivityManager()

        // A live connection claims the stream so the reconciler leaves it alone.
        manager.start(sessionID: "session-1", sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        // Suspension / transport trouble releases the claim — the suspended stream is
        // eligible for server-truth reconciliation again.
        manager.markStale()
        XCTAssertNil(manager.activeConnectedStreamID)

        // Reconnecting the same stream re-claims it.
        manager.start(sessionID: "session-1", sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        // Finalizing the run releases the claim.
        manager.end(status: .complete, activity: "Response complete")
        XCTAssertNil(manager.activeConnectedStreamID)
    }
}

@MainActor
private final class SpyAgentLiveActivityManager: AgentLiveActivityManaging {
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
    private(set) var didMarkStale = false
    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        didMarkStale = true
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}
