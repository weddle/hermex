import XCTest
@testable import HermesMobile

/// View-model behaviour + diff parsing for the native workspace-git feature.
/// The VMs are PATH-scoped (the session's resolved workspace path), and every
/// git call runs against `/api/git/{…}?path=` / `{path, …}` bodies.
final class GitWorkspaceViewModelTests: APIClientTestCase {

    private static let statusWithIgnored = """
    {
      "git": {
        "branch": "main",
        "changed": 1,
        "files": [
          {"path": "a.swift", "unstaged": true, "additions": 3, "deletions": 1},
          {"path": ".DS_Store", "untracked": true, "additions": 0, "deletions": 0}
        ]
      }
    }
    """

    private func statusJSON(branch: String, files: String = "[]", changed: Int? = 0) -> String {
        let changedJSON = changed.map { ", \"changed\": \($0)" } ?? ""
        return #"{"git": {"branch": "\#(branch)"\#(changedJSON), "files": \#(files)}}"#
    }

    private func statusResponse(_ json: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        apiTestJSONResponse(json, for: request)
    }

    private func gitError(_ json: String, status: Int = 400, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }

    // MARK: - GitWorkspaceViewModel (read-only status)

    @MainActor
    func testLoadExcludesIgnoredFilesFromCountsAndTotals() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/status")
            XCTAssertEqual(try? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value, "/tmp/s1")
            return apiTestJSONResponse(Self.statusWithIgnored, for: request)
        }
        let viewModel = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertFalse(viewModel.isNonRepository)
        let status = try XCTUnwrap(viewModel.status)
        XCTAssertEqual(status.files?.count, 2)
        XCTAssertEqual(status.trackedFiles.count, 1)
        XCTAssertEqual(status.changedCount, 1)
        XCTAssertEqual(status.totalAdditions, 3)
        XCTAssertEqual(status.totalDeletions, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testRefreshReplacesStaleData() async throws {
        var dirty = true
        let client = makeClient { request in
            let json = dirty ? Self.statusWithIgnored : self.statusJSON(branch: "main")
            return apiTestJSONResponse(json, for: request)
        }
        let viewModel = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()
        XCTAssertEqual(viewModel.status?.trackedFiles.count, 1)

        dirty = false
        await viewModel.load()
        XCTAssertEqual(viewModel.status?.trackedFiles.count, 0, "Refreshing replaces, not appends.")
        XCTAssertEqual(viewModel.status?.changedCount, 0)
    }

    @MainActor
    func testDifferentPathsHaveIndependentState() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first { $0.name == "path" }?.value
            let branch = path == "/tmp/s1" ? "main" : "feature/x"
            return apiTestJSONResponse(self.statusJSON(branch: branch), for: request)
        }

        let vm1 = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        let vm2 = GitWorkspaceViewModel(path: "/tmp/s2", server: URL(string: "https://example.test")!, apiClient: client)

        await vm1.load()
        await vm2.load()

        XCTAssertEqual(vm1.status?.branch, "main")
        XCTAssertEqual(vm2.status?.branch, "feature/x")
    }

    @MainActor
    func testLoadIfNeededLoadsOnlyOnce() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse(self.statusJSON(branch: "main"), for: request)
        }
        let viewModel = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testLoadIfNeededRetriesAfterTransientFailure() async throws {
        var shouldFail = true
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            if shouldFail {
                shouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }
            return apiTestJSONResponse(self.statusJSON(branch: "main"), for: request)
        }
        let viewModel = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.status?.branch, "main")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testNonRepositoryWorkspaceSetsEmptyState() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"git": null}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.isNonRepository)
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testLoadSurfacesErrorOnHTTPFailure() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error": "boom"}"#.utf8))
        }
        let viewModel = GitWorkspaceViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertNil(viewModel.status)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    // MARK: - GitWorkspaceAvailabilityViewModel

    @MainActor
    func testAvailabilityLoadsStatusAndBranchesForRepository() async throws {
        var branchesLoaded = false
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(self.statusJSON(branch: "main", files: #"[{"path":"a.swift","unstaged":true}]"#, changed: 1), for: request)
            case "/api/git/branches":
                branchesLoaded = true
                return apiTestJSONResponse(#"[{"name":"main","checked_out":true,"is_default":true,"worktree_path":null}]"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        XCTAssertFalse(viewModel.hasRepository)
        await viewModel.load()

        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertEqual(viewModel.status?.changedCount, 1)
        XCTAssertTrue(branchesLoaded)
        XCTAssertEqual(viewModel.currentBranchName, "main")
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityHidesForNonRepository() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"git": null}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNil(viewModel.status)
        XCTAssertNil(viewModel.branches)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityHidesOnHTTPFailure() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error": "boom"}"#.utf8))
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.statusError)
    }

    @MainActor
    func testAvailabilityLoadIfNeededRetriesAfterTransientFailure() async throws {
        var shouldFail = true
        let client = makeClient { request in
            if request.url?.path == "/api/git/status", shouldFail {
                shouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }
            if request.url?.path == "/api/git/branches" {
                return apiTestJSONResponse(#"[{"name":"main","checked_out":true}]"#, for: request)
            }
            return apiTestJSONResponse(self.statusJSON(branch: "main"), for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNotNil(viewModel.lastError)

        await viewModel.loadIfNeeded()

        XCTAssertTrue(viewModel.hasRepository, "Load-if-needed retries after a transient status failure.")
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testCheckoutRefreshesBranchAndStatus() async throws {
        var currentBranch = "main"
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(self.statusJSON(branch: currentBranch), for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"[{"name":"main","checked_out":true},{"name":"feature","checked_out":false}]"#, for: request)
            case "/api/git/branch/switch":
                let method = request.httpMethod
                XCTAssertEqual(method, "POST")
                currentBranch = "feature"
                return apiTestJSONResponse(#"{"branch": "feature"}"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await viewModel.load()
        XCTAssertEqual(viewModel.currentBranchName, "main")

        let outcome = await viewModel.checkout(GitCheckoutTarget(ref: "feature", mode: .local))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(viewModel.currentBranchName, "feature")
        XCTAssertEqual(viewModel.status?.branch, "feature")
    }

    @MainActor
    func testCheckoutDirtyWorktreeRequestsStashConfirmation() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(self.statusJSON(branch: "main"), for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"[{"name":"main","checked_out":true}]"#, for: request)
            case "/api/git/branch/switch":
                return self.gitError(#"{"error":"Working tree is dirty","code":"dirty_worktree"}"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await viewModel.load()

        let outcome = await viewModel.checkout(GitCheckoutTarget(ref: "feature", mode: .local))

        XCTAssertEqual(outcome, .requiresStash)
        XCTAssertNotNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testPerformRemoteActionPushSucceeds() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(self.statusJSON(branch: "main"), for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"[{"name":"main","checked_out":true}]"#, for: request)
            case "/api/git/review/push":
                XCTAssertEqual(request.httpMethod, "POST")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await viewModel.load()

        let ok = await viewModel.performRemoteAction(.push)

        XCTAssertTrue(ok)
        XCTAssertEqual(viewModel.lastActionMessage, "Pushed successfully.")
    }

    @MainActor
    func testPerformRemoteActionPushFailureSurfacesActionError() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(self.statusJSON(branch: "main"), for: request)
            case "/api/git/review/push":
                return self.gitError(#"{"error":"Remote rejected the push","code":"push_failed"}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await viewModel.load()

        let ok = await viewModel.performRemoteAction(.push)

        XCTAssertFalse(ok)
        XCTAssertEqual(viewModel.actionErrorMessage, "Remote rejected the push" )
    }

    // MARK: - Quick commit pipeline

    private static let statusWithOneFile = """
    {"git":{"branch":"main","changed":1,"files":[
      {"path":"a.swift","unstaged":true,"additions":3,"deletions":1}
    ]}}
    """

    @MainActor
    func testQuickCommitWithPushRunsFullPipelineAndReportsPhases() async throws {
        var phases: [GitCommitPhase] = []
        var paths: [String] = []
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"[{"name":"main","checked_out":true}]"#, for: request)
            case "/api/git/review/stage":
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            case "/api/git/review/commit":
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected path: \(path)")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertTrue(vm.hasCommittableChanges)

        let outcome = await vm.quickCommit(push: true, message: "Ship it") { phases.append($0) }

        guard case .success(let result) = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertEqual(result.branch, "main")
        XCTAssertEqual(result.message, "Ship it")
        XCTAssertTrue(result.didPush)
        XCTAssertEqual(phases, [.committing])
        XCTAssertNil(vm.commitPhase, "Phase resets after the pipeline finishes.")
        XCTAssertTrue(paths.contains("/api/git/review/stage"))
        XCTAssertTrue(paths.contains("/api/git/review/commit"))
    }

    @MainActor
    func testQuickCommitWithoutPushSkipsPushCall() async throws {
        var paths: [String] = []
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/review/stage", "/api/git/review/commit":
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: false, message: "Local only")

        guard case .success(let result) = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertFalse(result.didPush)
        XCTAssertFalse(paths.contains("/api/git/review/push"))
    }

    @MainActor
    func testQuickCommitReturnsNothingToCommitWhenClean() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(self.statusJSON(branch: "main", files: "[]", changed: 0), for: request)
        }
        let vm = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: false, message: "nothing")

        XCTAssertEqual(outcome, .nothingToCommit)
    }

    @MainActor
    func testQuickCommitFailsWithFriendlyMessageWhenStageRejected() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/review/stage":
                return self.gitError(#"{"message":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: false, message: "x")

        XCTAssertEqual(outcome, .failure)
        XCTAssertEqual(vm.actionErrorMessage, "Destructive git writes are disabled")
    }

    @MainActor
    func testRefreshAfterExternalMutationPicksUpNewStatus() async throws {
        var changed = 1
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse("{\"git\":{\"branch\":\"main\",\"changed\":\(changed),\"files\":[]}}", for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"[]"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitWorkspaceAvailabilityViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.status?.changedCount, 1)

        changed = 0
        await vm.refreshAfterExternalMutation()

        XCTAssertEqual(vm.status?.changedCount, 0)
    }

    // MARK: - GitCommitViewModel (advanced staging sheet)

    @MainActor
    func testCommitSheetLoadsFilesAndTogglesSelection() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(Self.statusWithOneFile, for: request)
        }
        let vm = GitCommitViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)

        await vm.load()

        XCTAssertEqual(vm.trackedFiles.map(\.path), ["a.swift"])
        XCTAssertFalse(vm.hasSelection)
        let file = try XCTUnwrap(vm.trackedFiles.first)
        vm.toggleSelection(file)
        XCTAssertTrue(vm.hasSelection)
        vm.toggleSelection(file)
        XCTAssertFalse(vm.hasSelection)
    }

    @MainActor
    func testCommitSheetStageSelectedOrAllStages() async throws {
        var staged = false
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/review/stage":
                staged = true
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitCommitViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        await vm.stageSelectedOrAll()

        XCTAssertTrue(staged)
        XCTAssertNil(vm.actionErrorMessage)
    }

    @MainActor
    func testCommitSheetCommitRequiresNonEmptyMessage() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(Self.statusWithOneFile, for: request)
        }
        let vm = GitCommitViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        vm.message = "   "

        let ok = await vm.commit(push: false)

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.actionErrorMessage, "Enter a commit message first.")
    }

    @MainActor
    func testCommitSheetCommitSucceedsAndClearsState() async throws {
        var committed = false
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/review/commit":
                committed = true
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitCommitViewModel(path: "/tmp/s1", server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        vm.message = "Ship it"
        let file = try XCTUnwrap(vm.trackedFiles.first)
        vm.toggleSelection(file)

        let ok = await vm.commitSelected(push: false)

        XCTAssertTrue(ok)
        XCTAssertTrue(committed)
        XCTAssertEqual(vm.committedRevision, 1)
        XCTAssertEqual(vm.message, "")
        XCTAssertFalse(vm.hasSelection)
    }

    // MARK: - GitDiff parsing (pure)

    func testDiffParserDropsPreambleAndClassifiesLines() {
        let raw = """
        diff --git a/App.swift b/App.swift
        index 1234567..89abcde 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -1,3 +1,3 @@
         context line
        -removed line
        +added line
        """
        let hunks = DiffHunk.parse(raw)

        XCTAssertEqual(hunks.count, 1)
        let hunk = try! XCTUnwrap(hunks.first)
        XCTAssertEqual(hunk.header, "@@ -1,3 +1,3 @@")
        XCTAssertEqual(hunk.lines.count, 3)
        XCTAssertEqual(hunk.lines[0].kind, .context)
        XCTAssertEqual(hunk.lines[1].kind, .deletion)
        XCTAssertEqual(hunk.lines[2].kind, .addition)
        XCTAssertEqual(hunk.lines[2].text, "+added line")
    }

    func testDiffParserHandlesMultipleHunks() {
        let raw = """
        @@ -1,1 +1,1 @@
        -a
        +b
        @@ -10,2 +10,3 @@
         keep
        +new
        """
        let hunks = DiffHunk.parse(raw)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].id, 0)
        XCTAssertEqual(hunks[1].id, 1)
        XCTAssertEqual(hunks[1].header, "@@ -10,2 +10,3 @@")
        XCTAssertEqual(hunks[1].lines.map(\.kind), [.context, .addition])
        XCTAssertEqual(hunks[1].lines[0].newLineNumber, 10)
        XCTAssertEqual(hunks[1].lines[1].newLineNumber, 11)
    }

    func testDiffParserCreatesSyntheticPatchWithoutHunkHeader() {
        let hunks = DiffHunk.parse("--- a/a.txt\n+++ b/a.txt\n-old\n+new")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertTrue(hunks[0].isSynthetic)
        XCTAssertEqual(hunks[0].displayLabel, "Patch 1 of 1")
        XCTAssertEqual(hunks[0].additions, 1)
        XCTAssertEqual(hunks[0].deletions, 1)
    }

    func testDiffParserEmptyInputReturnsNoHunks() {
        XCTAssertTrue(DiffHunk.parse("").isEmpty)
        XCTAssertTrue(DiffHunk.parse("diff --git a/x b/x\nindex 1..2\n").isEmpty, "No hunk header → nothing to show.")
    }

    // MARK: - Git action toast (pure)

    @MainActor
    func testToastProgressSuccessAndAutoDismiss() async {
        let state = GitActionToastState()
        state.showProgress(GitActionProgress(title: "Working", detailLines: ["• Pushing"]))
        XCTAssertNotNil(state.progress)
        XCTAssertNil(state.success)

        state.showSuccess(GitActionSuccess(title: "Done"), autoDismissAfter: .milliseconds(10))
        XCTAssertNil(state.progress)
        XCTAssertNotNil(state.success)

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(state.success)
    }

    @MainActor
    func testToastRapidReplacementDoesNotDismissLatestSuccess() async {
        let state = GitActionToastState()
        state.showSuccess(GitActionSuccess(title: "First"), autoDismissAfter: .milliseconds(5))
        state.showSuccess(GitActionSuccess(title: "Second"), autoDismissAfter: .seconds(1))

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.success?.title, "Second")
        state.dismissSuccess()
    }
}
