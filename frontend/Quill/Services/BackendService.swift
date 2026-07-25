import Foundation

enum BackendError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case httpError(Int, String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .decodingError(let e): return "Decoding error: \(e)"
        }
    }
}

actor BackendService {
    static let shared = BackendService()

    private let baseURL = "http://127.0.0.1:5323"
    private let session: URLSession

    // Timeouts for LLM-backed operations (long-form generation, multi-pass
    // book writing, etc.) need to be much longer than 30s. Local Ollama can
    // take 60-120s for big generations, especially on first load.
    private static let requestTimeout: TimeInterval = 600  // 10 min
    private static let resourceTimeout: TimeInterval = 1800  // 30 min

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.resourceTimeout
        // Don't retry — the backend has its own retry logic and the user
        // should see a clear error if a request really fails.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw BackendError.invalidURL(baseURL + path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let req = try makeRequest(path: path)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackendError.decodingError(error)
        }
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let req = try makeRequest(path: path, method: "POST", body: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackendError.decodingError(error)
        }
    }

    func put(_ path: String, body: [String: Any]) async throws {
        let req = try makeRequest(path: path, method: "PUT", body: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }
    }

    func getRaw(_ path: String) async throws -> Data {
        let req = try makeRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }
        return data
    }

    func delete(_ path: String) async throws {
        let req = try makeRequest(path: path, method: "DELETE")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }
    }

    struct EditFixResult: Decodable {
        let text: String
        let slotId: String?
        let modelId: String?
        let originalChars: Int?
        let fixedChars: Int?
        let instruction: String?

        enum CodingKeys: String, CodingKey {
            case text
            case slotId = "slot_id"
            case modelId = "model_id"
            case originalChars = "original_chars"
            case fixedChars = "fixed_chars"
            case instruction
        }
    }

    struct EditFixError: Decodable {
        let error: String
    }

    /// Call the Zed-style /api/edit-fix endpoint. Returns the fixed text
    /// (with whitespace already cleaned up by the backend).
    func editFix(text: String, instruction: String = "fix typos and grammar", slotId: String? = nil) async throws -> EditFixResult {
        var body: [String: Any] = [
            "text": text,
            "instruction": instruction,
        ]
        if let slotId = slotId { body["slot_id"] = slotId }
        let req = try makeRequest(path: "/api/edit-fix", method: "POST", body: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode == 400 {
            // Try to extract the error message
            if let err = try? JSONDecoder().decode(EditFixError.self, from: data) {
                throw BackendError.httpError(400, err.error)
            }
            throw BackendError.httpError(400, String(data: data, encoding: .utf8) ?? "Bad request")
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }
        do {
            return try JSONDecoder().decode(EditFixResult.self, from: data)
        } catch {
            throw BackendError.decodingError(error)
        }
    }

    func streamPost(
        _ path: String,
        body: [String: Any],
        onContinue: @escaping (String) -> Bool,
        onToken: @escaping (String) -> Void,
        onFileOp: @escaping (FileOpEvent) -> Void = { _ in }
    ) async throws {
        let req = try makeRequest(path: path, method: "POST", body: body)
        let (bytes, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.networkError(NSError(domain: "", code: -1, userInfo: nil))
        }
        if http.statusCode >= 400 {
            let msg = String(data: bytes, encoding: .utf8) ?? "Unknown error"
            throw BackendError.httpError(http.statusCode, msg)
        }

        guard let text = String(data: bytes, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data: ") {
                let jsonStr = String(trimmed.dropFirst(6))
                if jsonStr == "[DONE]" {
                    _ = onContinue("[DONE]")
                    break
                }
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let fileOp = json["file_op"] as? [String: Any] {
                        let event = FileOpEvent(
                            op: fileOp["op"] as? String ?? "",
                            target: fileOp["target"] as? String ?? "",
                            detail: fileOp["detail"] as? String ?? "",
                            success: fileOp["success"] as? Bool ?? false,
                            error: fileOp["error"] as? String ?? ""
                        )
                        onFileOp(event)
                        continue
                    }
                    if let token = json["token"] as? String {
                        if !onContinue(token) { break }
                        onToken(token)
                    }
                }
            }
        }
    }

    /// Stream a /api/chat response. Calls `onToken` for each streamed token,
    /// `onDone` with the final metadata (e.g. `chapter_written`, `email`),
    /// and `onError` on failure.
    func streamChat(
        payload: [String: Any],
        onToken: @escaping (String) -> Void,
        onDone: @escaping ([String: Any]) -> Void = { _ in },
        onError: @escaping (String) -> Void = { _ in }
    ) async throws {
        let req = try makeRequest(path: "/api/chat", method: "POST", body: payload)
        let (bytes, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            onError("invalid response")
            return
        }
        if http.statusCode >= 400 {
            let msg = String(data: bytes, encoding: .utf8) ?? "Unknown error"
            onError("HTTP \(http.statusCode): \(msg)")
            return
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            onError("could not decode response")
            return
        }
        var finalMeta: [String: Any] = [:]
        var streamedAny = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("data: ") { continue }
            let jsonStr = String(trimmed.dropFirst(6))
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let token = json["token"] as? String {
                    onToken(token)
                    streamedAny = true
                }
                if let err = json["error"] as? String {
                    onError(err)
                }
                if json["done"] as? Bool == true {
                    // Carry forward any non-token fields
                    for (k, v) in json {
                        if k != "token" && k != "done" {
                            finalMeta[k] = v
                        }
                    }
                }
            }
        }
        if !streamedAny && finalMeta.isEmpty {
            // Non-streaming JSON response (stream=false)
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let txt = json["text"] as? String {
                    onToken(txt)
                }
                for (k, v) in json where k != "text" {
                    finalMeta[k] = v
                }
            }
        }
        onDone(finalMeta)
    }
}

// MARK: - File Operation Event
struct FileOpEvent {
    let op: String
    let target: String
    let detail: String
    let success: Bool
    let error: String

    var summary: String {
        switch op {
        case "create_chapter":
            return success ? "✅ Created chapter: \(target).md" : "❌ \(error)"
        case "rename_chapter":
            return success ? "✅ Renamed chapter: \(detail)" : "❌ \(error)"
        case "delete_chapter":
            return success ? "✅ Deleted chapter: \(target)" : "❌ \(error)"
        case "write_to_chapter":
            return "📝 Targeting chapter: \(target).md"
        default:
            return "⚙️ File operation: \(op) \(target)"
        }
    }
}
