import XCTest
@testable import HermesMobile

/// Request construction + tolerant decoding for the native Hermes Agent dashboard
/// path-based git endpoints (`web_routers/git.py`) — `/api/git/status`,
/// `/api/git/branches`, `/api/git/review/diff`, and the write routes. Every
/// request is scoped by the workspace `path`. Mirrors `APIClientWorkspaceFileTests`.
final class APIClientGitTests: APIClientTestCase {

    private func query(_ request: URLRequest) throws -> [String: String?] {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
    }

    private func errorResponse(_ json: String, status: Int, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(apiTestBodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - git/status

    func testGitStatusBuildsExpectedPathQueryAndDecodesFiles() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/status")
            XCTAssertEqual(request.httpMethod, "GET")
            let q = try self.query(request)
            XCTAssertEqual(q["path"], "/tmp/workspace/repo")
            XCTAssertNil(q["session_id"])

            return apiTestJSONResponse("""
            {
              "git": {
                "branch": "feature/foo",
                "upstream": "origin/feature/foo",
                "ahead": 1,
                "behind": 2,
                "changed": 2,
                "staged": 1,
                "unstaged": 1,
                "untracked": 1,
                "conflicted": 0,
                "files": [
                  {
                    "path": "Sources/App.swift",
                    "staged": false,
                    "unstaged": true,
                    "untracked": false,
                    "conflicted": false,
                    "additions": 10,
                    "deletions": 4
                  },
                  {
                    "path": "New.swift",
                    "staged": false,
                    "unstaged": false,
                    "untracked": true,
                    "conflicted": false,
                    "additions": 0,
                    "deletions": 0
                  }
                ]
              }
            }
            """, for: request)
        }

        let statusResponse = try await client.gitStatus(path: "/tmp/workspace/repo")
        let status = try XCTUnwrap(statusResponse.git)

        XCTAssertEqual(status.branch, "feature/foo")
        XCTAssertEqual(status.upstream, "origin/feature/foo")
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(status.behind, 2)
        XCTAssertEqual(status.changedCount, 2)
        XCTAssertEqual(status.files?.count, 2)
        XCTAssertEqual(status.trackedFiles.count, 2)
        XCTAssertEqual(status.totalAdditions, 10)
        XCTAssertEqual(status.totalDeletions, 4)
        // Change kind is derived from the booleans.
        XCTAssertEqual(status.trackedFiles[0].changeKind, .modified)
        XCTAssertEqual(status.trackedFiles[1].changeKind, .untracked)
        XCTAssertEqual(status.trackedFiles[0].fileName, "App.swift")
        XCTAssertEqual(status.trackedFiles[0].parentDirectory, "Sources")
    }

    func testGitStatusDecodesNonRepository() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"git": null}"#, for: request)
        }

        let statusResponse = try await client.gitStatus(path: "/tmp/repo")
        XCTAssertNil(statusResponse.git)
    }

    func testGitStatusToleratesMissingFieldsAndUnknownKeys() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "git": {
                "branch": "main",
                "files": [
                  {"path": "a.txt", "staged": true, "future_field": 99}
                ],
                "totally_new_key": {"nested": true}
              }
            }
            """, for: request)
        }

        let statusResponse = try await client.gitStatus(path: "/tmp/repo")
        let status = try XCTUnwrap(statusResponse.git)
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.changed)
        XCTAssertNil(status.upstream)
        let file = try XCTUnwrap(status.files?.first)
        XCTAssertEqual(file.path, "a.txt")
        XCTAssertNil(file.additions)
        XCTAssertEqual(file.changeKind, .modified)
        // changedCount falls back to the tracked-file count.
        XCTAssertEqual(status.changedCount, 1)
    }

    // MARK: - git/branches

    func testGitBranchesBuildsExpectedPathQueryAndDecodesBareArray() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/branches")
            XCTAssertEqual(request.httpMethod, "GET")
            let q = try self.query(request)
            XCTAssertEqual(q["path"], "/tmp/repo")
            XCTAssertNil(q["session_id"])

            // The native route returns a bare array of branch refs.
            return apiTestJSONResponse("""
            [
              {"name": "main", "checked_out": true, "is_default": true, "worktree_path": null, "future_field": true},
              {"name": "dev", "checked_out": false, "is_default": false, "worktree_path": null}
            ]
            """, for: request)
        }

        let branchesResponse = try await client.gitBranches(path: "/tmp/repo")
        let branches = try XCTUnwrap(branchesResponse.branches)

        XCTAssertEqual(branches.local?.map(\.name), ["main", "dev"])
        XCTAssertEqual(branches.local?.first?.checkedOut, true)
        XCTAssertEqual(branches.local?.first?.isDefault, true)
        XCTAssertTrue((branches.remote ?? []).isEmpty)
    }

    // MARK: - git/review/diff

    func testGitDiffBuildsExpectedPathQueryWithStagedKindAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/review/diff")
            XCTAssertEqual(request.httpMethod, "GET")
            let q = try self.query(request)
            XCTAssertEqual(q["path"], "/tmp/repo")
            XCTAssertEqual(q["file"], "Sources/App.swift")
            XCTAssertEqual(q["scope"], "uncommitted")
            XCTAssertEqual(q["staged"], "true")
            XCTAssertNil(q["session_id"])

            return apiTestJSONResponse("""
            {
              "diff": {
                "path": "Sources/App.swift",
                "kind": "staged",
                "binary": false,
                "too_large": false,
                "additions": 3,
                "deletions": 1,
                "diff": "@@ -1 +1 @@\\n-old\\n+new\\n"
              }
            }
            """, for: request)
        }

        let diffResponse = try await client.gitDiff(path: "/tmp/repo", file: "Sources/App.swift", kind: "staged")
        let diff = try XCTUnwrap(diffResponse.diff)

        XCTAssertEqual(diff.path, "Sources/App.swift")
        XCTAssertEqual(diff.kind, "staged")
        XCTAssertEqual(diff.binary, false)
        XCTAssertEqual(diff.tooLarge, false)
        XCTAssertEqual(diff.additions, 3)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testGitDiffDefaultsKindToUnstaged() async throws {
        let client = makeClient { request in
            let q = try self.query(request)
            XCTAssertEqual(q["staged"], "false")
            return apiTestJSONResponse(#"{"diff": {"diff": ""}}"#, for: request)
        }

        let diffResponse = try await client.gitDiff(path: "/tmp/repo", file: "a.txt")
        let diff = try XCTUnwrap(diffResponse.diff)
        XCTAssertEqual(diff.kind, nil)
    }

    func testGitDiffDecodesBinaryAndTooLarge() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"diff": {"path": "Assets/icon.png", "binary": true, "too_large": false, "diff": ""}}
            """, for: request)
        }

        let diffResponse = try await client.gitDiff(path: "/tmp/repo", file: "Assets/icon.png")
        let diff = try XCTUnwrap(diffResponse.diff)
        XCTAssertEqual(diff.binary, true)
        XCTAssertEqual(diff.tooLarge, false)
        XCTAssertEqual(diff.diff, "")
    }

    func testGitDiffNonRepositorySurfacesHTTPError() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"not a git repository"}"#.utf8))
        }

        do {
            _ = try await client.gitDiff(path: "/tmp/repo", file: "a.txt")
            XCTFail("Expected non-repo HTTP error")
        } catch {
            let error = try XCTUnwrap(error as? APIError)
            XCTAssertEqual(error.serverMessage, "not a git repository")
        }
    }

    // MARK: - git writes

    func testGitCycleStageCommitPushBuildExpectedBodies() async throws {
        var methods: [String] = []
        var paths: [String] = []
        var bodies: [[String: Any]] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            paths.append(request.url?.path ?? "")
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        let stage = try await client.gitStage(path: "/tmp/repo", file: "a.txt")
        let commit = try await client.gitCommit(path: "/tmp/repo", message: "Ship it", push: true)
        let push = try await client.gitPush(path: "/tmp/repo")

        XCTAssertEqual(stage.ok, true)
        XCTAssertEqual(commit.ok, true)
        XCTAssertEqual(push.ok, true)
        XCTAssertEqual(methods, ["POST", "POST", "POST"])
        XCTAssertEqual(paths, [
            "/api/git/review/stage",
            "/api/git/review/commit",
            "/api/git/review/push"
        ])

        // Stage body: {path, file}.
        XCTAssertEqual(bodies[0]["path"] as? String, "/tmp/repo")
        XCTAssertEqual(bodies[0]["file"] as? String, "a.txt")
        // Commit body: {path, message, push}.
        XCTAssertEqual(bodies[1]["path"] as? String, "/tmp/repo")
        XCTAssertEqual(bodies[1]["message"] as? String, "Ship it")
        XCTAssertEqual(bodies[1]["push"] as? Bool, true)
        // Push body: {path}.
        XCTAssertEqual(bodies[2]["path"] as? String, "/tmp/repo")
        XCTAssertNil(bodies[2]["file"])
    }

    func testGitUnstageAndRevertBuildBodies() async throws {
        var bodies: [[String: Any]] = []
        var paths: [String] = []
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        _ = try await client.gitUnstage(path: "/tmp/repo", file: nil)
        _ = try await client.gitRevert(path: "/tmp/repo", file: "b.txt")

        XCTAssertEqual(paths, ["/api/git/review/unstage", "/api/git/review/revert"])
        // A nil file is omitted from the JSON body.
        XCTAssertNil(bodies[0]["file"])
        XCTAssertEqual(bodies[0]["path"] as? String, "/tmp/repo")
        XCTAssertEqual(bodies[1]["file"] as? String, "b.txt")
    }

    func testGitBranchSwitchBuildsBodyAndDecodesBranch() async throws {
        var body: [String: Any]?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/branch/switch")
            XCTAssertEqual(request.httpMethod, "POST")
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return apiTestJSONResponse(#"{"branch": "dev"}"#, for: request)
        }

        let response = try await client.gitBranchSwitch(path: "/tmp/repo", branch: "dev")

        XCTAssertEqual(response.branch, "dev")
        XCTAssertEqual(body?["path"] as? String, "/tmp/repo")
        XCTAssertEqual(body?["branch"] as? String, "dev")
    }

    func testGitWriteErrorSurfacesStructuredServerMessage() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"code":"dirty_worktree","message":"Working tree is dirty"}"#.utf8))
        }

        do {
            _ = try await client.gitCommit(path: "/tmp/repo", message: "x")
            XCTFail("Expected git write error")
        } catch {
            let error = try XCTUnwrap(error as? APIError)
            XCTAssertEqual(error.serverCode, "dirty_worktree")
            XCTAssertEqual(error.serverMessage, "Working tree is dirty")
        }
    }
}
