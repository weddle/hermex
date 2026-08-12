import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientCronEndpointTests: APIClientTestCase {
    func testCronsBuildsExpectedPathAndDecodesTolerantJobList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)

            // Native `/api/cron/jobs` returns a bare array of job records.
            return apiTestJSONResponse("""
            [
              {
                "id": "job123",
                "name": "Morning digest",
                "prompt": "Summarize overnight activity",
                "schedule": {"kind": "cron", "expr": "0 7 * * *", "unexpected": true},
                "schedule_display": "0 7 * * *",
                "enabled": true,
                "state": "scheduled",
                "next_run_at": "2026-05-05T11:00:00Z",
                "last_run_at": 1777892400,
                "last_status": "ok",
                "deliver": "local",
                "skills": ["summarize", "notify"],
                "ignored_new_field": {"nested": "value"}
              },
              {
                "id": "legacy-broken",
                "schedule": {"kind": "cron", "expr": "0 8 * * *"},
                "repeat": {"times": null, "completed": 17},
                "enabled": false,
                "state": "completed",
                "next_run_at": null,
                "last_status": "ok"
              }
            ]
            """, for: request)
        }

        let response = try await client.crons()
        let first = try XCTUnwrap(response.jobs?.first)
        let second = try XCTUnwrap(response.jobs?.last)

        XCTAssertEqual(first.jobId, "job123")
        XCTAssertEqual(first.displayName, "Morning digest")
        XCTAssertEqual(first.scheduleText, "0 7 * * *")
        let nextRunAt = try XCTUnwrap(first.nextRunAt)
        let lastRunAt = try XCTUnwrap(first.lastRunAt)
        XCTAssertEqual(nextRunAt.date.timeIntervalSince1970, 1_777_978_800, accuracy: 0.1)
        XCTAssertEqual(lastRunAt.date.timeIntervalSince1970, 1_777_892_400, accuracy: 0.1)
        XCTAssertFalse(nextRunAt.formatted.isEmpty)
        XCTAssertEqual(first.skills, ["summarize", "notify"])
        XCTAssertEqual(first.status, .active)

        XCTAssertEqual(second.status, .needsAttention)
        XCTAssertEqual(second.displayName, "0 8 * * *")
    }

    func testCronRunsBuildsExpectedPathAndDecodesRunSessions() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job123/runs")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["limit"], "5")

            return apiTestJSONResponse("""
            {
              "runs": [
                {
                  "session_id": "run-1",
                  "title": "2026-05-04_10-00-00.md",
                  "started_at": 1777892400,
                  "created_at": 1777806000,
                  "model": "gpt-5.4",
                  "profile": "work"
                },
                {
                  "session_id": "run-2",
                  "title": "2026-05-04_09-00-00.md",
                  "started_at": 1777858800
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.cronRuns(jobID: "job123", limit: 5)

        XCTAssertEqual(response.outputs?.count, 2)
        XCTAssertEqual(response.outputs?.first?.filename, "2026-05-04_10-00-00.md")
        XCTAssertEqual(response.outputs?.first?.runID, "run-1")
        XCTAssertEqual(response.outputs?.first?.runStartedAt, 1_777_892_400)
        XCTAssertEqual(response.outputs?.last?.filename, "2026-05-04_09-00-00.md")
        XCTAssertNil(response.outputs?.first?.content)
    }

    func testCronCreateBuildsExpectedBodyAndDecodesBareJob() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["prompt"] as? String, "Summarize overnight activity")
            XCTAssertEqual(body?["schedule"] as? String, "0 7 * * *")
            XCTAssertEqual(body?["name"] as? String, "Morning digest")
            XCTAssertEqual(body?["deliver"] as? String, "local")
            XCTAssertEqual(body?["skills"] as? [String], ["summarize", "notify"])
            XCTAssertEqual(body?["model"] as? String, "@openai:gpt-5.5")
            XCTAssertNil(body?["provider"], "Omitted provider must not be sent so the server default applies.")
            XCTAssertEqual(body?["profile"] as? String, "work")
            XCTAssertEqual(body?["toast_notifications"] as? Bool, true)

            // Native create returns the created job record directly.
            return apiTestJSONResponse("""
            {
              "id": "job-new",
              "name": "Morning digest",
              "prompt": "Summarize overnight activity",
              "schedule": "0 7 * * *",
              "enabled": true,
              "state": "scheduled",
              "model": "@openai:gpt-5.5",
              "profile": "work",
              "toast_notifications": true
            }
            """, for: request)
        }

        let response = try await client.createCron(
            prompt: "Summarize overnight activity",
            schedule: "0 7 * * *",
            name: "Morning digest",
            deliver: "local",
            skills: ["summarize", "notify"],
            model: "@openai:gpt-5.5",
            provider: nil,
            profile: "work",
            toastNotifications: true
        )

        XCTAssertEqual(response.job?.jobId, "job-new")
        XCTAssertEqual(response.job?.scheduleText, "0 7 * * *")
        XCTAssertEqual(response.job?.displayName, "Morning digest")
        XCTAssertEqual(response.job?.model, "@openai:gpt-5.5")
        XCTAssertEqual(response.job?.toastNotifications, true)
    }

    func testCronUpdateBuildsExpectedBodyAndDecodesBareJob() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job123")
            XCTAssertEqual(request.httpMethod, "PUT")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let updates = try XCTUnwrap(body?["updates"] as? [String: Any])
            XCTAssertEqual(updates["prompt"] as? String, "Updated prompt")
            XCTAssertEqual(updates["schedule"] as? String, "0 8 * * *")
            XCTAssertEqual(updates["name"] as? String, "Updated digest")
            XCTAssertEqual(updates["deliver"] as? String, "local")
            XCTAssertEqual(updates["skills"] as? [String], ["swift"])
            XCTAssertEqual(updates["model"] as? String, "@anthropic:claude")
            XCTAssertEqual(updates["provider"] as? String, "anthropic")
            XCTAssertEqual(updates["profile"] as? String, "personal")

            return apiTestJSONResponse("""
            {
              "id": "job123",
              "name": "Updated digest",
              "prompt": "Updated prompt",
              "schedule": {"kind": "cron", "expr": "0 8 * * *"},
              "enabled": true,
              "state": "scheduled",
              "model": "@anthropic:claude",
              "provider": "anthropic",
              "profile": "personal",
              "toast_notifications": false
            }
            """, for: request)
        }

        let response = try await client.updateCron(
            jobID: "job123",
            prompt: "Updated prompt",
            schedule: "0 8 * * *",
            name: "Updated digest",
            deliver: "local",
            skills: ["swift"],
            model: "@anthropic:claude",
            provider: "anthropic",
            profile: "personal",
            toastNotifications: false
        )

        XCTAssertEqual(response.job?.jobId, "job123")
        XCTAssertEqual(response.job?.displayName, "Updated digest")
        XCTAssertEqual(response.job?.scheduleText, "0 8 * * *")
        XCTAssertEqual(response.job?.model, "@anthropic:claude")
        XCTAssertEqual(response.job?.provider, "anthropic")
        XCTAssertEqual(response.job?.toastNotifications, false)
    }

    func testCronCreateSendsProviderWhenSet() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["provider"] as? String, "openai")

            return apiTestJSONResponse("""
            {
              "id": "job-provider",
              "prompt": "Run it",
              "schedule": "0 7 * * *",
              "provider": "openai"
            }
            """, for: request)
        }

        let response = try await client.createCron(
            prompt: "Run it",
            schedule: "0 7 * * *",
            name: nil,
            deliver: nil,
            skills: [],
            model: nil,
            provider: "openai",
            profile: nil,
            toastNotifications: true
        )

        XCTAssertEqual(response.job?.provider, "openai")
    }

    func testCronDeliveryOptionsBuildsExpectedPathAndDecodesTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/delivery-targets")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)

            // Native `/api/cron/delivery-targets` returns `{targets: [{id, name}]}`.
            return apiTestJSONResponse("""
            {
              "targets": [
                {"id": "local", "name": "Local (save output only)"},
                {"id": "origin", "name": "Origin (reply to creator)"},
                {"id": "slack", "name": "Slack", "unexpected_field": {"nested": true}},
                {"id": "telegram"}
              ],
              "ignored_new_field": 7
            }
            """, for: request)
        }

        let response = try await client.cronDeliveryOptions()
        let platforms = try XCTUnwrap(response.platforms)

        XCTAssertEqual(platforms.map(\.value), ["local", "origin", "slack", "telegram"])
        XCTAssertEqual(platforms.first?.label, "Local (save output only)")
        XCTAssertNil(platforms.last?.label)
    }

    func testCronDeliveryOptionsToleratesUnexpectedPlatformsShape() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"targets": "unexpected"}"#, for: request)
        }

        let response = try await client.cronDeliveryOptions()

        XCTAssertNil(response.platforms)
    }

    func testCronJobIDMutationsBuildExpectedPathsAndBodies() async throws {
        var expectedRequests: [(path: String, method: String, reason: String?)] = [
            ("/api/cron/jobs/job123/trigger", "POST", nil),
            ("/api/cron/jobs/job123/pause", "POST", "Manual pause"),
            ("/api/cron/jobs/job123/resume", "POST", nil),
            ("/api/cron/jobs/job123", "DELETE", nil)
        ]

        let client = makeClient { request in
            let expected = expectedRequests.removeFirst()
            XCTAssertEqual(request.url?.path, expected.path)
            XCTAssertEqual(request.httpMethod, expected.method)

            if let reason = expected.reason {
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual(body?["reason"] as? String, reason)
            } else {
                XCTAssertNil(apiTestBodyData(from: request), "No body expected for \(expected.path)")
            }

            return apiTestJSONResponse("""
            {
              "id": "job123",
              "name": "Digest",
              "enabled": true,
              "state": "scheduled"
            }
            """, for: request)
        }

        let runResponse = try await client.runCron(jobID: "job123")
        let pauseResponse = try await client.pauseCron(jobID: "job123", reason: "Manual pause")
        let resumeResponse = try await client.resumeCron(jobID: "job123")
        let deleteResponse = try await client.deleteCron(jobID: "job123")

        XCTAssertEqual(runResponse.job?.jobId, "job123")
        XCTAssertEqual(pauseResponse.job?.jobId, "job123")
        XCTAssertEqual(resumeResponse.job?.jobId, "job123")
        XCTAssertEqual(deleteResponse.job?.jobId, "job123")
        XCTAssertTrue(expectedRequests.isEmpty)
    }

    func testCronRunsOmitsLimitWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job456/runs")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertNil(query["limit"])

            return apiTestJSONResponse("""
            {
              "runs": []
            }
            """, for: request)
        }

        let response = try await client.cronRuns(jobID: "job456", limit: nil)
        XCTAssertEqual(response.outputs?.count, 0)
    }
}
