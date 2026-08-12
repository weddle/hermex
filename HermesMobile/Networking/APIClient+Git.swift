import Foundation

// Workspace Git calls, retargeted to the native Hermes Agent dashboard git
// router (`web_routers/git.py`). The native surface is PATH-based — every
// request carries the working-directory path (`path`) the server git runs in —
// scoped per chat session via the session's resolved workspace path.
extension APIClient {
    func gitStatus(path: String) async throws -> GitStatusResponse {
        try await send(endpoint: .gitStatus(path: path), method: "GET")
    }

    func gitBranches(path: String) async throws -> GitBranchesResponse {
        try await send(endpoint: .gitBranches(path: path), method: "GET")
    }

    func gitDiff(path: String, file: String, kind: String = "unstaged") async throws -> GitDiffResponse {
        try await send(
            endpoint: .gitDiff(path: path, file: file, kind: kind),
            method: "GET"
        )
    }

    func gitBranchSwitch(path: String, branch: String) async throws -> GitBranchSwitchResponse {
        try await send(
            endpoint: .gitBranchSwitch,
            method: "POST",
            body: GitBranchSwitchRequest(path: path, branch: branch)
        )
    }

    func gitStage(path: String, file: String?) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitStage,
            method: "POST",
            body: GitFileRequest(path: path, file: file)
        )
    }

    func gitUnstage(path: String, file: String?) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitUnstage,
            method: "POST",
            body: GitFileRequest(path: path, file: file)
        )
    }

    func gitRevert(path: String, file: String?) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitRevert,
            method: "POST",
            body: GitFileRequest(path: path, file: file)
        )
    }

    func gitCommit(path: String, message: String, push: Bool = false) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitCommit,
            method: "POST",
            body: GitCommitBody(path: path, message: message, push: push)
        )
    }

    func gitPush(path: String) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitPush,
            method: "POST",
            body: GitPathRequest(path: path)
        )
    }
}

private struct GitPathRequest: Encodable {
    let path: String
}

private struct GitFileRequest: Encodable {
    let path: String
    let file: String?
}

private struct GitCommitBody: Encodable {
    let path: String
    let message: String
    let push: Bool
}

private struct GitBranchSwitchRequest: Encodable {
    let path: String
    let branch: String
}
