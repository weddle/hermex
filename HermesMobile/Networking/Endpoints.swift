import Foundation

enum Endpoint {
    case health
    case authStatus
    case login
    case logout
    case wsTicket
    case sessions(includeArchived: Bool = false, limit: Int? = 100)
    case sessionsSearch(query: String, limit: Int? = 20)
    case session(id: String)
    case sessionMessages(id: String, limit: Int?, offset: Int?, order: String?)
    case sessionPatch(id: String)
    case deleteSession(id: String)
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
    case cronUpdate(jobID: String)
    case cronDelete(jobID: String)
    case cronRun(jobID: String)
    case cronPause(jobID: String)
    case cronResume(jobID: String)
    case cronRuns(jobID: String, limit: Int?)
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
        case let .session(id):
            return "/api/sessions/\(id)"
        case let .sessionMessages(id, _, _, _):
            return "/api/sessions/\(id)/messages"
        case let .sessionPatch(id):
            return "/api/sessions/\(id)"
        case let .deleteSession(id):
            return "/api/sessions/\(id)"
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
            return "/api/cron/jobs"
        case .cronCreate:
            return "/api/cron/jobs"
        case let .cronUpdate(jobID):
            return "/api/cron/jobs/\(jobID)"
        case let .cronDelete(jobID):
            return "/api/cron/jobs/\(jobID)"
        case let .cronRun(jobID):
            return "/api/cron/jobs/\(jobID)/trigger"
        case let .cronPause(jobID):
            return "/api/cron/jobs/\(jobID)/pause"
        case let .cronResume(jobID):
            return "/api/cron/jobs/\(jobID)/resume"
        case let .cronRuns(jobID, _):
            return "/api/cron/jobs/\(jobID)/runs"
        case .cronDeliveryOptions:
            return "/api/cron/delivery-targets"
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
        case let .sessions(includeArchived, limit):
            var items = [URLQueryItem(name: "archived", value: includeArchived ? "include" : "exclude")]
            if let limit {
                items.append(URLQueryItem(name: "limit", value: "\(limit)"))
            }
            return items
        case let .sessionsSearch(query, limit):
            var items = [URLQueryItem(name: "q", value: query)]
            if let limit {
                items.append(URLQueryItem(name: "limit", value: "\(limit)"))
            }
            return items
        case let .sessionMessages(_, limit, offset, order):
            var items: [URLQueryItem] = []
            if let limit {
                items.append(URLQueryItem(name: "limit", value: "\(limit)"))
            }
            if let offset {
                items.append(URLQueryItem(name: "offset", value: "\(offset)"))
            }
            if let order {
                items.append(URLQueryItem(name: "order", value: order))
            }
            return items
        case let .chatStreamStatus(streamID):
            return [URLQueryItem(name: "stream_id", value: streamID)]
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
        case let .cronRuns(jobID, limit):
            var items: [URLQueryItem] = []
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
