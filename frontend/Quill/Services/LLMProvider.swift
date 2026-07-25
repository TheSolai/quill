import Foundation

// MARK: - LLMProvider Protocol
protocol LLMProvider: Sendable {
    var name: String { get }
    var id: String { get }
    func isAvailable() async -> Bool
    func sendMessage(_ messages: [ChatMessage]) async throws -> String
    func generateStream(_ messages: [ChatMessage]) -> AsyncStream<String>
}

// MARK: - Provider Registry
@MainActor
final class LLMRegistry: ObservableObject {
    static let shared = LLMRegistry()

    @Published private(set) var providers: [LLMProvider] = []
    @Published var selectedProviderId: String = "ollama"
    /// True when the active provider is a slot-based one (loaded from the
    /// backend). False for the legacy hard-coded providers.
    @Published private(set) var usingSlotProvider: Bool = false

    /// The current slot-based provider, if any. Set by `detectAndSelect`.
    private var slotProvider: LLMSlotProvider?

    var selectedProvider: LLMProvider? {
        // Prefer slot-based provider when available
        if let sp = slotProvider {
            return sp
        }
        return providers.first { $0.id == selectedProviderId }
    }

    private init() {
        providers = [
            OllamaProvider(),
            SwiftHelperProvider(),
            AppleIntelligenceProvider(),
        ]
    }

    func detectAndSelect() async {
        // First try the slot system
        await LLMSlotRegistry.shared.load()
        if let activeSlot = LLMSlotRegistry.shared.activeSlot {
            let slotProv = LLMSlotRegistry.shared.provider(for: activeSlot)
            if await slotProv.isAvailable() {
                self.slotProvider = slotProv as? LLMSlotProvider
                self.usingSlotProvider = true
                self.selectedProviderId = "slot:\(activeSlot.id)"
                print("[LLMRegistry] using slot provider: \(activeSlot.name) (\(activeSlot.type))")
                return
            }
        }
        // Fall back to legacy hard-coded providers
        usingSlotProvider = false
        for provider in providers {
            let available = await provider.isAvailable()
            print("[LLMRegistry] \(provider.name): \(available ? "available" : "not available")")
        }
        for provider in providers {
            if await provider.isAvailable() {
                selectedProviderId = provider.id
                break
            }
        }
    }

    var providerDescriptions: [ProviderDescription] {
        var descs: [ProviderDescription] = []
        if usingSlotProvider, let s = slotProvider {
            descs.append(ProviderDescription(id: "slot:\(s.id)", name: s.name))
        }
        descs.append(contentsOf: providers.map { ProviderDescription(id: $0.id, name: $0.name) })
        return descs
    }
}

struct ProviderDescription: Identifiable {
    let id: String
    let name: String
}

// MARK: - Apple Intelligence Provider
final class AppleIntelligenceProvider: LLMProvider, @unchecked Sendable {
    let name = "Apple Intelligence"
    let id = "apple_intelligence"

    func isAvailable() async -> Bool {
        let frameworkURL = "/System/Library/Frameworks/AppleIntelligence.framework"
        let available = FileManager.default.fileExists(atPath: frameworkURL)
        if !available {
            print("[AppleIntelligenceProvider] Framework not found — requires macOS 26+")
        }
        return available
    }

    func sendMessage(_ messages: [ChatMessage]) async throws -> String {
        guard await isAvailable() else {
            throw NSError(domain: "AppleIntelligence", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Apple Intelligence requires macOS 26 or later. " +
                            "Your current OS version does not support this feature. " +
                            "Please update your system, or switch to Ollama in Settings."])
        }
        return ""
    }

    func generateStream(_ messages: [ChatMessage]) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                guard await self.isAvailable() else {
                    continuation.finish(); return
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Ollama Provider
final class OllamaProvider: LLMProvider, @unchecked Sendable {
    let name = "Ollama (Local)"
    let id = "ollama"
    private let baseURL = "http://127.0.0.1:5323"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func isAvailable() async -> Bool {
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
        let lastMsg = messages.last?.content ?? ""
        let payload: [String: Any] = [
            "task": lastMsg,
            "mode": "short",
            "project_id": "default",
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        let url = URL(string: "\(baseURL)/api/tasks")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await session.data(for: req)
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var result = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data: "), !trimmed.contains("[DONE]") {
                let jsonStr = String(trimmed.dropFirst(6))
                if let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let token = json["token"] as? String {
                    result += token
                }
            }
        }
        return result
    }

    func generateStream(_ messages: [ChatMessage]) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let lastMsg = messages.last?.content ?? ""
                let payload: [String: Any] = [
                    "task": lastMsg,
                    "mode": "short",
                    "project_id": "default",
                    "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                ]
                let url = URL(string: "\(self.baseURL)/api/tasks")!
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
                    print("[OllamaProvider] Stream error: \(error)")
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Swift Helper Provider
final class SwiftHelperProvider: LLMProvider, @unchecked Sendable {
    let name = "Swift Helper (Local)"
    let id = "swift"

    private var helperPath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/quill-ai-helper"
    }

    private var standaloneHelperPath: String {
        let srcRoot = (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent
            .replacingOccurrences(of: "/Quill.app/Contents", with: "")
        return srcRoot + "/Helpers/quill-ai-helper"
    }

    private func resolveHelperPath() -> String {
        if FileManager.default.fileExists(atPath: helperPath) {
            return helperPath
        }
        return standaloneHelperPath
    }

    func isAvailable() async -> Bool {
        let path = resolveHelperPath()
        return FileManager.default.fileExists(atPath: path)
    }

    func sendMessage(_ messages: [ChatMessage]) async throws -> String {
        let prompt = buildPrompt(from: messages)
        let request: [String: Any] = [
            "prompt": prompt,
            "model": "gemma4:latest",
            "stream": false
        ]
        let inputData = try JSONSerialization.data(withJSONObject: request)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveHelperPath())
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let outputPipe = process.standardOutput as! Pipe
        try process.run()
        (process.standardInput as! Pipe).fileHandleForWriting.write(inputData)
        (process.standardInput as! Pipe).fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let response = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let text = response["text"] as? String else {
            return ""
        }
        return text
    }

    func generateStream(_ messages: [ChatMessage]) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let prompt = self.buildPrompt(from: messages)
                let request: [String: Any] = [
                    "prompt": prompt,
                    "model": "gemma4:latest",
                    "stream": true
                ]
                guard let inputData = try? JSONSerialization.data(withJSONObject: request) else {
                    continuation.finish(); return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.resolveHelperPath())
                process.standardInput = Pipe()
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                let outputPipe = process.standardOutput as! Pipe

                do {
                    try process.run()
                    (process.standardInput as! Pipe).fileHandleForWriting.write(inputData)
                    (process.standardInput as! Pipe).fileHandleForWriting.closeFile()

                    outputPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty {
                            outputPipe.fileHandleForReading.readabilityHandler = nil
                            continuation.finish()
                            return
                        }
                        if let line = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !line.isEmpty {
                            if line.hasPrefix("data: ") && !line.contains("[DONE]") {
                                let jsonStr = String(line.dropFirst(6))
                                if let jsonData = jsonStr.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                   let token = json["token"] as? String {
                                    continuation.yield(token)
                                }
                            }
                        }
                    }
                } catch {
                    print("[SwiftHelperProvider] Process error: \(error)")
                    continuation.finish()
                }
            }
        }
    }

    private func buildPrompt(from messages: [ChatMessage]) -> String {
        var parts: [String] = []
        for msg in messages {
            if msg.role == .user {
                parts.append("User: \(msg.content)")
            } else if msg.role == .assistant {
                parts.append("Assistant: \(msg.content)")
            }
        }
        return """
        You are Quill, an expert creative writing assistant. Write in vivid, immersive prose. \
        Be direct and literary. When writing chapters, output only the prose — no titles, no preambles.

        \(parts.joined(separator: "\n\n"))

        Assistant:
        """
    }
}
