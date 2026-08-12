import Foundation

struct ChatCancelResponse: Decodable, Equatable {
    let ok: Bool?
    let cancelled: Bool?
    let streamId: String?
    let error: String?
}

struct ChatStreamStatusResponse: Decodable, Equatable {
    let active: Bool?
    let streamId: String?
    let replayAvailable: Bool?
    let journal: RunJournalStatus?
}

/// The server's run-journal summary, surfaced on `/api/chat/stream/status` so a
/// reconciled Live Activity can be finalized with the run's real outcome (#267).
/// Every field is optional: the `journal` block is absent when the server has no
/// summary for a stream, and `terminalState`'s vocabulary may grow upstream — so
/// we decode tolerantly and never crash on an unknown value.
struct RunJournalStatus: Decodable, Equatable {
    /// Whether the server logged a genuine terminal event for the run. Decoded to
    /// mirror the journal payload shape (#267 acceptance criterion named both
    /// fields); outcome mapping reads `terminalState` only. Kept because it is not
    /// redundant with `terminalState`: a run the server force-marks
    /// `"lost-worker-bookkeeping"` reports `terminal == false`, so this stays
    /// available for any future consumer that must tell a real terminal event from
    /// a bookkeeping one.
    let terminal: Bool?
    let terminalState: String?
}

struct ChatSteerResponse: Decodable, Equatable {
    let accepted: Bool?
    let fallback: String?
    let streamId: String?
    let error: String?
}

struct BackgroundStartResponse: Decodable, Equatable {
    let taskId: String?
    let streamId: String?
    let sessionId: String?
    let error: String?
}

struct BackgroundStatusResponse: Decodable, Equatable {
    let results: [BackgroundResult]?
}

struct BackgroundResult: Decodable, Equatable {
    let taskId: String?
    let prompt: String?
    let answer: String?
    let completedAt: Double?
}

struct ModelsResponse: Decodable, Equatable {
    let groups: [JSONValue]?
    let models: [JSONValue]?
    let defaultModel: String?
    let activeProvider: String?
}

struct DefaultModelResponse: Decodable, Equatable {
    let ok: Bool?
    let model: String?
}

/// `GET /api/reasoning` (and the reasoning save endpoints). The server returns
/// the resolved model's reasoning/effort state; fields vary by server version and
/// all decode lossily.
struct ReasoningStatusResponse: Decodable, Equatable {
    /// Model-aware effort vocabulary from `GET /api/reasoning` (`supported_efforts`).
    /// `nil` on older servers that don't send the field — callers must fall back
    /// to the static effort list (issue #18).
    let supportedEfforts: [String]?
    /// `supports_reasoning_effort` — `false` means the resolved model has no
    /// effort control at all (hide the picker). `nil` on older servers.
    let supportsReasoningEffort: Bool?
    let error: String?
    let ok: Bool?
    let showReasoning: Bool?
    let reasoningEffort: String?
    let effort: String?

    var effectiveEffort: String? {
        reasoningEffort ?? effort
    }

    /// `supported_efforts` trimmed, lowercased, de-duplicated, order preserved.
    /// Stays `nil` when the server omitted the field (legacy fallback signal).
    var normalizedSupportedEfforts: [String]? {
        guard let supportedEfforts else { return nil }
        var seen = Set<String>()
        return supportedEfforts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct PersonalitiesResponse: Decodable, Equatable {
    let personalities: [PersonalitySummary]?
}

extension PersonalitiesResponse {
    var slashAutocompleteNames: [String] {
        var seen = Set<String>()
        return (["none"] + (personalities ?? []).compactMap { personality in
            guard let name = personality.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                return nil
            }

            return name
        })
        .filter { seen.insert($0).inserted }
    }
}

struct PersonalitySummary: Decodable, Equatable, Hashable, Identifiable {
    var id: String { name ?? UUID().uuidString }

    let name: String?
    let description: String?
}

struct PersonalitySetResponse: Decodable, Equatable {
    let ok: Bool?
    let personality: String?
    let prompt: String?
    let error: String?
}

struct ProfilesResponse: Decodable, Equatable {
    let profiles: [ProfileSummary]?
    let active: String?
    let singleProfileMode: Bool?

    init(profiles: [ProfileSummary]?, active: String?, singleProfileMode: Bool? = nil) {
        self.profiles = profiles
        self.active = active
        self.singleProfileMode = singleProfileMode
    }
}

struct ProfileCreateResponse: Decodable, Equatable {
    let ok: Bool?
    let profile: ProfileSummary?
    let error: String?
}

/// Mirrors the upstream profile-name rule (`^[a-z0-9][a-z0-9_-]{0,63}$`) so the
/// create form can validate before hitting the server.
enum ProfileNameRules {
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 64 else { return false }
        guard isLowercaseAlphanumeric(first) else { return false }
        return name.allSatisfy { isLowercaseAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isLowercaseAlphanumeric(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character)
    }

    /// Mirrors the upstream base-URL rule for profile creation: when provided,
    /// the value must start with `http://` or `https://` (server 400s otherwise).
    static func isValidBaseURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }
}

struct ProfileSwitchResponse: Decodable, Equatable {
    let profiles: [ProfileSummary]?
    let active: String?
    let defaultModel: String?
    let defaultWorkspace: String?
    let error: String?
}

struct ProfileSummary: Decodable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name ?? path ?? UUID().uuidString }

    let name: String?
    let path: String?
    let isDefault: Bool?
    let isActive: Bool?
    let gatewayRunning: Bool?
    let model: String?
    let provider: String?
    let hasEnv: Bool?
    let skillCount: Int?

    var displayName: String {
        guard let name, !name.isEmpty else { return String(localized: "Profile") }
        return name == "default" ? String(localized: "Default") : name
    }

    var normalizedName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ProfilesResponse {
    var effectiveDefaultProfileName: String? {
        if let active = normalizedProfileName(active) {
            return active
        }

        if let activeProfile = profiles?.first(where: { $0.isActive == true })?.normalizedName {
            return activeProfile
        }

        if let defaultProfile = profiles?.first(where: { $0.isDefault == true })?.normalizedName {
            return defaultProfile
        }

        return profiles?.compactMap(\.normalizedName).first
    }

    func displayName(for profileName: String?) -> String? {
        guard let profileName = normalizedProfileName(profileName) else { return nil }

        return profile(matching: profileName)?.displayName
            ?? (profileName == "default" ? String(localized: "Default") : profileName)
    }

    func profile(matching profileName: String?) -> ProfileSummary? {
        guard let profileName = normalizedProfileName(profileName) else { return nil }
        return profiles?.first { $0.normalizedName == profileName }
    }

    private func normalizedProfileName(_ profileName: String?) -> String? {
        guard let profileName else { return nil }
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ModelCatalogGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let providerID: String?
    let models: [ModelCatalogOption]
    let extraModels: [ModelCatalogOption]

    init(
        id: String,
        name: String,
        providerID: String?,
        models: [ModelCatalogOption],
        extraModels: [ModelCatalogOption]
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.models = models
        self.extraModels = extraModels
    }

    init(
        id: String,
        name: String,
        providerID: String?,
        models: [ModelCatalogOption]
    ) {
        self.init(
            id: id,
            name: name,
            providerID: providerID,
            models: models,
            extraModels: []
        )
    }
}

extension ModelCatalogGroup {
    var slashAutocompleteModels: [ModelCatalogOption] {
        var seen = Set<String>()
        return (models + extraModels).filter { seen.insert($0.id).inserted }
    }
}

struct ModelCatalogOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let providerID: String?
}

extension ModelCatalogOption {
    func matchesSelection(modelID: String?, providerID: String?) -> Bool {
        guard id == modelID else { return false }
        guard let providerID else { return true }
        return self.providerID == providerID
    }
}

extension Collection where Element == ModelCatalogOption {
    func firstMatchingSelection(modelID: String?, providerID: String?) -> ModelCatalogOption? {
        guard let modelID, !modelID.isEmpty else { return nil }

        if let providerID {
            return first { $0.id == modelID && $0.providerID == providerID }
        }

        return first { $0.id == modelID }
    }
}

extension ModelsResponse {
    var catalogGroups: [ModelCatalogGroup] {
        ModelCatalogParser.parseGroups(from: self)
    }

    func displayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        return catalogGroups
            .flatMap(\.slashAutocompleteModels)
            .first(where: { $0.id == modelID })?
            .displayName
    }
}

/// Live (refreshed) model list for the current provider, mapped from the native
/// `/api/model/options?refresh=1` payload. Shape:
/// `{"provider": "<id>", "models": [{"id", "label"}], "count": <int>}`.
struct ModelsLiveResponse: Decodable, Equatable {
    let provider: String?
    let models: [JSONValue]?
    let count: Int?
}

extension ModelsLiveResponse {
    /// Provider id with whitespace-only values normalized away.
    var normalizedProvider: String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Models parsed from the live payload, attributed to the echoed provider.
    var liveOptions: [ModelCatalogOption] {
        guard let models else { return [] }
        return ModelCatalogParser.parseModelOptions(
            from: .array(models),
            providerID: normalizedProvider
        )
    }
}

extension Array where Element == ModelCatalogGroup {
    /// Replaces the matching provider group's models with the live list (live is
    /// authoritative for that provider, covering both additions and removals).
    /// Returns `self` unchanged when the provider matches no group or the live
    /// list is empty, so an odd live response can never blank out the cached picker.
    func mergingLiveModels(from response: ModelsLiveResponse) -> [ModelCatalogGroup] {
        guard let provider = response.normalizedProvider else { return self }

        let liveModels = response.liveOptions
        guard !liveModels.isEmpty else { return self }

        return map { group in
            guard group.providerID == provider else { return group }
            return ModelCatalogGroup(
                id: group.id,
                name: group.name,
                providerID: group.providerID,
                models: liveModels,
                extraModels: group.extraModels
            )
        }
    }
}

private enum ModelCatalogParser {
    static func parseGroups(from response: ModelsResponse) -> [ModelCatalogGroup] {
        guard let groupValues = response.groups else { return [] }

        return groupValues.enumerated().compactMap { index, groupValue in
            guard case .object(let groupDict) = groupValue else { return nil }

            let providerID = stringValue(from: groupDict["provider_id"])
            let name = stringValue(from: groupDict["name"]) ?? providerID ?? String(localized: "Models")
            let models = parseModelOptions(from: groupDict["models"], providerID: providerID)
            let extraModels = parseModelOptions(from: groupDict["extra_models"], providerID: providerID)
            guard !models.isEmpty else { return nil }

            return ModelCatalogGroup(
                id: providerID ?? "\(name)-\(index)",
                name: name,
                providerID: providerID,
                models: models,
                extraModels: extraModels
            )
        }
    }

    static func parseModelOptions(from value: JSONValue?, providerID: String?) -> [ModelCatalogOption] {
        guard case .array(let items) = value else { return [] }

        return items.compactMap { item in
            guard case .object(let dict) = item else { return nil }

            let id = stringValue(from: dict["id"]) ?? ""
            guard !id.isEmpty else { return nil }

            let displayName = stringValue(from: dict["name"])
                ?? stringValue(from: dict["label"])
                ?? id
            let optionProviderID = stringValue(from: dict["provider_id"]) ?? providerID

            return ModelCatalogOption(
                id: id,
                displayName: displayName,
                providerID: optionProviderID
            )
        }
    }

    private static func stringValue(from value: JSONValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
