import Foundation

extension APIClient {
    /// Uploads a managed file to the native dashboard (`POST /api/files/upload`).
    /// The payload is a base64 `data_url` body with an explicit destination
    /// `path` (resolved under the dashboard's managed-files root) and
    /// `overwrite` enabled, matching the native handler's contract.
    func uploadFile(sessionID: String, data: Data, filename: String) async throws -> UploadResponse {
        let mimeType = Self.mimeType(for: filename)
        let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
        let body: [String: Any] = [
            "path": filename,
            "data_url": dataURL,
            "overwrite": true
        ]

        let responseData = try await sendDataReturningResponse(
            endpoint: .upload,
            method: "POST",
            encodedBody: try JSONSerialization.data(withJSONObject: body)
        ).0

        // Native `/api/files/upload` returns `{ok, entry: {name, path, size, mime_type}, path}`.
        struct NativeUploadResponse: Decodable {
            let ok: Bool?
            let path: String?
            let entry: NativeFileEntry?
        }
        struct NativeFileEntry: Decodable {
            let name: String?
            let path: String?
            let size: Int?
            let mimeType: String?
        }

        let native: NativeUploadResponse = try decode(NativeUploadResponse.self, from: responseData)
        let entry = native.entry
        let serverMime = entry?.mimeType
        let trimmedMime = serverMime?.isEmpty == true ? nil : serverMime
        let resolvedMime = trimmedMime ?? mimeType
        return UploadResponse(
            filename: entry?.name ?? entry?.path,
            path: entry?.path ?? native.path ?? filename,
            size: entry?.size,
            mime: resolvedMime,
            isImage: resolvedMime.hasPrefix("image/"),
            error: native.ok == false ? String(localized: "The server rejected the upload.") : nil
        )
    }

    private static func mimeType(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "md", "swift", "py", "js", "ts", "json", "yaml", "yml", "html", "css":
            return "text/plain"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
}
