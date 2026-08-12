import Foundation

extension APIClient {
    /// Native model/provider inventory (`GET /api/model/options`), mapped to
    /// Hermex's `ModelsResponse` so the existing composer and picker keep their
    /// catalog contract. The native payload is `{providers: [row], model,
    /// provider}` — `model`/`provider` are the configured (current) assignment.
    func models(profile: String? = nil) async throws -> ModelsResponse {
        let native: NativeModelOptionsResponse = try await send(
            endpoint: .modelOptions(profile: profile, refresh: false),
            method: "GET"
        )
        return native.hermexModelsResponse
    }

    /// Persists the main-slot model assignment via `POST /api/model/set
    /// {scope: "main", provider, model}` and returns the assigned model.
    /// A model-only picker (no provider known) carries an empty provider; the
    /// server's main-slot validation requires provider + model together, so
    /// callers that only know the model id supply the current provider too.
    func saveDefaultModel(model: String, provider: String? = nil) async throws -> DefaultModelResponse {
        let body = ModelSetRequest(
            scope: "main",
            provider: provider ?? "",
            model: model
        )
        let response: ModelSetResponse = try await send(endpoint: .modelSet, method: "POST", body: body)
        return DefaultModelResponse(
            ok: response.ok ?? true,
            model: response.model ?? model
        )
    }

    /// Refreshed live provider inventory (`GET /api/model/options?refresh=1`)
    /// for the current profile, mapped to `ModelsLiveResponse`. The native
    /// refresh busts the per-provider model cache; `model`/`provider` echo the
    /// resolved current assignment.
    func modelsLive(profile: String? = nil) async throws -> ModelsLiveResponse {
        let native: NativeModelOptionsResponse = try await send(
            endpoint: .modelOptions(profile: profile, refresh: true),
            method: "GET"
        )
        return native.liveResponse
    }

    /// Reasoning status for the current profile's resolved model. The native
    /// dashboard has no `/api/reasoning`; we derive the support signal from the
    /// per-model `capabilities.reasoning` map in `/api/model/options` and expose
    /// the native effort vocabulary as `supported_efforts`.
    func reasoning(profile: String? = nil) async throws -> ReasoningStatusResponse {
        let native: NativeModelOptionsResponse = try await send(
            endpoint: .modelOptions(profile: profile, refresh: false),
            method: "GET"
        )
        return ReasoningStatusResponse(
            supportedEfforts: [String](ReasoningStatusResponse.nativeEffortVocabulary),
            supportsReasoningEffort: native.capabilities(for: native.currentModel),
            error: nil,
            ok: true,
            showReasoning: true,
            reasoningEffort: nil,
            effort: nil
        )
    }

    /// Persists the default reasoning effort via the gateway `config.set
    /// reasoning` (global scope) — the native dashboard's persistence path for
    /// the effort level. Returns the refreshed reasoning status.
    func saveReasoningEffort(_ effort: String, profile: String? = nil) async throws -> ReasoningStatusResponse {
        try await withGatewayConnection(profile: profile) { gateway in
            _ = try await gateway.setConfig(
                sessionID: "",
                key: "reasoning",
                value: .string(effort),
                global: true
            )
        }
        return try await reasoning(profile: profile)
    }

    /// Sets the reasoning display (show/hide) via the gateway `config.set
    /// reasoning` (global) — mirrors the native `show_reasoning` config key.
    func saveReasoningDisplay(_ display: String, profile: String? = nil) async throws -> ReasoningStatusResponse {
        try await withGatewayConnection(profile: profile) { gateway in
            _ = try await gateway.setConfig(
                sessionID: "",
                key: "reasoning",
                value: .string(display),
                global: true
            )
        }
        return try await reasoning(profile: profile)
    }

    /// Lists profiles (`GET /api/profiles`) merged with the sticky active one
    /// (`GET /api/profiles/active`), into Hermex's `ProfilesResponse`.
    func profiles() async throws -> ProfilesResponse {
        let list: NativeProfilesListResponse = try await send(endpoint: .profiles, method: "GET")
        let active: NativeActiveProfileResponse = try await send(endpoint: .activeProfile, method: "GET")
        let activeName = active.active ?? active.current ?? "default"
        return ProfilesResponse(
            profiles: list.profiles?.map(\.summary) ?? [],
            active: activeName,
            singleProfileMode: nil
        )
    }

    /// Switches the sticky active profile (`POST /api/profiles/active {name}`),
    /// then reloads the profile list so the response carries the fresh active
    /// profile and its default model.
    func switchProfile(name: String) async throws -> ProfileSwitchResponse {
        let switchResponse: NativeActiveProfileUpdateResponse = try await send(
            endpoint: .switchProfile,
            method: "POST",
            body: ActiveProfileUpdateRequest(name: name)
        )
        let resolvedName = switchResponse.active ?? name
        let profilesResponse = try await profiles()
        let activeModel = profilesResponse.profile(matching: resolvedName)?.model
        return ProfileSwitchResponse(
            profiles: profilesResponse.profiles,
            active: resolvedName,
            defaultModel: activeModel,
            defaultWorkspace: nil,
            error: nil
        )
    }

    /// Creates a profile (`POST /api/profiles {name, clone_from_default, …}`).
    /// The webui "clone config" toggle maps to `clone_from_default`; the
    /// optional model/provider assignment is honored best-effort by the server
    /// after the profile directory exists.
    func createProfile(
        name: String,
        cloneConfig: Bool = false,
        defaultModel: String? = nil,
        modelProvider: String? = nil,
        baseUrl: String? = nil,
        apiKey: String? = nil
    ) async throws -> ProfileCreateResponse {
        let body = NativeProfileCreateRequest(
            name: name,
            cloneFrom: nil,
            cloneFromDefault: cloneConfig,
            provider: modelProvider,
            model: defaultModel
        )
        let response: NativeProfileCreateResponse = try await send(
            endpoint: .createProfile,
            method: "POST",
            body: body
        )
        let ok = response.ok ?? true
        return ProfileCreateResponse(
            ok: ok,
            profile: ProfileSummary(
                name: response.name ?? name,
                path: response.path,
                isDefault: false,
                isActive: false,
                gatewayRunning: nil,
                model: defaultModel,
                provider: modelProvider,
                hasEnv: nil,
                skillCount: nil
            ),
            error: ok ? nil : response.error
        )
    }
}

private struct ModelSetRequest: Encodable {
    let scope: String
    let provider: String
    let model: String
}

/// `POST /api/model/set` response — `{ok, scope, provider, model, …}`.
private struct ModelSetResponse: Decodable {
    let ok: Bool?
    let model: String?
    let provider: String?
    let confirmRequired: Bool?
    let error: String?
}

private struct ActiveProfileUpdateRequest: Encodable {
    let name: String
}

/// `POST /api/profiles` create payload — mirrors the native `ProfileCreate`
/// model: "clone config" maps to `clone_from_default`, and the optional
/// model/provider assignment is applied best-effort after the directory exists.
private struct NativeProfileCreateRequest: Encodable {
    let name: String
    let cloneFrom: String?
    let cloneFromDefault: Bool
    let provider: String?
    let model: String?
}

private struct NativeProfileCreateResponse: Decodable {
    let ok: Bool?
    let name: String?
    let path: String?
    let error: String?
}

/// `GET /api/profiles` — native list shape (`_profile_to_dict`/fallback rows).
private struct NativeProfilesListResponse: Decodable {
    let profiles: [NativeProfileRow]?
}

private struct NativeProfileRow: Decodable {
    let name: String?
    let path: String?
    let isDefault: Bool?
    let isActive: Bool?
    let gatewayRunning: Bool?
    let model: String?
    let provider: String?
    let hasEnv: Bool?
    let skillCount: Int?

    var summary: ProfileSummary {
        ProfileSummary(
            name: name,
            path: path,
            isDefault: isDefault,
            isActive: isActive,
            gatewayRunning: gatewayRunning,
            model: model,
            provider: provider,
            hasEnv: hasEnv,
            skillCount: skillCount
        )
    }
}

/// `GET /api/profiles/active` — `{active, current}`.
private struct NativeActiveProfileResponse: Decodable {
    let active: String?
    let current: String?
}

/// `POST /api/profiles/active` — `{ok, active}`.
private struct NativeActiveProfileUpdateResponse: Decodable {
    let ok: Bool?
    let active: String?
}

/// `GET /api/model/options` — `{providers: [row], model, provider}`.
private struct NativeModelOptionsResponse: Decodable {
    struct ProviderRow: Decodable {
        let slug: String?
        let name: String?
        let isCurrent: Bool?
        let isUserDefined: Bool?
        let models: [String]?
        let totalModels: Int?
        let capabilities: [String: [String: Bool]]?

        var providerID: String? {
            let trimmed = slug?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }

        var displayName: String {
            let trimmed = (name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            return trimmed.isEmpty ? (providerID ?? String(localized: "Models")) : trimmed
        }

        /// Native models are bare model-id strings; each becomes a
        /// `{id, label}` object matching the catalog parser's model shape.
        var modelObjects: [JSONValue] {
            (models ?? []).compactMap { modelID in
                let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                return .object([
                    "id": .string(id),
                    "label": .string(id)
                ])
            }
        }

        var catalogGroup: ModelCatalogGroup {
            let providerID = providerID
            let options = (models ?? []).map { modelID in
                ModelCatalogOption(id: modelID, displayName: modelID, providerID: providerID)
            }
            return ModelCatalogGroup(
                id: providerID ?? displayName,
                name: displayName,
                providerID: providerID,
                models: options,
                extraModels: []
            )
        }

        /// A single provider row serialized as the catalog's `groups` entry.
        var groupValue: JSONValue {
            .object([
                "provider_id": providerID.map(JSONValue.string) ?? .string(""),
                "name": .string(displayName),
                "models": .array(modelObjects)
            ])
        }
    }

    let providers: [ProviderRow]?
    let model: String?
    let provider: String?

    var currentModel: String? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    var currentProvider: String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The provider row backing the current assignment, if any.
    var currentRow: ProviderRow? {
        guard let currentProvider else { return nil }
        let target = currentProvider.lowercased()
        return providers?.first {
            ($0.providerID?.lowercased() == target)
                || ($0.isCurrent == true && $0.providerID?.lowercased().contains(target) == true)
        }
        ?? providers?.first { $0.isCurrent == true }
    }

    /// Hermex `ModelsResponse` — the catalog `groups` derived from the native
    /// provider rows, `default_model` = the configured model.
    var hermexModelsResponse: ModelsResponse {
        ModelsResponse(
            groups: providers?.map(\.groupValue),
            models: nil,
            defaultModel: currentModel,
            activeProvider: currentProvider
        )
    }

    /// Hermex live-response shape for the current provider — the native
    /// refresh echoes the resolved provider and its (refreshed) model ids.
    var liveResponse: ModelsLiveResponse {
        let row = currentRow
        return ModelsLiveResponse(
            provider: currentProvider,
            models: row?.modelObjects,
            count: row.map { $0.models?.count ?? 0 }
        )
    }

    /// The `{model: {reasoning}}` capabilities entry for the resolved model —
    /// scans every provider row's capabilities map.
    func capabilities(for modelID: String?) -> Bool? {
        guard let modelID else { return nil }
        for row in providers ?? [] {
            guard let caps = row.capabilities?[modelID],
                  let reasoning = caps["reasoning"] else { continue }
            return reasoning
        }
        return nil
    }
}

extension ReasoningStatusResponse {
    /// Native gateway reasoning-effort vocabulary. Mirrors the backend
    /// `VALID_REASONING_EFFORTS` (`minimal … ultra`); the composer's static
    /// fallback list already covers `none` + these.
    static let nativeEffortVocabulary: Set<String> = [
        "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
    ]
}
