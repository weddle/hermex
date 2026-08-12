import XCTest
@testable import HermesMobile

final class ChatComposerConfigLoaderTests: APIClientTestCase {
    func testLoadUsesSessionProfileDefault() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        var requestPaths: [String] = []
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            requestPaths.append(request.url?.path ?? "")

            switch (requestCount, request.url?.path) {
            case (1, "/api/profiles"):
                // Initial profile list from profiles()'s first REST call.
                return apiTestJSONResponse("""
                {
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter"}
                  ]
                }
                """, for: request)
            case (2, "/api/profiles/active"):
                // Active lookup: session profile "work" differs from "default".
                return apiTestJSONResponse(#"{"active": "default"}"#, for: request)
            case (3, "/api/profiles/active"):
                // switchProfile(name: "work"): POST the sticky active name.
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "work")
                return apiTestJSONResponse(#"{"ok": true, "active": "work"}"#, for: request)
            case (4, "/api/profiles"):
                // switchProfile reloads the profile list with the fresh active.
                return apiTestJSONResponse("""
                {
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case (5, "/api/profiles/active"):
                return apiTestJSONResponse(#"{"active": "work"}"#, for: request)
            case (6, "/api/model/options"), (7, "/api/model/options"):
                // models(profile:) and reasoning(profile:) both hit /api/model/options.
                return apiTestJSONResponse("""
                {
                  "model": "\(openRouterModel)",
                  "provider": "openrouter",
                  "providers": [
                    {
                      "slug": "openrouter",
                      "name": "OpenRouter",
                      "models": ["\(openRouterModel)"],
                      "capabilities": { "\(openRouterModel)": { "reasoning": true, "fast": true } }
                    }
                  ]
                }
                """, for: request)
            case (8, "/api/fs/default-cwd"):
                return apiTestJSONResponse(#"{"cwd": "/tmp/workspace"}"#, for: request)
            default:
                XCTFail("Unexpected request \(requestCount): \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState(currentProfile: "work")
        )

        XCTAssertNil(result.configurationError)
        XCTAssertEqual(result.state.selectedProfileName, "work")
        XCTAssertEqual(result.state.currentProfile, "work")
        XCTAssertEqual(result.state.currentModel, openRouterModel)
        XCTAssertEqual(result.state.currentModelProvider, "openrouter")
        XCTAssertEqual(result.state.currentWorkspace, "/tmp/workspace")
        // The native /api/model/options-derived reasoning always carries the
        // full effort vocabulary; the seeded effort stays the local selection.
        XCTAssertNil(result.state.selectedReasoningEffort)
        XCTAssertEqual(
            Set(result.state.supportedReasoningEfforts ?? []),
            ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(result.state.supportsReasoningEffort, true)
        XCTAssertEqual(result.state.workspaceSuggestions, ["/tmp/workspace"])
        XCTAssertEqual(requestPaths, [
            "/api/profiles",
            "/api/profiles/active",
            "/api/profiles/active",
            "/api/profiles",
            "/api/profiles/active",
            "/api/model/options",
            "/api/model/options",
            "/api/fs/default-cwd"
        ])
    }

    func testLoadKeepsSessionModelOverrideWhenProfileHasDifferentDefault() async throws {
        let sessionModel = "@openai:gpt-5.5"
        let profileDefault = "deepseek/deepseek-chat-v3-0324:free"
        var requestPaths: [String] = []
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            requestPaths.append(request.url?.path ?? "")

            switch (requestCount, request.url?.path) {
            case (1, "/api/profiles"):
                return apiTestJSONResponse("""
                {
                  "profiles": [
                    {"name": "work", "model": "\(profileDefault)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case (2, "/api/profiles/active"):
                return apiTestJSONResponse(#"{"active": "work"}"#, for: request)
            case (3, "/api/model/options"), (4, "/api/model/options"):
                return apiTestJSONResponse("""
                {
                  "model": "\(profileDefault)",
                  "provider": "openrouter",
                  "providers": [
                    {
                      "slug": "openrouter",
                      "name": "OpenRouter",
                      "models": ["\(profileDefault)"],
                      "capabilities": { "\(profileDefault)": { "reasoning": true, "fast": true } }
                    },
                    {
                      "slug": "openai",
                      "name": "OpenAI",
                      "models": ["\(sessionModel)"],
                      "capabilities": { "\(sessionModel)": { "reasoning": true } }
                    }
                  ]
                }
                """, for: request)
            case (5, "/api/fs/default-cwd"):
                return apiTestJSONResponse(#"{"cwd": "/tmp/workspace"}"#, for: request)
            default:
                XCTFail("Unexpected request \(requestCount): \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState(
                currentWorkspace: "/tmp/workspace",
                currentModel: sessionModel,
                currentModelProvider: "openai",
                currentProfile: "work"
            )
        )

        XCTAssertNil(result.configurationError)
        XCTAssertEqual(result.state.currentModel, sessionModel)
        XCTAssertEqual(result.state.currentModelProvider, "openai")
        XCTAssertEqual(result.state.selectedProfileName, "work")
        // The native /api/model/options-derived reasoning never seeds the
        // locally-selected effort; it only surfaces the model-aware gating.
        XCTAssertNil(result.state.selectedReasoningEffort)
        XCTAssertEqual(
            Set(result.state.supportedReasoningEfforts ?? []),
            ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(result.state.supportsReasoningEffort, true)
        XCTAssertEqual(requestPaths, [
            "/api/profiles",
            "/api/profiles/active",
            "/api/model/options",
            "/api/model/options",
            "/api/fs/default-cwd"
        ])
    }

    func testLoadReturnsPartialStateWhenConfigurationFails() async throws {
        var requestPaths: [String] = []
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            requestPaths.append(request.url?.path ?? "")

            switch (requestCount, request.url?.path) {
            case (1, "/api/profiles"):
                return apiTestJSONResponse("""
                {
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true}
                  ]
                }
                """, for: request)
            case (2, "/api/profiles/active"):
                return apiTestJSONResponse(#"{"active": "default"}"#, for: request)
            case (3, "/api/model/options"):
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"models unavailable"}"#.utf8))
            default:
                XCTFail("Unexpected request \(requestCount): \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState()
        )

        XCTAssertNotNil(result.configurationError)
        XCTAssertEqual(result.state.selectedProfileName, "default")
        XCTAssertEqual(result.state.profileOptions.map(\.name), ["default"])
        XCTAssertEqual(result.state.currentModel, "gpt-5.4")
        XCTAssertNil(result.state.currentModelProvider)
        XCTAssertEqual(requestPaths, ["/api/profiles", "/api/profiles/active", "/api/model/options"])
    }

    func testLoadStoresSingleProfileModeFromProfilesResponse() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1

            switch (requestCount, request.url?.path) {
            case (1, "/api/profiles"):
                // Even when the server marks single_profile_mode, the native
                // mapper does not surface it through the /api/profiles list.
                return apiTestJSONResponse("""
                {
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true, "is_active": true}
                  ],
                  "single_profile_mode": true
                }
                """, for: request)
            case (2, "/api/profiles/active"):
                return apiTestJSONResponse(#"{"active": "default"}"#, for: request)
            case (3, "/api/model/options"), (4, "/api/model/options"):
                return apiTestJSONResponse("""
                {
                  "model": "gpt-5.4",
                  "provider": "openai",
                  "providers": [
                    {
                      "slug": "openai",
                      "name": "OpenAI",
                      "models": ["gpt-5.4"],
                      "capabilities": { "gpt-5.4": { "reasoning": true } }
                    }
                  ]
                }
                """, for: request)
            case (5, "/api/fs/default-cwd"):
                return apiTestJSONResponse(#"{"cwd": "/tmp"}"#, for: request)
            default:
                XCTFail("Unexpected request \(requestCount): \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState()
        )

        XCTAssertNil(result.configurationError)
        // The native REST profiles mapping never carries single_profile_mode, so
        // the composer keeps the default multi-profile mode.
        XCTAssertFalse(result.state.isSingleProfileMode)
    }
}

/// Pure gating logic for the composer reasoning-effort menu (issue #18):
/// building the option list from `supported_efforts` and deciding whether
/// the control is shown at all.
final class ReasoningEffortGatingTests: XCTestCase {
    func testOptionsFallBackToStaticListWithoutServerVocabulary() {
        XCTAssertEqual(
            ReasoningEffortOption.options(forSupportedEfforts: nil).map(\.id),
            ["none", "minimal", "low", "medium", "high", "xhigh"]
        )
        // Defensive: an empty list also falls back (the control is hidden
        // before this is rendered because supports_reasoning_effort is false).
        XCTAssertEqual(
            ReasoningEffortOption.options(forSupportedEfforts: []).map(\.id),
            ["none", "minimal", "low", "medium", "high", "xhigh"]
        )
    }

    func testOptionsFilterToServerVocabularyPreservingServerOrder() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: ["high", "low"])
        XCTAssertEqual(options.map(\.id), ["high", "low"])
        XCTAssertEqual(options.map(\.title), ["High", "Low"])
    }

    func testOptionsNormalizeAndKeepUnknownServerEfforts() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: [" Low ", "low", "", "turbo"])
        XCTAssertEqual(options.map(\.id), ["low", "turbo"])
        XCTAssertEqual(options.map(\.title), ["Low", "Turbo"])
    }

    func testShowsEffortControlFollowsServerFlag() {
        XCTAssertFalse(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: false,
            supportedEfforts: ["low"]
        ))
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: true,
            supportedEfforts: []
        ))
    }

    func testShowsEffortControlInfersFromEffortsWhenFlagMissing() {
        XCTAssertFalse(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: []
        ))
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: ["low"]
        ))
        // Older servers send neither field: keep today's behavior (visible).
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: nil
        ))
    }
}
