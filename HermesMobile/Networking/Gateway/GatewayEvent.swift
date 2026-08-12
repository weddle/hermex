//
//  GatewayEvent.swift
//  HermesMobile
//
//  Stream events emitted by the Hermes Agent gateway transport. The cases are
//  the subset Hermex actually renders; unknown event types map to `.ignored`.
//
//  Adapted from hermes-conduit (MIT License), Conduit/Services/HermesClient.swift
//  (enum StreamEvent) for the Hermex fork's native dashboard transport.
//

import Foundation

/// Runtime fields returned by `session.resume` and `session.info`.
/// `running` is optional only so the client can identify an outdated gateway.
struct GatewayRuntimeSnapshot {
    let running: Bool?
    let status: String?
    let model: String?
    let provider: String?
    let cwd: String?
    let contextPercent: Double?
    let contextUsed: Int?
    let contextMax: Int?
    let activeAgents: Int?
    let reasoningEffort: String?
    let fast: Bool?
    /// Per-session approval bypass, overriding the profile default while the
    /// conversation is active without changing `approvals.mode` itself.
    let yolo: Bool?
    let approvalsMode: String?
    let inflight: GatewayValue?
    let queued: GatewayValue?

    /// `session.resume` may include an in-flight or queued projection that is
    /// newer than the persisted transcript. Keep that projection for a live
    /// turn; the REST transcript is otherwise the richer history view.
    var hasLiveProjection: Bool {
        [inflight, queued].contains { value in
            guard let value else { return false }
            switch value {
            case .null: return false
            case .bool(let flag): return flag
            case .number(let number): return number != 0 && !number.isNaN
            case .string(let text): return !text.isEmpty
            case .array, .object: return true
            }
        }
    }

    /// The in-flight projection holds text not yet persisted. A resumed live
    /// turn needs this prefix before accepting new token deltas.
    var inflightAssistantText: String {
        guard let object = inflight?.objectValue else { return "" }
        return ["assistant", "text", "content"]
            .compactMap { object[$0]?.stringValue }
            .first { !$0.isEmpty } ?? ""
    }

    init(
        object: [String: GatewayValue],
        inflight: GatewayValue? = nil,
        queued: GatewayValue? = nil
    ) {
        running = object["running"]?.boolValue
        status = object["status"]?.stringValue
        model = object["model"]?.stringValue
        provider = object["provider"]?.stringValue
        cwd = object["cwd"]?.stringValue
        contextPercent = object["context_percent"]?.doubleValue
        contextUsed = object["context_used"]?.intValue
        contextMax = object["context_max"]?.intValue
        activeAgents = object["active_agents"]?.intValue ?? object["active_subagents"]?.intValue
        reasoningEffort = object["reasoning_effort"]?.stringValue
            ?? object["reasoning"]?.stringValue
        fast = object["fast"]?.boolValue
            ?? object["fast_mode"]?.boolValue
        yolo = object["yolo"]?.boolValue
        approvalsMode = object["approvals_mode"]?.stringValue
            ?? object["approval_mode"]?.stringValue
            ?? object["approvals"]?.objectValue?["mode"]?.stringValue
        self.inflight = inflight
        self.queued = queued
    }
}

struct GatewayResumeResult {
    let sessionId: String
    let messages: [GatewayChatMessage]
    let snapshot: GatewayRuntimeSnapshot
}

/// A lightweight message returned by `session.resume`, mapped at the
/// coordinator boundary into Hermex's concrete `ChatMessage` model.
struct GatewayChatMessage {
    let id: String?
    let role: String
    let content: String
    let reasoningContent: String?
    let toolCalls: [GatewayToolCall]?
}

struct GatewayToolCall {
    let id: String?
    let name: String?
    let arguments: String?
    let output: String?
}

struct GatewayBranchMessage {
    let role: String
    let content: String
}

/// Result of the newer active-turn correction RPC. `queued` is still a
/// successful delivery: Hermes accepted the correction while the agent was in
/// its short turn-build window and will run it next.
enum GatewayRedirectOutcome: Equatable {
    case redirected
    case queued
    case rejected

    init(gatewayStatus: String?) {
        switch gatewayStatus?.lowercased() {
        case "redirected": self = .redirected
        case "queued": self = .queued
        default: self = .rejected
        }
    }
}

/// Stream events emitted by `HermesGatewayClient` and consumed by the chat
/// coordinator. `ignored` carries no payload so unknown events are neither
/// logged with contents nor matched on.
enum GatewayEvent {
    case messageDelta(sessionID: String, text: String)
    case reasoningDelta(sessionID: String, text: String)
    case messageComplete(sessionID: String, messageID: String?, content: String?, reasoning: String?)
    case messageError(sessionID: String, message: String)
    case messageInterrupted(sessionID: String)
    case sessionBusy(sessionID: String, busy: Bool)
    case sessionInfo(sessionID: String, snapshot: GatewayRuntimeSnapshot)
    case sessionTitle(sessionID: String, title: String)
    case toolStarted(sessionID: String, name: String, input: GatewayValue?)
    case toolCompleted(sessionID: String, name: String, output: GatewayValue?)
    case clarification(sessionID: String, requestID: String, question: String, choices: [(label: String, value: String)])
    case approval(sessionID: String, command: String, description: String, choices: [String]?)
    case context(sessionID: String, percent: Double, used: Int, max: Int)
    case model(sessionID: String, model: String, provider: String)
    case ignored
}
