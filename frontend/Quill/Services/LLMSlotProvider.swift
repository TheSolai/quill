import Foundation

// MARK: - LLMSlotProvider
// Slot-based LLM provider that talks to the Quill backend's /api/slots
// and /api/chat endpoints. The backend handles routing to Ollama, MLX,
// MiniMax, LM Studio, or any custom OpenAI-compatible endpoint.

struct LLMSlot: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let type: String                // "ollama" | "mlx" | "minimax" | "lmstudio" | "custom"
    let modelId: String             // provider-specific model id
    let endpoint: String?
    let hasApiKey: Bool
    let options: [String: AnyCodable]?
    let purpose: String?
    let category: String?           // "local" | "creative" | "research" | "code" | "cloud" | "minimax"
    let toolCalling: Bool?          // supports OpenAI-style tool/function calling
    let thinking: Bool?             // supports thinking/reasoning tokens
    let isDefault: Bool
    let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id, name, type, endpoint, options, purpose, category, metadata
        case modelId = "model_id"
        case hasApiKey = "has_api_key"
        case toolCalling = "tool_calling"
        case thinking
        case isDefault = "is_default"
    }
}

struct LLMSlotsResponse: Codable {
    let slots: [LLMSlot]
    let activeId: String
    let providerTypes: [String]?

    enum CodingKeys: String, CodingKey {
        case slots
        case activeId = "active_id"
        case providerTypes = "provider_types"
    }
}

// AnyCodable — a type-erased Codable value, used for options/metadata dicts.
struct AnyCodable: Codable, Equatable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let arr = try? c.decode([AnyCodable].self) { value = arr.map { $0.value } }
        else if let dict = try? c.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]: try c.encode(dict.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

// MARK: - Slot-based provider (talks to /api/chat)

final class LLMSlotProvider: LLMProvider, @unchecked Sendable {
    let name: String
    let id: String              // slot id
    let slotType: String
    let modelId: String
    private let baseURL: String
    private let session: URLSession

    init(slot: LLMSlot, baseURL: String = "http://127.0.0.1:5323") {
        self.id = slot.id
        self.name = slot.name
        self.slotType = slot.type
        self.modelId = slot.modelId
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func isAvailable() async -> Bool {
        // Probe /api/health — it includes the active slot info
        guard let url = URL(string: "\(baseURL)/api/health") else { return false }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let backend = json["backend"] as? String, backend == "ok" {
                return true
            }
        } catch {}
        return false
    }

    func sendMessage(_ messages: [ChatMessage]) async throws -> String {
        var collected = ""
        for await token in generateStream(messages) {
            collected += token
        }
        return collected
    }

    func generateStream(_ messages: [ChatMessage]) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let payload: [String: Any] = [
                    "slot_id": self.id,
                    "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                    "stream": true,
                ]
                guard let url = URL(string: "\(self.baseURL)/api/chat") else {
                    continuation.finish(); return
                }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
                do {
                    let (data, _) = try await self.session.data(for: req)
                    guard let text = String(data: data, encoding: .utf8) else {
                        continuation.finish(); return
                    }
                    for line in text.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("data: ") {
                            if trimmed.contains("[DONE]") { continuation.finish(); return }
                            let jsonStr = String(trimmed.dropFirst(6))
                            if let jsonData = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let token = json["token"] as? String {
                                continuation.yield(token)
                            }
                        }
                    }
                } catch {
                    print("[LLMSlotProvider] Stream error: \(error)")
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Slot registry

@MainActor
final class LLMSlotRegistry: ObservableObject {
    static let shared = LLMSlotRegistry()

    @Published private(set) var slots: [LLMSlot] = []
    @Published private(set) var activeSlotId: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let baseURL = "http://127.0.0.1:5323"
    private let session: URLSession
    /// UserDefaults key for persisting the selected slot id across launches.
    private let userDefaultsKey = "quill.activeSlotId"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
        if let stored = UserDefaults.standard.string(forKey: userDefaultsKey) {
            self.activeSlotId = stored
        }
    }

    /// Build a provider for a given slot. This is what the AIAssistantView uses.
    func provider(for slot: LLMSlot) -> LLMProvider {
        LLMSlotProvider(slot: slot, baseURL: baseURL)
    }

    /// Build a provider for the active slot. Falls back to first slot if active
    /// slot is missing.
    func activeProvider() -> LLMProvider? {
        let target = slots.first { $0.id == activeSlotId } ?? slots.first
        guard let s = target else { return nil }
        return LLMSlotProvider(slot: s, baseURL: baseURL)
    }

    var activeSlot: LLMSlot? {
        slots.first { $0.id == activeSlotId } ?? slots.first
    }

    /// Load all slots from the backend. Call on app launch + after any change.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let url = URL(string: "\(baseURL)/api/slots") else {
            lastError = "invalid backend URL"; return
        }
        do {
            let (data, _) = try await session.data(from: url)
            let resp = try JSONDecoder().decode(LLMSlotsResponse.self, from: data)
            self.slots = resp.slots
            // If we don't have a stored active id, use the backend's default
            if activeSlotId.isEmpty || !slots.contains(where: { $0.id == activeSlotId }) {
                self.activeSlotId = resp.activeId
                UserDefaults.standard.set(resp.activeId, forKey: userDefaultsKey)
            }
            self.lastError = nil
        } catch {
            self.lastError = "failed to load slots: \(error.localizedDescription)"
            print("[LLMSlotRegistry] load error: \(error)")
        }
    }

    /// Set the active slot both locally and on the backend.
    func setActive(_ slotId: String) async {
        guard slots.contains(where: { $0.id == slotId }) else { return }
        self.activeSlotId = slotId
        UserDefaults.standard.set(slotId, forKey: userDefaultsKey)
        // Tell the backend
        guard let url = URL(string: "\(baseURL)/api/slots/\(slotId)/activate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.lastError = "backend rejected slot switch: HTTP \(http.statusCode)"
            } else {
                self.lastError = nil
            }
        } catch {
            self.lastError = "slot switch failed: \(error.localizedDescription)"
        }
    }

    /// Test a slot's connectivity.
    func test(_ slotId: String) async -> (ok: Bool, latencyMs: Double, error: String?) {
        guard let url = URL(string: "\(baseURL)/api/slots/\(slotId)/test") else {
            return (false, 0, "invalid URL")
        }
        let t0 = Date()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (data, response) = try await session.data(for: req)
            let latency = Date().timeIntervalSince(t0) * 1000
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return (false, latency, "HTTP \(http.statusCode)")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ok = json["ok"] as? Bool ?? false
                let err = json["error"] as? String
                return (ok, latency, err)
            }
            return (false, latency, "unparseable response")
        } catch {
            return (false, Date().timeIntervalSince(t0) * 1000, error.localizedDescription)
        }
    }

    /// Create a new slot. Returns the created slot on success.
    func create(_ slot: LLMSlot) async -> Result<LLMSlot, Error> {
        guard let url = URL(string: "\(baseURL)/api/slots") else {
            return .failure(NSError(domain: "LLMSlotRegistry", code: 1))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let body = try JSONEncoder().encode(slot)
            req.httpBody = body
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let errText = String(data: data, encoding: .utf8) ?? "unknown"
                return .failure(NSError(domain: "LLMSlotRegistry", code: http.statusCode,
                                         userInfo: [NSLocalizedDescriptionKey: errText]))
            }
            let created = try JSONDecoder().decode(LLMSlot.self, from: data)
            await load()
            return .success(created)
        } catch {
            return .failure(error)
        }
    }

    /// Delete a slot by id.
    func delete(_ slotId: String) async -> Result<Void, Error> {
        guard let url = URL(string: "\(baseURL)/api/slots/\(slotId)") else {
            return .failure(NSError(domain: "LLMSlotRegistry", code: 1))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(NSError(domain: "LLMSlotRegistry", code: http.statusCode))
            }
            await load()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
