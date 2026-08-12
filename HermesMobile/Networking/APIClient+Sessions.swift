import Foundation

// MARK: - Native dashboard DTOs

/// A session row as returned by `GET /api/sessions`, `GET /api/sessions/search`,
/// and `GET /api/sessions/{id}`. Native rows are the `sessions` table columns
/// (snake_case) with the heavy `system_prompt`/`model_config` fields stripped on
/// list routes. Every field is optional/lossy so backend shape changes never
/// break decoding.
private struct NativeSessionRow: Decodable, Equatable {
    let id: String?
    let sessionId: String?
    let sessionKey: String?
    let title: String?
    let model: String?
    let modelProvider: String?
    let messageCount: Int?
    let startedAt: Double?
    let updatedAt: Double?
    let lastActivityAt: Double?
    let pinned: Bool?
    let archived: Bool?
    let projectId: String?
    let profile: String?
    let profileName: String?
    let cwd: String?
    let worktreePath: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCostUsd: Double?
    let parentSessionId: String?
    let relationshipType: String?
    let source: String?
    let sourceTag: String?
    let isActive: Bool?

    // NOTE: the shared `APIClient` decoder uses `.convertFromSnakeCase`, which
    // re-derives every CodingKey's lookup key from its camelCase spelling. An
    // explicit snake_case raw value like `case sessionId = "session_id"` is
    // re-converted to `sessionId` and then silently fails to match the wire
    // key. So these keys MUST keep the auto camelCase spelling (the strategy
    // maps `session_id` → `sessionId`), with `estimatedCostUsd` matching the
    // `estimated_cost_usd` wire field. Do not "fix" them back to explicit
    // snake_case raw values.
    enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case sessionKey
        case title
        case model
        case modelProvider
        case messageCount
        case startedAt
        case updatedAt
        case lastActivityAt
        case pinned
        case archived
        case projectId
        case profile
        case profileName
        case cwd
        case worktreePath
        case inputTokens
        case outputTokens
        case estimatedCostUsd
        case parentSessionId
        case relationshipType
        case source
        case sourceTag
        case isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        sessionKey = container.decodeLossyStringIfPresent(forKey: .sessionKey)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        modelProvider = container.decodeLossyStringIfPresent(forKey: .modelProvider)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        startedAt = container.decodeLossyDoubleIfPresent(forKey: .startedAt)
        updatedAt = container.decodeLossyDoubleIfPresent(forKey: .updatedAt)
        lastActivityAt = container.decodeLossyDoubleIfPresent(forKey: .lastActivityAt)
        pinned = container.decodeLossyBoolIfPresent(forKey: .pinned)
        archived = container.decodeLossyBoolIfPresent(forKey: .archived)
        projectId = container.decodeLossyStringIfPresent(forKey: .projectId)
        profile = container.decodeLossyStringIfPresent(forKey: .profile)
        profileName = container.decodeLossyStringIfPresent(forKey: .profileName)
        cwd = container.decodeLossyStringIfPresent(forKey: .cwd)
        worktreePath = container.decodeLossyStringIfPresent(forKey: .worktreePath)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        estimatedCostUsd = container.decodeLossyDoubleIfPresent(forKey: .estimatedCostUsd)
        parentSessionId = container.decodeLossyStringIfPresent(forKey: .parentSessionId)
        relationshipType = container.decodeLossyStringIfPresent(forKey: .relationshipType)
        source = container.decodeLossyStringIfPresent(forKey: .source)
        sourceTag = container.decodeLossyStringIfPresent(forKey: .sourceTag)
        isActive = container.decodeLossyBoolIfPresent(forKey: .isActive)
    }

    /// The durable id the app holds for REST resume/detail and gateway resume.
    /// Native rows usually key on `id`; search results surface the compression-tip
    /// id as `session_id`, so accept either.
    var resolvedSessionID: String? {
        nonEmptyText(sessionId) ?? nonEmptyText(id)
    }

    var resolvedTitle: String? { nonEmptyText(title) }
    var resolvedWorkspace: String? { nonEmptyText(cwd) ?? nonEmptyText(worktreePath) }
    var resolvedProfile: String? { nonEmptyText(profileName) ?? nonEmptyText(profile) }

    func summary() -> SessionSummary {
        let resolvedID = resolvedSessionID
        let resolvedTitle = self.resolvedTitle
        let resolvedWorkspace = self.resolvedWorkspace
        let resolvedProfile = self.resolvedProfile
        return SessionSummary(
            sessionId: resolvedID,
            title: resolvedTitle,
            workspace: resolvedWorkspace,
            model: nonEmptyText(model),
            modelProvider: nonEmptyText(modelProvider),
            messageCount: messageCount,
            createdAt: startedAt ?? lastActivityAt,
            updatedAt: updatedAt ?? lastActivityAt,
            lastMessageAt: lastActivityAt,
            pinned: pinned,
            archived: archived,
            projectId: nonEmptyText(projectId),
            profile: resolvedProfile,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCostUsd,
            activeStreamId: nil,
            isStreaming: isActive == true ? nil : nil,
            isCliSession: nil,
            userMessageCount: nil,
            hasPendingUserMessage: nil,
            pendingStartedAt: nil,
            worktreePath: resolvedWorkspace,
            sourceTag: nonEmptyText(sourceTag) ?? nonEmptyText(source),
            rawSource: nonEmptyText(source),
            sessionSource: nonEmptyText(source),
            sourceLabel: nonEmptyText(source),
            parentSessionId: nonEmptyText(parentSessionId),
            relationshipType: nonEmptyText(relationshipType),
            readOnly: nil,
            isReadOnly: nil,
            matchType: nil
        )
    }
}

/// Paginated list envelope `GET /api/sessions`.
private struct NativeSessionsResponse: Decodable {
    let sessions: [NativeSessionRow]?
    let total: Int?
}

/// Search envelope `GET /api/sessions/search` — native returns `results`, each
/// row carries the compression-tip `session_id`, `title`, timestamps, and a
/// `snippet` instead of a nested message payload.
private struct NativeSessionSearchResponse: Decodable {
    let results: [NativeSessionRow]?

    enum CodingKeys: String, CodingKey {
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try? container.decodeIfPresent([NativeSessionRow].self, forKey: .results)
    }
}

/// Messages envelope `GET /api/sessions/{id}/messages`.
private struct NativeSessionMessagesResponse: Decodable {
    let sessionId: String?
    let messages: [ChatMessage]?
    let pagination: NativeMessagesPagination?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case messages
        case pagination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        messages = (try? container.decodeIfPresent([ChatMessage].self, forKey: .messages))
            ?? Self.decodeTolerantMessages(from: container)
        pagination = try? container.decodeIfPresent(NativeMessagesPagination.self, forKey: .pagination)
    }

    private static func decodeTolerantMessages(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [ChatMessage]? {
        guard let values = try? container.decodeIfPresent([JSONValue].self, forKey: .messages) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return values.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(ChatMessage.self, from: data)
        }
    }
}

private struct NativeMessagesPagination: Decodable {
    let limit: Int?
    let offset: Int?
    let order: String?
    let returned: Int?
}

/// Native `README` on message pagination: `order` is `oldest|latest`; an omitted
/// limit defaults to the latest 500 in chronological order. Older pages use
/// `offset` against insertion order.
private enum NativeMessagesOrder {
    static let oldest = "oldest"
    static let latest = "latest"
}

extension APIClient {
    /// Fetches the visible (non-archived) session list from the native dashboard.
    /// `includeArchived` flips the `archived=include` filter so the archived
    /// settings panel can list archived rows; `limit` (≤100) controls the page.
    func sessions() async throws -> SessionsResponse {
        try await sessions(includeArchived: false, archivedLimit: nil)
    }

    func sessions(includeArchived: Bool = false, archivedLimit: Int? = nil) async throws -> SessionsResponse {
        // `archived_limit` is a WebUI-only knob with no native equivalent; the
        // native list always pages by `archived` + `limit`.
        let limit = min(max(archivedLimit ?? 100, 1), 100)
        let native: NativeSessionsResponse = try await send(
            endpoint: .sessions(includeArchived: includeArchived, limit: limit),
            method: "GET"
        )
        let summaries = (native.sessions ?? []).map { $0.summary() }
        return SessionsResponse(
            sessions: summaries,
            cliCount: nil,
            archivedCount: native.total,
            serverTime: nil,
            serverTz: nil
        )
    }

    func searchSessions(query: String, content: Bool = true, depth: Int = 5) async throws -> SessionSearchResponse {
        // Native FTS5 search ignores `content`/`depth`; the query text and page
        // size are the only parameters.
        let native: NativeSessionSearchResponse = try await send(
            endpoint: .sessionsSearch(query: query, limit: 20),
            method: "GET"
        )
        let summaries = (native.results ?? []).map { $0.summary() }
        return SessionSearchResponse(
            sessions: summaries,
            query: query,
            count: summaries.count
        )
    }

    /// Loads a single session's metadata plus (optionally) its transcript.
    ///
    /// The native dashboard splits these: `GET /api/sessions/{id}` returns the
    /// metadata row and `GET /api/sessions/{id}/messages` returns the transcript
    /// with explicit pagination. `messageBefore` maps to an `offset` (number of
    /// messages to page past, oldest-first).
    func session(
        id: String,
        includeMessages: Bool = true,
        messageLimit: Int? = 50,
        messageBefore: Int? = nil,
        expandRenderable: Bool = false
    ) async throws -> SessionResponse {
        let native: NativeSessionRow = try await send(
            endpoint: .session(id: id),
            method: "GET"
        )
        let summary = native.summary()
        let detail = SessionDetail(native: native, messages: nil, messagesOffset: nil, messagesTruncated: nil)
        var appliedDetail = detail
        appliedDetail = SessionDetail(native: native, messages: nil, messagesOffset: nil, messagesTruncated: nil)

        guard includeMessages else {
            return SessionResponse(session: appliedDetail)
        }

        let messagesResponse: NativeSessionMessagesResponse = try await send(
            endpoint: .sessionMessages(
                id: id,
                limit: messageLimit,
                offset: messageBefore,
                order: messageBefore == nil ? nil : NativeMessagesOrder.oldest
            ),
            method: "GET"
        )

        let messages = messagesResponse.messages ?? []
        let returned = messagesResponse.pagination?.returned
        let totalCount = summary.messageCount ?? returned
        let offset = messageBefore
        // A page shorter than the requested size (or an explicit offset page)
        // marks the transcript truncated so "load earlier" stays available.
        let isTruncated = offset.map { $0 > 0 } ?? (messageLimit != nil && messages.count == messageLimit)
        let resolvedOffset = offset
            ?? (isTruncated == true ? (totalCount.map { max(0, $0 - messages.count) }) : nil)

        return SessionResponse(
            session: SessionDetail(
                native: native,
                messages: messages,
                messagesOffset: resolvedOffset,
                messagesTruncated: isTruncated
            )
        )
    }

    /// Creates a transient gateway draft. Native Hermes persists the durable
    /// row only when the first prompt is submitted, so the returned detail is
    /// built directly from `session.create`; no REST read can succeed yet.
    func createSession(workspace: String?, model: String?, modelProvider: String?, profile: String?) async throws -> SessionResponse {
        let created = try await createGatewayDraft(
            workspace: workspace,
            model: model,
            modelProvider: modelProvider,
            profile: profile
        )
        return SessionResponse(session: SessionDetail(
            sessionId: created.storedSessionID,
            title: "Untitled Session",
            workspace: created.cwd ?? workspace,
            model: created.model ?? model,
            modelProvider: created.provider ?? modelProvider,
            messageCount: 0,
            archived: false,
            profile: profile,
            worktreePath: created.cwd ?? workspace
        ))
    }

    /// Renames a session. Native REST PATCH `/api/sessions/{id}` with `{title}`.
    func renameSession(id: String, title: String) async throws -> SessionMutationResponse {
        let patch = SessionPatchRequest(title: title, archived: nil, pinned: nil)
        let native: NativeSessionRow = try await send(
            endpoint: .sessionPatch(id: id),
            method: "PATCH",
            body: patch
        )
        return SessionMutationResponse(
            ok: true,
            session: native.summary(),
            error: nil
        )
    }

    /// Deletes a session. Native DELETE `/api/sessions/{id}` is idempotent.
    func deleteSession(id: String) async throws -> SessionMutationResponse {
        let result: NativeDeleteSessionResponse = try await send(
            endpoint: .deleteSession(id: id),
            method: "DELETE"
        )
        return SessionMutationResponse(
            ok: result.ok ?? true,
            session: nil,
            error: nil
        )
    }

    /// Pins/unpins a session via native REST PATCH `{pinned}`.
    func pinSession(id: String, pinned: Bool) async throws -> SessionMutationResponse {
        let patch = SessionPatchRequest(title: nil, archived: nil, pinned: pinned)
        let native: NativeSessionRow = try await send(
            endpoint: .sessionPatch(id: id),
            method: "PATCH",
            body: patch
        )
        return SessionMutationResponse(
            ok: true,
            session: native.summary(),
            error: nil
        )
    }

    /// Archives/unarchives a session via native REST PATCH `{archived}`.
    func archiveSession(id: String, archived: Bool) async throws -> SessionMutationResponse {
        let patch = SessionPatchRequest(title: nil, archived: archived, pinned: nil)
        let native: NativeSessionRow = try await send(
            endpoint: .sessionPatch(id: id),
            method: "PATCH",
            body: patch
        )
        return SessionMutationResponse(
            ok: true,
            session: native.summary(),
            error: nil
        )
    }

    /// Branches a session via the gateway `session.branch` RPC, then hydrates the
    /// new branch through REST detail. `keepCount` limits the copied history;
    /// `title` becomes the branch's name.
    func branchSession(id: String, keepCount: Int? = nil, title: String? = nil) async throws -> SessionBranchResponse {
        let result: GatewayValue = try await withGatewayConnection(profile: nil) { gateway in
            try await gateway.branch(
                sessionID: id,
                count: keepCount,
                name: title
            )
        }
        let object = result.objectValue ?? [:]
        let branchID = nonEmptyText(object["session_id"]?.stringValue)
            ?? nonEmptyText(object["stored_session_id"]?.stringValue)
        guard let branchID else {
            throw APIError.decoding(underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "session.branch returned no session id.")
            ))
        }
        return SessionBranchResponse(
            sessionId: branchID,
            title: nonEmptyText(object["title"]?.stringValue) ?? title,
            parentSessionId: nonEmptyText(object["parent"]?.stringValue) ?? id,
            error: nil
        )
    }

    /// Compresses a session via the gateway `session.compress` RPC, then reloads
    /// the durable transcript so the UI can replace its messages.
    func compressSession(id: String, focusTopic: String? = nil) async throws -> SessionCompressResponse {
        let result: GatewayValue = try await withGatewayConnection(profile: nil) { gateway in
            try await gateway.compress(sessionID: id, focusTopic: focusTopic)
        }
        let object = result.objectValue ?? [:]
        let status = object["status"]?.stringValue ?? "compressed"
        let summary = SessionCompressionSummary(
            headline: object["summary"]?.objectValue?["headline"]?.stringValue,
            tokenLine: object["summary"]?.objectValue?["token_line"]?.stringValue,
            note: object["summary"]?.objectValue?["note"]?.stringValue,
            referenceMessage: nil
        )
        let messages: [ChatMessage] = object["messages"]?.arrayValue?.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(ChatMessage.self, from: data)
        } ?? []
        return SessionCompressResponse(
            ok: status == "compressed",
            session: nil,
            summary: summary,
            focusTopic: focusTopic,
            error: status == "compressed" ? nil : String(localized: "Compression did not complete.")
        )
    }

    /// Updates a session's model/provider/workspace via gateway `config.set`
    /// (`model`) and `session.cwd.set` (`workspace`), then reloads the detail.
    func updateSession(
        id: String,
        workspace: String?,
        model: String?,
        modelProvider: String?
    ) async throws -> SessionResponse {
        try await withGatewayConnection(profile: nil) { gateway in
            if let model, !model.isEmpty {
                var value = model
                if let modelProvider, !modelProvider.isEmpty {
                    value += " --provider \(modelProvider)"
                }
                try await gateway.setConfig(sessionID: id, key: "model", value: .string(value))
            }
            if let workspace, !workspace.isEmpty {
                try await gateway.setSessionCwd(sessionID: id, cwd: workspace)
            }
        }
        return try await session(id: id, includeMessages: false, messageLimit: nil)
    }

    /// Moves a durable session using the destination project's primary path.
    /// Hermes derives project membership from cwd; there is no project-id move.
    func moveSession(id: String, projectID: String?) async throws -> SessionMutationResponse {
        guard let projectID, !projectID.isEmpty else {
            throw APIError.decoding(underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Native Hermes cannot move a session to an unassigned project bucket.")
            ))
        }
        let projects = try await projects()
        let destination = projects.projects?.first { $0.projectId == projectID }?.primaryPath
        guard let destination, !destination.isEmpty else {
            throw APIError.decoding(underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "The destination project has no workspace path.")
            ))
        }
        try await withGatewayConnection(profile: nil) { gateway in
            try await gateway.moveSession(id, toWorkspace: destination)
        }
        let response = try await self.session(id: id, includeMessages: false, messageLimit: nil)
        guard let detail = response.session else {
            return SessionMutationResponse(ok: false, session: nil, error: String(localized: "The server did not return the moved session."))
        }
        return SessionMutationResponse(ok: true, session: SessionSummary(from: detail).replacingProjectID(with: projectID), error: nil)
    }

    /// Reads the session's approval-bypass (YOLO) state via the gateway's
    /// `config.set("yolo", value: "status")` read contract.
    func sessionYolo(sessionID: String) async throws -> SessionYoloResponse {
        let result: GatewayValue = try await withGatewayConnection(profile: nil) { gateway in
            try await gateway.yoloStatus(sessionID: sessionID)
        }
        return SessionYoloResponse(ok: true, yoloEnabled: result.boolValue ?? (result.stringValue == "1"))
    }

    /// Sets the session's approval-bypass (YOLO) state via `config.set("yolo", …)`.
    func setSessionYolo(sessionID: String, enabled: Bool) async throws -> SessionYoloResponse {
        let result: GatewayValue = try await withGatewayConnection(profile: nil) { gateway in
            try await gateway.setConfig(sessionID: sessionID, key: "yolo", value: .string(enabled ? "1" : "0"))
            return .string(enabled ? "1" : "0")
        }
        return SessionYoloResponse(ok: true, yoloEnabled: result.stringValue == "1")
    }
}

// MARK: - Request bodys

/// Trims + nils empty text (mirrors `SessionSummary.nonEmpty`, which is private
/// to that type).
private func nonEmptyText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private struct SessionPatchRequest: Encodable {
    let title: String?
    let archived: Bool?
    let pinned: Bool?
}

/// `DELETE /api/sessions/{id}` returns `{ok, already_absent?}`.
private struct NativeDeleteSessionResponse: Decodable {
    let ok: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
    }
}

// MARK: - SessionDetail native mapping

extension SessionDetail {
    /// Builds a `SessionDetail` from a native session row plus an optional
    /// transcript page, mapping pagination metadata into the legacy
    /// `messagesTruncated`/`messagesOffset` fields the chat UI consumes.
    fileprivate init(
        native: NativeSessionRow,
        messages: [ChatMessage]?,
        messagesOffset: Int?,
        messagesTruncated: Bool?
    ) {
        self.init(
            sessionId: native.resolvedSessionID,
            title: native.resolvedTitle,
            workspace: native.resolvedWorkspace,
            model: nonEmptyText(native.model),
            modelProvider: nonEmptyText(native.modelProvider),
            messageCount: native.messageCount,
            createdAt: native.startedAt ?? native.lastActivityAt,
            updatedAt: native.updatedAt ?? native.lastActivityAt,
            lastMessageAt: native.lastActivityAt,
            pinned: native.pinned,
            archived: native.archived,
            projectId: nonEmptyText(native.projectId),
            profile: native.resolvedProfile,
            inputTokens: native.inputTokens,
            outputTokens: native.outputTokens,
            estimatedCost: native.estimatedCostUsd,
            activeStreamId: nil,
            pendingUserMessage: nil,
            pendingAttachments: nil,
            pendingStartedAt: nil,
            worktreePath: native.resolvedWorkspace,
            contextLength: nil,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            isCliSession: nil,
            sourceTag: nonEmptyText(native.sourceTag) ?? nonEmptyText(native.source),
            rawSource: nonEmptyText(native.source),
            sessionSource: nonEmptyText(native.source),
            sourceLabel: nonEmptyText(native.source),
            parentSessionId: nonEmptyText(native.parentSessionId),
            relationshipType: nonEmptyText(native.relationshipType),
            readOnly: nil,
            isReadOnly: nil,
            messages: messages,
            toolCalls: nil,
            messagesTruncated: messagesTruncated,
            messagesOffset: messagesOffset,
            compressionAnchorVisibleIdx: nil,
            compressionAnchorMessageKey: nil,
            compressionAnchorSummary: nil
        )
    }
}
