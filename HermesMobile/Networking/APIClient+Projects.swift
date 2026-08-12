import Foundation

extension APIClient {
    /// Lists projects for the scoped profile via the `projects.tree` gateway
    /// RPC. The native project tree returns `{projects: [{id, name|label,
    /// color, primary_path, created_at, ...}], active_id}`; we map each tree
    /// node to Hermex's `ProjectSummary` so the sidebar keeps working.
    func projects(profile: String? = nil) async throws -> ProjectsResponse {
        try await withGatewayConnection(profile: profile) { client in
            let result = try await client.projects()
            let projectsArray = result.objectValue?["projects"]?.arrayValue ?? []
            let projects = projectsArray.compactMap { Self.projectSummary(fromTree: $0) }
            return ProjectsResponse(projects: projects)
        }
    }

    /// Creates a project via the `projects.create` gateway RPC. The native
    /// payload carries `folders` (the workspace paths the project owns), so
    /// rename/create keep the path-based folder contract native expects.
    func createProject(name: String, color: String?, profile: String? = nil) async throws -> ProjectMutationResponse {
        try await withGatewayConnection(profile: profile) { client in
            let result = try await client.createProject(name: name, folders: [])
            let project = Self.projectSummary(from: result.objectValue?["project"])
            return ProjectMutationResponse(ok: project != nil, project: project, error: nil)
        }
    }

    /// Renames a project via the `projects.update` gateway RPC. Native update
    /// accepts `id` + optional `name`/`color`.
    func renameProject(id: String, name: String, color: String?, profile: String? = nil) async throws -> ProjectMutationResponse {
        try await withGatewayConnection(profile: profile) { client in
            let result = try await client.updateProject(id: id, name: name, color: color)
            let project = Self.projectSummary(from: result.objectValue?["project"])
            return ProjectMutationResponse(ok: project != nil, project: project, error: nil)
        }
    }

    /// Deletes a project via the `projects.delete` gateway RPC. Native delete
    /// responds with the full `projects` payload; the UI already reloads the
    /// list after a successful delete, so only `ok` is decoded here.
    func deleteProject(id: String, profile: String? = nil) async throws -> ProjectMutationResponse {
        try await withGatewayConnection(profile: profile) { client in
            _ = try await client.deleteProject(id: id)
            return ProjectMutationResponse(ok: true, project: nil, error: nil)
        }
    }

    /// Maps a `projects.tree` node (`{id, label|name, color, primary_path,
    /// created_at}`) to `ProjectSummary`. The native tree node uses `label`,
    /// while `projects.create`/`projects.update` echo the raw project with
    /// `name`; both key-orders are tolerated.
    private static func projectSummary(fromTree value: GatewayValue) -> ProjectSummary? {
        guard let object = value.objectValue else { return nil }
        let id = object["id"]?.stringValue
        let label = object["label"]?.stringValue
            ?? object["name"]?.stringValue
        let color = object["color"]?.stringValue
        let createdAt = object["created_at"]?.doubleValue
            ?? object["createdAt"]?.doubleValue
        let name: String?
        if let label, !label.isEmpty {
            name = label
        } else {
            name = object["name"]?.stringValue
        }
        return ProjectSummary(
            projectId: id,
            name: name,
            color: color,
            createdAt: createdAt
        )
    }

    /// Maps a `projects.create`/`projects.update` result object
    /// (`{project: {id, name, color, created_at}}`) to `ProjectSummary`.
    private static func projectSummary(from value: GatewayValue?) -> ProjectSummary? {
        guard let object = value?.objectValue else { return nil }
        return ProjectSummary(
            projectId: object["id"]?.stringValue,
            name: object["name"]?.stringValue ?? object["label"]?.stringValue,
            color: object["color"]?.stringValue,
            createdAt: object["created_at"]?.doubleValue ?? object["createdAt"]?.doubleValue
        )
    }
}
