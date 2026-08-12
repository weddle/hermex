import Foundation

extension APIClient {
    /// The native dashboard's default working directory (`GET /api/fs/default-cwd`),
    /// wrapped in Hermex's `WorkspacesResponse` shape so the composer's workspace
    /// picker keeps its existing contract. The native payload is `{cwd, branch}`.
    func workspaces() async throws -> WorkspacesResponse {
        struct FsDefaultCwdResponse: Decodable {
            let cwd: String?
        }
        let response: FsDefaultCwdResponse = try await send(endpoint: .workspaceRoots, method: "GET")
        let path = response.cwd
        let root = path.map { WorkspaceRoot(path: $0, name: nil) }
        return WorkspacesResponse(
            workspaces: root.map { [$0] },
            last: path
        )
    }

    /// Directory-style path suggestions (`GET /api/fs/list?path=<prefix>`), mapped
    /// to the composer's suggestion-list contract: entries are returned as absolute
    /// paths so picking `/workspace` and `/models` autocomplete work identically.
    func workspaceSuggestions(prefix: String) async throws -> WorkspaceSuggestionsResponse {
        let listing: DirectoryListResponse = try await send(
            endpoint: .workspaceSuggestions(prefix: prefix),
            method: "GET"
        )
        let suggestions = (listing.entries ?? []).compactMap(\.path)
        return WorkspaceSuggestionsResponse(suggestions: suggestions, prefix: prefix)
    }

    /// Lists a directory (`GET /api/fs/list?path=`). An empty/nil path resolves to
    /// the dashboard's default working directory.
    func directoryList(path: String? = nil) async throws -> DirectoryListResponse {
        try await send(endpoint: .directoryList(path: path), method: "GET")
    }

    /// Reads a text file (`GET /api/fs/read-text?path=`).
    func file(path: String) async throws -> FileResponse {
        try await send(endpoint: .file(path: path), method: "GET")
    }

    /// Downloads a managed file's raw bytes (`GET /api/files/download?path=`).
    func rawFileData(path: String) async throws -> Data {
        try await sendDataReturningResponse(
            endpoint: .rawFile(path: path),
            method: "GET",
            encodedBody: nil,
            accept: "*/*"
        ).0
    }

    /// Downloads raw media bytes (`GET /api/files/download?path=`), identical wire
    /// contract to `rawFileData` but used by the transcript media loader.
    func mediaData(path: String) async throws -> Data {
        try await sendDataReturningResponse(
            endpoint: .media(path: path),
            method: "GET",
            encodedBody: nil,
            accept: "*/*"
        ).0
    }

    func remoteTranscriptMediaData(from url: URL) async throws -> Data {
        if Self.isSameOrigin(url, as: baseURL) {
            return try await downloadData(from: url, using: session, mapsUnauthorized: true)
        }

        return try await downloadData(from: url, using: publicMediaSession, mapsUnauthorized: false)
    }
}
