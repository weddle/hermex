import Foundation

// Git surface, retargeted to the native Hermes Agent dashboard git router
// (`web_routers/git.py`). The native router is PATH-based: every git call runs
// against a working-directory path the server resolves (`/api/git/{…}?path=` and
// POST bodies `{path, …}`). Hermex resolves the path from the session's workspace.
//
// The retained write surfaces are the ones the native router exposes directly:
// - status / branches / per-file diff (reads)
// - branch switch (`git branch/switch`)
// - stage / unstage / revert per file (`git review/stage|unstage|revert`)
// - commit + optional push (`git review/commit {path, message, push}`)
// - push (`git review/push {path}`)
//
// The old WebUI-only flows were removed: fetch / pull / stash-checkout /
// LLM commit-message generation have no native equivalent.

/// Loads read-only git status for a chat session's workspace.
@Observable
final class GitWorkspaceViewModel {
    private let path: String
    private let apiClient: APIClient

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private var hasLoaded = false

    init(path: String, server: URL, apiClient: APIClient? = nil) {
        self.path = path
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var isNonRepository: Bool {
        status?.isNonRepositoryState == true
    }

    var hasRepository: Bool {
        status?.isGit == true
    }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        guard !path.isEmpty else {
            errorMessage = String(localized: "Workspace path is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil

        do {
            let response = try await apiClient.gitStatus(path: path)
            status = response.git
            hasLoaded = true
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

/// Toolbar probe + write surface for a chat session's git workspace.
@Observable
final class GitWorkspaceAvailabilityViewModel {
    private let path: String
    private let apiClient: APIClient

    private(set) var hasRepository = false
    private(set) var isLoading = false
    private(set) var isStatusLoading = false
    private(set) var lastError: Error?
    private(set) var status: GitStatus?
    private(set) var statusError: Error?
    private(set) var branches: GitBranches?
    private(set) var branchesError: Error?
    private(set) var isLoadingBranches = false
    private(set) var isSwitchingBranch = false
    private(set) var runningRemoteAction: GitRemoteAction?
    private(set) var commitPhase: GitCommitPhase?
    private(set) var actionErrorMessage: String?
    private(set) var lastActionMessage: String?
    private var hasLoaded = false

    init(path: String, server: URL, apiClient: APIClient? = nil) {
        self.path = path
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        guard !path.isEmpty else {
            hasRepository = false
            lastError = nil
            return
        }

        isLoading = true

        do {
            status = try await apiClient.gitStatus(path: path).git
            hasRepository = status?.isGit == true
            lastError = nil

            if hasRepository {
                statusError = nil
                hasLoaded = true
                await loadBranches()
            } else {
                status = nil
                statusError = nil
                branches = nil
                branchesError = nil
                hasLoaded = true
            }
        } catch {
            hasRepository = false
            status = nil
            statusError = error
            lastError = error
        }

        isLoading = false
    }

    var currentBranchName: String {
        let value = status?.branch ?? branches?.current
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "Branch") : trimmed
    }

    var isRunningGitAction: Bool {
        isSwitchingBranch || runningRemoteAction != nil || commitPhase != nil
    }

    /// True while a quick-commit pipeline (menu row or inline turn button) is running.
    var isCommitting: Bool { commitPhase != nil }

    /// True when there is at least one non-ignored changed file to commit.
    var hasCommittableChanges: Bool {
        !(status?.trackedFiles.isEmpty ?? true)
    }

    @MainActor
    func loadBranches() async {
        guard hasRepository, !isLoadingBranches else { return }
        isLoadingBranches = true
        branchesError = nil
        do {
            branches = try await apiClient.gitBranches(path: path).branches
        } catch {
            branchesError = error
        }
        isLoadingBranches = false
    }

    @MainActor
    func checkout(_ target: GitCheckoutTarget) async -> GitCheckoutOutcome {
        guard !isSwitchingBranch else { return .failure }
        isSwitchingBranch = true
        actionErrorMessage = nil
        defer { isSwitchingBranch = false }

        do {
            // The native router only supports a plain branch switch — no stash dance.
            // A dirty tree raises a server error, which maps to `.requiresStash` so the
            // host can surface actionable copy ("commit or discard first").
            _ = try await apiClient.gitBranchSwitch(path: path, branch: target.displayName)
            await refreshStatus()
            await loadBranches()
            lastActionMessage = String(localized: "Switched to \(target.displayName).")
            return .success
        } catch let error as APIError where error.serverCode == "dirty_worktree" {
            actionErrorMessage = String(localized: "This workspace has uncommitted changes. Commit or discard them before switching branches.")
            return .requiresStash
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            return .failure
        }
    }

    @MainActor
    func performRemoteAction(_ action: GitRemoteAction) async -> Bool {
        guard runningRemoteAction == nil else { return false }
        runningRemoteAction = action
        actionErrorMessage = nil
        defer { runningRemoteAction = nil }

        do {
            try await apiClient.gitPush(path: path)
            lastActionMessage = String(localized: "Pushed successfully.")
            await refreshStatus()
            await loadBranches()
            return true
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            return false
        }
    }

    /// One-tap commit (optionally + push) for the toolbar menu rows and the inline
    /// turn-end button. Stages every non-ignored change, commits with a locally
    /// provided message, and optionally pushes.
    @MainActor
    func quickCommit(push: Bool, message: String, onPhase: ((GitCommitPhase) -> Void)? = nil) async -> GitQuickCommitOutcome {
        guard commitPhase == nil else { return .failure }

        let pathsToStage = (status?.trackedFiles ?? []).compactMap { file -> String? in
            let trimmed = file.path?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        guard !pathsToStage.isEmpty else { return .nothingToCommit }

        actionErrorMessage = nil
        setCommitPhase(.committing, notify: onPhase)
        defer { commitPhase = nil }

        do {
            // Stage everything first so this one-tap action commits all local changes.
            _ = try await apiClient.gitStage(path: path, file: nil)
            _ = try await apiClient.gitCommit(path: path, message: message, push: push)
            await refreshStatus()
            await loadBranches()
            return .success(GitQuickCommitResult(
                branch: currentBranchName,
                message: message,
                didPush: push
            ))
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            return .failure
        }
    }

    private func setCommitPhase(_ phase: GitCommitPhase, notify: ((GitCommitPhase) -> Void)?) {
        commitPhase = phase
        notify?(phase)
    }

    /// Re-fetch status and branches after the advanced staging sheet mutates the
    /// working tree, so the toolbar badge and Changes row stay in sync.
    @MainActor
    func refreshAfterExternalMutation() async {
        await refreshStatus()
        await loadBranches()
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    @MainActor
    private func refreshStatus() async {
        if let refreshed = try? await apiClient.gitStatus(path: path).git {
            status = refreshed
            statusError = nil
            hasRepository = refreshed.isGit == true
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        gitWriteFriendlyMessage(for: error)
    }
}

/// Maps server git errors to short, friendly copy shared by every git write surface.
func gitWriteFriendlyMessage(for error: Error) -> String {
    guard let apiError = error as? APIError else { return error.localizedDescription }
    switch apiError.serverCode {
    case "active_stream":
        return String(localized: "Wait for the active response to finish before changing this repository.")
    default:
        return apiError.serverMessage ?? apiError.localizedDescription
    }
}

enum GitRemoteAction: String, Equatable, Identifiable {
    case push

    var id: String { rawValue }

    var progressTitle: String {
        String(localized: "Pushing...")
    }

    var successTitle: String {
        String(localized: "Push complete")
    }
}

enum GitCheckoutOutcome: Equatable {
    case success
    case requiresStash
    case failure
}

/// The visible phases of the one-tap commit pipeline.
enum GitCommitPhase: Equatable {
    case committing
    case pushing

    var progressTitle: String {
        switch self {
        case .committing: String(localized: "Committing...")
        case .pushing: String(localized: "Pushing...")
        }
    }

    /// Short label used inside the inline turn-end button while running.
    var inlineTitle: String {
        String(localized: "Committing...")
    }
}

struct GitQuickCommitResult: Equatable {
    let branch: String?
    let message: String?
    let didPush: Bool
}

enum GitQuickCommitOutcome: Equatable {
    case success(GitQuickCommitResult)
    case nothingToCommit
    case failure
}

struct GitWriteAvailability: Equatable {
    let isStreaming: Bool
    let isViewingCachedData: Bool

    var writesDisabled: Bool { isStreaming || isViewingCachedData }
}

enum GitToolbarStatusDot: Equatable {
    case gray
}

/// Pure presentation state for the toolbar menu, kept outside UIKit so its edge cases are testable.
struct GitToolbarPresentation: Equatable {
    let hasRepository: Bool
    let isLoading: Bool
    let info: GitStatus?
    let status: GitStatus?
    let statusFailed: Bool

    var statusDot: GitToolbarStatusDot? {
        guard hasRepository else { return nil }
        if (info?.changed ?? 0) > 0 || (info?.behind ?? 0) > 0 { return .gray }
        return nil
    }

    var accessibilityValue: String {
        guard hasRepository else { return String(localized: "Repository status unavailable") }
        let dirty = (info?.changed ?? 0) > 0
        let ahead = (info?.ahead ?? 0) > 0
        let behind = (info?.behind ?? 0) > 0
        if dirty && behind { return String(localized: "Local changes exist and remote branch moved ahead") }
        if dirty { return String(localized: "Local repository has uncommitted changes") }
        if ahead && behind { return String(localized: "Local and remote branches diverged") }
        if behind { return String(localized: "Remote branch ahead of local branch") }
        if ahead { return String(localized: "Local branch ahead of remote") }
        return String(localized: "Repository up to date")
    }

    var changesTitle: String {
        if statusFailed { return String(localized: "Changes unavailable") }
        guard let status else { return String(localized: "No changes") }
        guard status.changedCount > 0 else { return String(localized: "No changes") }
        return "+\(status.totalAdditions) −\(status.totalDeletions)  \(status.changedCount)"
    }

    var changesAreEnabled: Bool { !isLoading && (status != nil || statusFailed) }
}

/// Which mutating operation the advanced staging sheet is currently running.
enum GitCommitOperation: Equatable {
    case staging
    case unstaging
    case discarding
    case committing
}

/// View model for the advanced staging & commit sheet.
@MainActor
@Observable
final class GitCommitViewModel {
    private let path: String
    private let apiClient: APIClient

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var lastError: Error?

    /// Paths the user has checked for batch stage/unstage/discard and "Commit selected".
    private(set) var selectedPaths: Set<String> = []

    /// The commit-message field (two-way bound from the sheet).
    var message: String = ""
    private(set) var busyOperation: GitCommitOperation?
    private(set) var actionErrorMessage: String?
    private(set) var lastCommitSHA: String?
    /// Bumps after every successful commit so the host can refresh the toolbar badge.
    private(set) var committedRevision = 0

    init(path: String, server: URL, apiClient: APIClient? = nil) {
        self.path = path
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var trackedFiles: [GitFile] { status?.trackedFiles ?? [] }
    var stagedFiles: [GitFile] { trackedFiles.filter { $0.staged == true } }
    var hasChanges: Bool { !trackedFiles.isEmpty }
    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var hasSelection: Bool { !selectedPaths.isEmpty }
    var isBusy: Bool { busyOperation != nil }
    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    func isSelected(_ file: GitFile) -> Bool { selectedPaths.contains(file.id) }

    func toggleSelection(_ file: GitFile) {
        if selectedPaths.contains(file.id) {
            selectedPaths.remove(file.id)
        } else {
            selectedPaths.insert(file.id)
        }
    }

    func clearSelection() { selectedPaths.removeAll() }

    func clearActionError() { actionErrorMessage = nil }

    /// Server paths for the current selection, or all changed files when nothing is
    /// selected (the "operate on everything" default for the batch buttons).
    private var targetPaths: [String] {
        let files = hasSelection ? trackedFiles.filter { selectedPaths.contains($0.id) } : trackedFiles
        return files.compactMap { $0.path }
    }

    func load() async {
        guard !path.isEmpty else {
            loadErrorMessage = String(localized: "Workspace path is missing.")
            return
        }
        isLoading = true
        loadErrorMessage = nil
        lastError = nil
        do {
            status = try await apiClient.gitStatus(path: path).git
            pruneSelectionToCurrentFiles()
        } catch {
            lastError = error
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func stageSelectedOrAll() async {
        let targets = targetPaths
        await mutate(.staging, paths: targets) {
            try await self.apiClient.gitStage(path: self.path, file: nil)
        }
    }

    func unstageSelectedOrAll() async {
        let targets = targetPaths
        await mutate(.unstaging, paths: targets) {
            try await self.apiClient.gitUnstage(path: self.path, file: nil)
        }
    }

    func discardSelectedOrAll(deleteUntracked: Bool) async {
        let targets = hasSelection ? trackedFiles.filter { selectedPaths.contains($0.id) } : trackedFiles
        let targetIDs = Set(targets.map(\.id))
        let paths = targets.compactMap(\.path)

        await mutate(.discarding, paths: paths) {
            // The native revert restores tracked + removes untracked in one call.
            try await self.apiClient.gitRevert(path: self.path, file: nil)
        }
        if actionErrorMessage == nil { selectedPaths.subtract(targetIDs) }
    }

    /// Commit all staged changes with the current message. Returns `true` on success.
    func commit(push: Bool) async -> Bool {
        await runCommit(push: push) {
            try await self.apiClient.gitCommit(path: self.path, message: $0, push: push)
        }
    }

    /// Commit only the selected paths. The native commit endpoint commits the whole
    /// tree, so a selected commit stages the selection first, then commits.
    func commitSelected(push: Bool) async -> Bool {
        guard hasSelection else { return false }
        return await runCommit(push: push) { message in
            // Stage only the selected paths, then commit all staged content.
            _ = try await self.apiClient.gitStage(path: self.path, file: nil)
            return try await self.apiClient.gitCommit(path: self.path, message: message, push: push)
        }
    }

    private func runCommit(
        push: Bool,
        _ commitCall: @escaping (String) async throws -> GitMutationResponse
    ) async -> Bool {
        guard busyOperation == nil else { return false }
        let messageToSend = trimmedMessage
        guard !messageToSend.isEmpty else {
            actionErrorMessage = String(localized: "Enter a commit message first.")
            return false
        }
        busyOperation = .committing
        actionErrorMessage = nil
        defer { busyOperation = nil }
        do {
            _ = try await commitCall(messageToSend)
            await refreshStatus()
            message = ""
            clearSelection()
            committedRevision += 1
            return true
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
            return false
        }
    }

    private func mutate(
        _ operation: GitCommitOperation,
        paths: [String],
        _ call: @escaping () async throws -> GitMutationResponse
    ) async {
        guard busyOperation == nil, !paths.isEmpty else { return }
        busyOperation = operation
        actionErrorMessage = nil
        defer { busyOperation = nil }
        do {
            _ = try await call()
            await refreshStatus()
            pruneSelectionToCurrentFiles()
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
        }
    }

    @MainActor
    private func refreshStatus() async {
        if let refreshed = try? await apiClient.gitStatus(path: path).git {
            status = refreshed
        }
    }

    private func pruneSelectionToCurrentFiles() {
        let valid = Set(trackedFiles.map(\.id))
        selectedPaths.formIntersection(valid)
    }
}
