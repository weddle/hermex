import Foundation

extension APIClient {
    func memory() async throws -> MemoryResponse {
        let profiles = try await profiles()
        guard let home = profiles.profiles?.first(where: { $0.normalizedName == profiles.effectiveDefaultProfileName })?.path
            ?? profiles.profiles?.first?.path else {
            throw APIError.decoding(underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "The server did not report a Hermes profile path.")
            ))
        }

        async let memoryFile = readMemoryFile(path: "\(home)/memories/MEMORY.md")
        async let userFile = readMemoryFile(path: "\(home)/memories/USER.md")
        async let soulFile = readMemoryFile(path: "\(home)/SOUL.md")
        let files = await (memoryFile, userFile, soulFile)
        return MemoryResponse(
            memory: files.0?.text,
            user: files.1?.text,
            soul: files.2?.text,
            memoryPath: files.0?.path,
            userPath: files.1?.path,
            soulPath: files.2?.path
        )
    }

    func writeMemory(section: MemorySection, content: String) async throws -> MemoryWriteResponse {
        let profiles = try await profiles()
        guard let home = profiles.profiles?.first(where: { $0.normalizedName == profiles.effectiveDefaultProfileName })?.path
            ?? profiles.profiles?.first?.path else {
            throw APIError.decoding(underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "The server did not report a Hermes profile path.")
            ))
        }
        let path = section.path(relativeTo: home)
        let response: NativeMemoryWriteResponse = try await send(
            endpoint: .memoryFileWrite,
            method: "POST",
            body: NativeMemoryWriteRequest(path: path, content: content)
        )
        return MemoryWriteResponse(ok: response.ok, section: section, path: response.path, error: nil)
    }

    private func readMemoryFile(path: String) async -> NativeMemoryFile? {
        do {
            return try await send(endpoint: .memoryFile(path: path), method: "GET")
        } catch let APIError.http(statusCode, _) where statusCode == 404 {
            return nil
        } catch {
            return nil
        }
    }
}

private struct NativeMemoryFile: Decodable {
    let text: String?
    let path: String?
}

private struct NativeMemoryWriteRequest: Encodable {
    let path: String
    let content: String
}

private struct NativeMemoryWriteResponse: Decodable {
    let ok: Bool?
    let path: String?
}

private extension MemorySection {
    func path(relativeTo home: String) -> String {
        switch self {
        case .memory: return "\(home)/memories/MEMORY.md"
        case .user: return "\(home)/memories/USER.md"
        case .soul: return "\(home)/SOUL.md"
        }
    }
}

