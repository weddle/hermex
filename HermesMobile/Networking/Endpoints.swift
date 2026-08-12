import Foundation

enum Endpoint {
    case health
    case authStatus
    case login
    case logout
    case wsTicket
    case sessions(includeArchived: Bool = false, archivedLimit: Int? = nil)
    case sessionsSearch(query: String, content: Bool, depth: Int)
    case session(id: String, includeMessages: Bool, messageLimit: Int?, messageBefore: Int?, expandRenderable: Bool = false)
    case sessionStatus(id: String)
    case newSession
    case renameSession
    case deleteSession
    case pinSession
    case archiveSession
    case branchSession
    case compressSession
    case undoSession
    case retrySession
    case truncateSession
    case updateSession
    case moveSession
    case sessionYolo(sessionID: String?)
    case exportSession(sessionID: String, format: SessionExportFormat)
    case chatStreamStatus(streamID: String)
    case chatSteer
    case workspaceRoots
    case workspaceSuggestions(prefix: String)
    case directoryList(path: String?)
    case file(path: String)
    case rawFile(path: String)
    case media(path: String)
    case gitStatus(path: String)
    case gitBranches(path: String)
    case gitDiff(path: String, file: String, kind: String)
    case gitBranchSwitch
    case gitStage
    case gitUnstage
    case gitRevert
    case gitCommit
    case gitPush
    case models
    case modelsLive
    case commands
    case defaultModel
    case reasoning(model: String? = nil, provider: String? = nil)
    case personalities
    case setPersonality
    case profiles
    case switchProfile
    case createProfile
    case providers
    case settings
    case crons
    case cronCreate
    case cronUpdate
    case cronDelete
    case cronRun
    case cronPause
    case cronResume
    case cronStatus(jobID: String?)
    case cronOutput(jobID: String, limit: Int?)
    case cronDeliveryOptions
    case memory
    case memoryWrite
    case skills
    case skillContent(name: String, file: String?)
    case toggleSkill
    case upload

    var path: String {
        switch self {
        case .health:
            return "/api/status"
        case .authStatus:
            return "/api/auth/providers"
        case .login:
            return "/auth/password-login"
        case .logout:
            return "/auth/logout"
        case .wsTicket:
            return "/api/auth/ws-ticket"
        case .sessions:
            return "/api/sessions"
        case .sessionsSearch:
            return "/api/sessions/search"
        case .session:
            return "/api/session"
        case .sessionStatus:
            return "/api/session/status"
        case .newSession:
            return "/api/session/new"
        case .renameSession:
            return "/api/session/rename"
        case .deleteSession:
            return "/api/session/delete"
        case .pinSession:
            return "/api/session/pin"
        case .archiveSession:
            return "/api/session/archive"
        case .branchSession:
            return "/api/session/branch"
        case .compressSession:
            return "/api/session/compress"
        case .undoSession:
            return "/api/session/undo"
        case .retrySession:
            return "/api/session/retry"
        case .truncateSession:
            return "/api/session/truncate"
        case .updateSession:
            return "/api/session/update"
        case .moveSession:
            return "/api/session/move"
        case .sessionYolo:
            return "/api/session/yolo"
        case .exportSession:
            return "/api/session/export"
        case .chatStreamStatus:
            return "/api/chat/stream/status"
        case .chatSteer:
            return "/api/chat/steer"
        case .workspaceRoots:
            return "/api/fs/default-cwd"
        case .workspaceSuggestions:
            return "/api/fs/list"
        case .directoryList:
            return "/api/fs/list"
        case .file:
            return "/api/fs/read-text"
        case .rawFile, .media:
            return "/api/files/download"
        case .gitStatus:
            return "/api/git/status"
        case .gitBranches:
            return "/api/git/branches"
        case .gitDiff:
            return "/api/git/review/diff"
        case .gitBranchSwitch:
            return "/api/git/branch/switch"
        case .gitStage:
            return "/api/git/review/stage"
        case .gitUnstage:
            return "/api/git/review/unstage"
        case .gitRevert:
            return "/api/git/review/revert"
        case .gitCommit:
            return "/api/git/review/commit"
        case .gitPush:
            return "/api/git/review/push"
        case .models:
            return "/api/models"
        case .modelsLive:
            return "/api/models/live"
        case .commands:
            return "/api/commands"
        case .defaultModel:
            return "/api/default-model"
        case .reasoning:
            return "/api/reasoning"
        case .personalities:
            return "/api/personalities"
        case .setPersonality:
            return "/api/personality/set"
        case .profiles:
            return "/api/profiles"
        case .switchProfile:
            return "/api/profile/switch"
        case .createProfile:
            return "/api/profile/create"
        case .providers:
            return "/api/providers"
        case .settings:
            return "/api/settings"
        case .crons:
            return "/api/crons"
        case .cronCreate:
            return "/api/crons/create"
        case .cronUpdate:
            return "/api/crons/update"
        case .cronDelete:
            return "/api/crons/delete"
        case .cronRun:
            return "/api/crons/run"
        case .cronPause:
            return "/api/crons/pause"
        case .cronResume:
            return "/api/crons/resume"
        case .cronStatus:
            return "/api/crons/status"
        case .cronOutput:
            return "/api/crons/output"
        case .cronDeliveryOptions:
            return "/api/crons/delivery-options"
        case .memory:
            return "/api/memory"
        case .memoryWrite:
            return "/api/memory/write"
        case .skills:
            return "/api/skills"
        case .skillContent:
            return "/api/skills/content"
        case .toggleSkill:
            return "/api/skills/toggle"
        case .upload:
            return "/api/upload"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case let .sessions(includeArchived, archivedLimit):
            // Opt-in (issue #17): the server's default response excludes archived
            // rows, so the main list request stays byte-identical when off.
            // `archived_limit` only means something alongside `include_archived=1`
            // (`_query_positive_int` in upstream routes.py), so it is only sent then.
            guard includeArchived else { return [] }

            var items = [URLQueryItem(name: "include_archived", value: "1")]
            if let archivedLimit {
                items.append(URLQueryItem(name: "archived_limit", value: "\(archivedLimit)"))
            }
            return items
        case let .sessionsSearch(query, content, depth):
            return [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "content", value: content ? "1" : "0"),
                URLQueryItem(name: "depth", value: "\(depth)")
            ]
        case let .session(id, includeMessages, messageLimit, messageBefore, expandRenderable):
            var items = [
                URLQueryItem(name: "session_id", value: id),
                URLQueryItem(name: "messages", value: includeMessages ? "1" : "0")
            ]

            if let messageLimit {
                items.append(URLQueryItem(name: "msg_limit", value: "\(messageLimit)"))
            }

            if let messageBefore {
                items.append(URLQueryItem(name: "msg_before", value: "\(messageBefore)"))
            }

            // Opt-in (upstream #3790): on cold load only, ask the server to widen the
            // window until it holds ~msg_limit *renderable* rows so tool-heavy sessions
            // don't open showing 1–2 bubbles. Omitted when false; older servers ignore it.
            if expandRenderable {
                items.append(URLQueryItem(name: "expand_renderable", value: "1"))
            }

            return items
        case let .sessionStatus(id):
            return [URLQueryItem(name: "session_id", value: id)]
        case let .chatStreamStatus(streamID):
            return [URLQueryItem(name: "stream_id", value: streamID)]
        case let .sessionYolo(sessionID):
            guard let sessionID else { return [] }
            return [URLQueryItem(name: "session_id", value: sessionID)]
        case let .exportSession(sessionID, format):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "format", value: format.rawValue)
            ]
        case let .directoryList(path):
            guard let path, !path.isEmpty else { return [] }
            return [URLQueryItem(name: "path", value: path)]
        case let .workspaceSuggestions(prefix):
            return [URLQueryItem(name: "path", value: prefix)]
        case let .file(path), let .rawFile(path):
            return [URLQueryItem(name: "path", value: path)]
        case let .media(path):
            return [URLQueryItem(name: "path", value: path)]
        case let .gitStatus(path),
            let .gitBranches(path):
            return [URLQueryItem(name: "path", value: path)]
        case let .gitDiff(path, file, kind):
            return [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "file", value: file),
                URLQueryItem(name: "scope", value: "uncommitted"),
                URLQueryItem(name: "staged", value: kind == "staged" ? "true" : "false")
            ]
        case let .cronStatus(jobID):
            guard let jobID else { return [] }
            return [URLQueryItem(name: "job_id", value: jobID)]
        case let .cronOutput(jobID, limit):
            var items = [URLQueryItem(name: "job_id", value: jobID)]
            if let limit {
                items.append(URLQueryItem(name: "limit", value: "\(limit)"))
            }
            return items
        case let .reasoning(model, provider):
            var items: [URLQueryItem] = []
            if let model, !model.isEmpty {
                items.append(URLQueryItem(name: "model", value: model))
            }
            if let provider, !provider.isEmpty {
                items.append(URLQueryItem(name: "provider", value: provider))
            }
            return items
        case let .skillContent(name, file):
            var items = [URLQueryItem(name: "name", value: name)]
            if let file {
                items.append(URLQueryItem(name: "file", value: file))
            }
            return items
        default:
            return []
        }
    }

    func url(relativeTo baseURL: URL) -> URL {
        let url = baseURL.appending(path: path)
        guard !queryItems.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }
}
