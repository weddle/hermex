import Foundation

// Tolerant, read-only models for the native Hermes Agent dashboard git router
// (`web_routers/git.py`). The router is PATH-based: every request carries the
// working-directory path the server resolves. All reads degrade to empty/nil on
// a non-repo; mutations raise (→ 400 with a message).
//
// Every field is optional and unknown keys are ignored so the app never crashes on a
// field the server adds or renames (hard rule #3). The shared `APIClient` decoder uses
// `.convertFromSnakeCase`, so snake_case JSON keys map onto these camelCase properties
// automatically.
//
// Native contracts:
// - GET /api/git/status?path= → flat repo status dict (branch, ahead, behind, staged_,
//   unstaged_, untracked_, conflicted_, changed, added, removed, files[]) or null
// - GET /api/git/branches?path= → bare array [{name, checkedOut, isDefault, worktreePath}]
// - GET /api/git/review/diff?path=&file=&scope=&staged= → {"diff": "…"}
// - POST /api/git/review/stage|unstage|revert {path, file} → {"ok": true}
// - POST /api/git/review/commit {path, message, push} → {"ok": true}
// - POST /api/git/review/push {path} → {"ok": true}
// - POST /api/git/branch/switch {path, branch} → {"branch": "…"}

// MARK: - git/status

struct GitStatusResponse: Decodable, Equatable {
    let git: GitStatus?
}

struct GitStatus: Decodable, Equatable {
    let branch: String?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let staged: Int?
    let unstaged: Int?
    let untracked: Int?
    let conflicted: Int?
    let changed: Int?
    let added: Int?
    let removed: Int?
    let files: [GitFile]?

    /// Native status has no `is_git` flag; a non-repo returns an HTTP error or an
    /// empty/null payload. Defaults to `true` (a decoded status means a repo).
    var isGit: Bool? { true }

    /// Changed files excluding ignored entries, mirroring the legacy `trackedFiles`.
    var trackedFiles: [GitFile] {
        (files ?? []).filter { !$0.isIgnoredFile }
    }

    /// Total added/deleted lines across non-ignored files.
    var totalAdditions: Int { trackedFiles.reduce(0) { $0 + ($1.additions ?? 0) } }
    var totalDeletions: Int { trackedFiles.reduce(0) { $0 + ($1.deletions ?? 0) } }

    /// Changed-file count from the server's `changed` count.
    var changedCount: Int { changed ?? trackedFiles.count }

    var isNonRepositoryState: Bool {
        (files ?? []).isEmpty && changed == nil
    }
}

struct GitFile: Decodable, Equatable, Identifiable {
    var id: String { path ?? UUID().uuidString }

    let path: String?
    let staged: Bool?
    let unstaged: Bool?
    let untracked: Bool?
    let conflicted: Bool?
    /// Native status does not carry per-file add/delete counts; defaults to nil and
    /// the UI falls back to showing no counts.
    let additions: Int?
    let deletions: Int?
    /// Last path component, e.g. `ContentView.swift`.
    var fileName: String {
        let value = displayPath
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    /// Parent directory shown as secondary text, or `nil` at the repo root.
    var parentDirectory: String? {
        let parts = displayPath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }
}

extension GitFile {
    enum ChangeKind: Equatable {
        case conflict
        case untracked
        case added
        case deleted
        case renamed
        case modified
        case ignored
        case unknown
    }

    var changeKind: ChangeKind {
        if conflicted == true { return .conflict }
        if untracked == true { return .untracked }
        if staged == true || unstaged == true { return .modified }
        return .unknown
    }

    var displayPath: String {
        path ?? ""
    }

    var isIgnoredFile: Bool { false }

    /// The diff query uses staged content for staged-only changes, unstaged otherwise.
    var preferredDiffKind: String {
        (staged == true && unstaged != true) ? "staged" : "unstaged"
    }
}

// MARK: - git/branches

struct GitBranchesResponse: Decodable, Equatable {
    let branches: GitBranches?
}

struct GitBranches: Decodable, Equatable {
    let current: String?
    let local: [GitBranchRef]?
    let remote: [GitBranchRef]?

    init(current: String?, local: [GitBranchRef]?, remote: [GitBranchRef]?) {
        self.current = current
        self.local = local
        self.remote = remote
    }

    init(from decoder: Decoder) throws {
        // The native route returns a bare array of branches; the decoder injects the
        // wrapper here so call sites can keep using `GitBranches.local`.
        let container = try decoder.singleValueContainer()
        let refs = try container.decode([GitBranchRef].self)
        current = nil
        local = refs
        remote = []
    }
}

struct GitBranchRef: Decodable, Equatable {
    let name: String?
    let checkedOut: Bool?
    let isDefault: Bool?
    let worktreePath: String?
}

enum GitBranchMode: String, Equatable {
    case local
    case remote
}

struct GitCheckoutTarget: Equatable, Identifiable {
    let ref: String
    let mode: GitBranchMode
    var newBranch: String? = nil
    var track = false

    var id: String { "\(mode.rawValue):\(ref):\(newBranch ?? "")" }
    var displayName: String { newBranch ?? ref }
}

/// Response for `branch/switch` — `{"branch": "…"}`. The tree's branch list is
/// refreshed afterward, so no status payload is needed on the wire.
struct GitBranchSwitchResponse: Decodable, Equatable {
    let branch: String?
}

/// Response for `stage`/`unstage`/`revert`/`commit`/`push` — `{"ok": true}`.
struct GitMutationResponse: Decodable, Equatable {
    let ok: Bool?
    let error: String?
}

// MARK: - git/diff (per-file unified diff)

struct GitDiffResponse: Decodable, Equatable {
    let diff: GitDiff?
}

struct GitDiff: Decodable, Equatable {
    let path: String?
    let kind: String?
    let binary: Bool?
    let tooLarge: Bool?
    let additions: Int?
    let deletions: Int?
    /// Unified diff text. Empty for binary or too-large diffs.
    let diff: String?
}
