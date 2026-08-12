//
//  StreamEventParser.swift
//  HermesMobile
//
//  Pure-function parser that maps gateway `event` notifications into the
//  `GatewayEvent` cases Hermex renders, so the gateway-to-app boundary can be
//  unit-tested without a live WebSocket.
//
//  Adapted from hermes-conduit (MIT License),
//  Conduit/Services/StreamEventParser.swift for the Hermex fork.
//

import Foundation

enum StreamEventParser {
    static func parse(params: GatewayValue) -> GatewayEvent? {
        guard let obj = params.objectValue else { return nil }
        let type = obj["type"]?.stringValue ?? ""
        let sessionID = obj["session_id"]?.stringValue ?? ""
        let payload = obj["payload"]?.objectValue

        switch type {
        case "message.delta":
            let text = payload?["text"]?.stringValue ?? obj["text"]?.stringValue ?? ""
            if text.isEmpty { return nil }
            return .messageDelta(sessionID: sessionID, text: text)

        case "reasoning.delta", "message.reasoning", "message.reasoning.delta":
            let text: String
            if let reasoning = payload?["reasoning"]?.stringValue {
                text = reasoning
            } else if let reasoningContent = payload?["reasoning_content"]?.stringValue {
                text = reasoningContent
            } else if let payloadText = payload?["text"]?.stringValue {
                text = payloadText
            } else if let content = payload?["content"]?.stringValue {
                text = content
            } else if let reasoning = obj["reasoning"]?.stringValue {
                text = reasoning
            } else {
                text = obj["text"]?.stringValue ?? ""
            }
            if text.isEmpty { return nil }
            return .reasoningDelta(sessionID: sessionID, text: text)

        case "message.complete":
            let messageID = payload?["message_id"]?.stringValue
                ?? payload?["id"]?.stringValue
                ?? payload?["message"]?.objectValue?["id"]?.stringValue
                ?? obj["message_id"]?.stringValue
                ?? obj["id"]?.stringValue
            let content = payload?["content"]?.stringValue
                ?? payload?["text"]?.stringValue
            let reasoning = payload?["reasoning"]?.stringValue
            return .messageComplete(sessionID: sessionID, messageID: messageID, content: content, reasoning: reasoning)

        case "error":
            return .messageError(sessionID: sessionID, message: payload?["message"]?.stringValue ?? "Hermes reported an error.")

        case "message.interrupted", "session.interrupted":
            return .messageInterrupted(sessionID: sessionID)

        case "session.busy":
            let busy = payload?["busy"]?.boolValue ?? false
            return .sessionBusy(sessionID: sessionID, busy: busy)

        case "session.info":
            return .sessionInfo(sessionID: sessionID, snapshot: GatewayRuntimeSnapshot(object: payload ?? [:]))

        case "session.title":
            let title = payload?["title"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return .sessionTitle(sessionID: sessionID, title: title)

        case "tool.start", "tool_call":
            let name = payload?["name"]?.stringValue ?? ""
            let input = payload?["input"]
                ?? payload?["arguments"]
                ?? payload?["args"]
            return .toolStarted(sessionID: sessionID, name: name, input: input)

        case "tool.complete", "tool_result":
            let name = payload?["name"]?.stringValue ?? ""
            let output = payload?["output"] ?? payload?["result"]
            return .toolCompleted(sessionID: sessionID, name: name, output: output)

        case "clarify", "clarify.request":
            guard let payload else { return nil }
            let requestID = payload["request_id"]?.stringValue ?? ""
            let question = payload["question"]?.stringValue ?? ""
            let choices: [(label: String, value: String)] = (payload["choices"]?.arrayValue ?? []).compactMap { choice in
                let object = choice.objectValue ?? [:]
                guard let label = object["label"]?.stringValue, !label.isEmpty else { return nil }
                return (label: label, value: object["value"]?.stringValue ?? label)
            }
            guard !requestID.isEmpty, !question.isEmpty else { return nil }
            return .clarification(sessionID: sessionID, requestID: requestID, question: question, choices: choices)

        case "approval.request":
            guard let payload else { return nil }
            let command = payload["command"]?.stringValue ?? ""
            let description = payload["description"]?.stringValue
                ?? payload["message"]?.stringValue
                ?? command
            let commandText = command.isEmpty ? description : command
            let choices = payload["choices"]?.arrayValue?.compactMap { $0.stringValue }
            return .approval(sessionID: sessionID, command: commandText, description: description, choices: choices)

        case "context.update", "session.context":
            let percent = payload?["context_percent"]?.doubleValue ?? 0
            let used = payload?["context_used"]?.intValue ?? 0
            let max = payload?["context_max"]?.intValue ?? 0
            return .context(sessionID: sessionID, percent: percent, used: used, max: max)

        case "model.update":
            let model = payload?["model"]?.stringValue ?? ""
            let provider = payload?["provider"]?.stringValue ?? ""
            return .model(sessionID: sessionID, model: model, provider: provider)

        default:
            return .ignored
        }
    }
}
