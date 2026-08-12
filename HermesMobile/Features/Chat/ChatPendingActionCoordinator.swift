import Foundation
import Observation
import OSLog

private let chatPendingActionCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatPendingActionCoordinator"
)

/// Friendly stand-in for the server's 409 `{"stale": true}` respond rejection:
/// the prompt already expired, so the card is dismissed instead of erroring (issue #25).
struct PendingPromptExpiredError: LocalizedError, Equatable {
    enum Prompt: Equatable {
        case approval
        case clarification
    }

    let prompt: Prompt

    var errorDescription: String? {
        switch prompt {
        case .approval:
            String(localized: "That approval request already expired, so the agent has moved on.")
        case .clarification:
            String(localized: "That clarification prompt already expired, so the agent has moved on.")
        }
    }
}

@MainActor
protocol ChatPendingActionCoordinatorDelegate: AnyObject {
    var pendingActionSessionID: String? { get }
    var pendingActionHasActiveStream: Bool { get }
    var pendingActionIsStreamConnectionSuspended: Bool { get }

    func pendingActionCoordinatorWillSubmitAction()
    func pendingActionCoordinatorDidFailAction(_ error: Error)
}

@MainActor
@Observable
final class ChatPendingActionCoordinator {
    private(set) var approvalPrompt: ApprovalPromptState?
    private(set) var isRespondingToApproval = false
    private(set) var approvalErrorMessage: String?
    private(set) var isSessionApprovalBypassEnabled = false

    private(set) var clarificationPrompt: ClarificationPromptState?
    private(set) var isRespondingToClarification = false
    private(set) var clarificationErrorMessage: String?

    weak var delegate: ChatPendingActionCoordinatorDelegate?

    private let client: APIClient

    private var approvalPendingBySession: [String: ApprovalPromptState] = [:]
    private var clarificationPendingBySession: [String: ClarificationPromptState] = [:]

    var hasPendingPrompt: Bool {
        approvalPrompt != nil || clarificationPrompt != nil
    }

    init(client: APIClient) {
        self.client = client
    }

    // MARK: - Approval

    func refreshApprovalBypassState() async {
        guard let sessionID = delegate?.pendingActionSessionID else { return }

        do {
            let response = try await client.sessionYolo(sessionID: sessionID)
            isSessionApprovalBypassEnabled = response.yoloEnabled == true
            if isSessionApprovalBypassEnabled {
                approvalPrompt = nil
            } else {
                renderApprovalPromptForCurrentSession()
            }
        } catch {
            // Approval bypass state is advisory UI; failures should not block chat.
        }
    }

    @discardableResult
    func respondToApproval(_ choice: ApprovalChoice) async -> Bool {
        guard let prompt = approvalPrompt,
              prompt.sessionID == delegate?.pendingActionSessionID
        else { return false }

        isRespondingToApproval = true
        approvalErrorMessage = nil
        delegate?.pendingActionCoordinatorWillSubmitAction()
        defer { isRespondingToApproval = false }

        do {
            try await client.withGatewayConnection(profile: nil) { gateway in
                try await gateway.respondToApproval(sessionID: prompt.sessionID, choice: choice.rawValue)
            }
            approvalPendingBySession[prompt.sessionID] = nil
            approvalPrompt = nil
            return true
        } catch {
            approvalErrorMessage = error.localizedDescription
            delegate?.pendingActionCoordinatorDidFailAction(error)
            return false
        }
    }

    @discardableResult
    func skipApprovalsForCurrentSession() async -> Bool {
        guard let prompt = approvalPrompt,
              prompt.sessionID == delegate?.pendingActionSessionID
        else { return false }

        isRespondingToApproval = true
        approvalErrorMessage = nil
        delegate?.pendingActionCoordinatorWillSubmitAction()
        defer { isRespondingToApproval = false }

        do {
            let response = try await client.setSessionYolo(sessionID: prompt.sessionID, enabled: true)
            isSessionApprovalBypassEnabled = response.yoloEnabled ?? true
            approvalPendingBySession[prompt.sessionID] = nil
            approvalPrompt = nil
            return true
        } catch {
            approvalErrorMessage = error.localizedDescription
            delegate?.pendingActionCoordinatorDidFailAction(error)
            return false
        }
    }

    func startMonitoring() {
        // Approval/clarification prompts arrive as gateway stream events routed
        // through the chat coordinator, so there is no SSE monitoring to start.
    }

    func stopMonitoring(clearPrompt: Bool) {
        guard clearPrompt else { return }
        if let sessionID = delegate?.pendingActionSessionID {
            approvalPendingBySession[sessionID] = nil
            clarificationPendingBySession[sessionID] = nil
        }
        approvalPrompt = nil
        approvalErrorMessage = nil
        clarificationPrompt = nil
        clarificationErrorMessage = nil
    }

    func applyApprovalUpdate(_ update: ApprovalPendingResponse, sessionID: String) {
        if let pending = update.pending, !pending.isEmpty {
            let prompt = ApprovalPromptState(
                sessionID: sessionID,
                pending: pending,
                pendingCount: max(update.pendingCount ?? 1, 1)
            )
            approvalPendingBySession[sessionID] = prompt
        } else {
            approvalPendingBySession[sessionID] = nil
        }

        renderApprovalPromptForCurrentSession()
    }

    // MARK: - Clarification

    @discardableResult
    func respondToClarification(_ responseText: String) async -> Bool {
        guard let prompt = clarificationPrompt,
              prompt.sessionID == delegate?.pendingActionSessionID
        else { return false }

        let response = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            clarificationErrorMessage = String(localized: "Enter a response before submitting.")
            return false
        }

        isRespondingToClarification = true
        clarificationErrorMessage = nil
        delegate?.pendingActionCoordinatorWillSubmitAction()
        defer { isRespondingToClarification = false }

        do {
            let requestID = prompt.pending.clarifyId ?? ""
            try await client.withGatewayConnection(profile: nil) { gateway in
                try await gateway.respondToClarification(requestID: requestID, answer: response)
            }
            clarificationPendingBySession[prompt.sessionID] = nil
            clarificationPrompt = nil
            return true
        } catch {
            clarificationErrorMessage = error.localizedDescription
            delegate?.pendingActionCoordinatorDidFailAction(error)
            return false
        }
    }

    func applyClarificationUpdate(_ update: ClarificationPendingResponse, sessionID: String) {
        if let pending = update.pending, !pending.isEmpty {
            let prompt = ClarificationPromptState(
                sessionID: sessionID,
                pending: pending,
                pendingCount: max(update.pendingCount ?? 1, 1)
            )
            clarificationPendingBySession[sessionID] = prompt
        } else {
            clarificationPendingBySession[sessionID] = nil
        }

        renderClarificationPromptForCurrentSession()
    }

    // MARK: - Rendering

    private func renderApprovalPromptForCurrentSession() {
        guard let sessionID = delegate?.pendingActionSessionID else {
            approvalPrompt = nil
            return
        }

        guard delegate?.pendingActionHasActiveStream == true,
              !isSessionApprovalBypassEnabled,
              let prompt = approvalPendingBySession[sessionID]
        else {
            if approvalPrompt?.sessionID == sessionID {
                approvalPrompt = nil
            }
            return
        }

        approvalPrompt = prompt
    }

    private func renderClarificationPromptForCurrentSession() {
        guard let sessionID = delegate?.pendingActionSessionID else {
            clarificationPrompt = nil
            return
        }

        guard delegate?.pendingActionHasActiveStream == true,
              let prompt = clarificationPendingBySession[sessionID]
        else {
            if clarificationPrompt?.sessionID == sessionID {
                clarificationPrompt = nil
            }
            return
        }

        clarificationPrompt = prompt
    }
}
