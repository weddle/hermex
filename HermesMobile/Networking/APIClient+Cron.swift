import Foundation

extension APIClient {
    /// Lists cron jobs across all profiles (native default `profile=all`).
    func crons() async throws -> CronJobsResponse {
        try await send(endpoint: .crons, method: "GET")
    }

    func createCron(
        prompt: String,
        schedule: String,
        name: String?,
        deliver: String?,
        skills: [String],
        model: String?,
        provider: String?,
        profile: String?,
        toastNotifications: Bool
    ) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronCreate,
            method: "POST",
            body: CronCreateRequest(
                prompt: prompt,
                schedule: schedule,
                name: name,
                deliver: deliver,
                skills: skills,
                model: model,
                provider: provider,
                profile: profile,
                toastNotifications: toastNotifications
            )
        )
    }

    /// Native PUT `/api/cron/jobs/{id}` accepts `{"updates": {...}}`; the dashboards
    /// tolerant decoder reads the returned job record.
    func updateCron(
        jobID: String,
        prompt: String?,
        schedule: String?,
        name: String?,
        deliver: String?,
        skills: [String]?,
        model: String?,
        provider: String?,
        profile: String?,
        toastNotifications: Bool?
    ) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronUpdate(jobID: jobID),
            method: "PUT",
            body: CronUpdateRequest(
                updates: CronUpdateRequest.Updates(
                    prompt: prompt,
                    schedule: schedule,
                    name: name,
                    deliver: deliver,
                    skills: skills,
                    model: model,
                    provider: provider,
                    profile: profile
                )
            )
        )
    }

    func cronDeliveryOptions() async throws -> CronDeliveryOptionsResponse {
        try await send(endpoint: .cronDeliveryOptions, method: "GET")
    }

    func deleteCron(jobID: String) async throws -> CronMutationResponse {
        try await send(endpoint: .cronDelete(jobID: jobID), method: "DELETE")
    }

    func runCron(jobID: String) async throws -> CronMutationResponse {
        try await send(endpoint: .cronRun(jobID: jobID), method: "POST")
    }

    func pauseCron(jobID: String, reason: String? = nil) async throws -> CronMutationResponse {
        var updates: [String: String] = [:]
        if let reason, !reason.isEmpty {
            updates["paused_reason"] = reason
        }
        return try await send(
            endpoint: .cronPause(jobID: jobID),
            method: "POST",
            body: updates.isEmpty ? nil : CronReasonBody(reason: reason)
        )
    }

    func resumeCron(jobID: String) async throws -> CronMutationResponse {
        try await send(endpoint: .cronResume(jobID: jobID), method: "POST")
    }

    /// Native GET `/api/cron/jobs/{id}/runs` returns the job's run sessions
    /// (newest first), not output files. Mapped into `CronOutputItem` rows so the
    /// existing detail UI can render them.
    func cronRuns(jobID: String, limit: Int? = 5) async throws -> CronOutputResponse {
        try await send(endpoint: .cronRuns(jobID: jobID, limit: limit), method: "GET")
    }
}

private struct CronCreateRequest: Encodable {
    let prompt: String
    let schedule: String
    let name: String?
    let deliver: String?
    let skills: [String]
    let model: String?
    let provider: String?
    let profile: String?
    let toastNotifications: Bool
}

private struct CronUpdateRequest: Encodable {
    struct Updates: Encodable {
        let prompt: String?
        let schedule: String?
        let name: String?
        let deliver: String?
        let skills: [String]?
        let model: String?
        let provider: String?
        let profile: String?
    }

    let updates: Updates
}

private struct CronReasonBody: Encodable {
    let reason: String?
}
