import Foundation

// MARK: - Project
struct Project: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var path: String
    var chapterCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, path
        case chapterCount = "chapter_count"
    }
}

// MARK: - Chapter
struct Chapter: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var path: String
    var modified: Double
    var size: Int
}

struct ChapterCreateResponse: Codable {
    let name: String
    let path: String
}

// MARK: - Chapter Content
struct ChapterContent: Codable {
    let name: String
    let content: String
    let path: String
}

// MARK: - Chat Message
struct ChatMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    var role: MessageRole
    var content: String
    var isStreaming: Bool = false

    enum MessageRole: String, Codable {
        case user
        case assistant
        case system
    }
}

// MARK: - API Response types
struct HealthResponse: Codable {
    let backend: String
    let ollama: String
    let model: String
}

struct ErrorResponse: Codable {
    let error: String
}

// MARK: - Project Settings
struct ProjectSettings: Codable {
    let title: String
    let author: String
    let genre: String
    let dedication: String
    let epigraph: String
    let style: String
    let model: String
    let chaptersDir: String

    enum CodingKeys: String, CodingKey {
        case title, author, genre, dedication, epigraph, style, model
        case chaptersDir = "chapters_dir"
    }
}

// MARK: - Scene (sub-chapter)
struct Scene: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let path: String
    let modified: Double
    let size: Int
}

struct SceneContent: Codable {
    let name: String
    let content: String
    let path: String
}

// MARK: - Story Bible / Codex
struct Codex: Codable {
    var characters: String
    var world: String
    var summary: String
    var style: String
    var plot: String
    var themes: String
}

// MARK: - Stats
struct WritingStats: Codable {
    var dailyGoal: Int
    var wordsToday: Int
    var totalWords: Int
    var lastSessionStart: String?
    var sessions: [SessionRecord]
    var lastActiveDate: String?

    enum CodingKeys: String, CodingKey {
        case dailyGoal = "daily_goal"
        case wordsToday = "words_today"
        case totalWords = "total_words"
        case lastSessionStart = "last_session_start"
        case sessions
        case lastActiveDate = "last_active_date"
    }

    init() {
        self.dailyGoal = 500
        self.wordsToday = 0
        self.totalWords = 0
        self.lastSessionStart = nil
        self.sessions = []
        self.lastActiveDate = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.dailyGoal = try c.decodeIfPresent(Int.self, forKey: .dailyGoal) ?? 500
        self.wordsToday = try c.decodeIfPresent(Int.self, forKey: .wordsToday) ?? 0
        self.totalWords = try c.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        self.lastSessionStart = try c.decodeIfPresent(String.self, forKey: .lastSessionStart)
        self.sessions = try c.decodeIfPresent([SessionRecord].self, forKey: .sessions) ?? []
        self.lastActiveDate = try c.decodeIfPresent(String.self, forKey: .lastActiveDate)
    }
}

struct SessionRecord: Codable {
    let start: String
    let end: String
}

// MARK: - Synopsis
struct Synopsis: Codable {
    var synopsis: String
}

// MARK: - Compile Preview
struct CompilePreview: Codable {
    let title: String
    let content: String
    let chapterCount: Int
    let wordCount: Int
    let author: String
    let genre: String

    enum CodingKeys: String, CodingKey {
        case title, content, author, genre
        case chapterCount = "chapter_count"
        case wordCount = "word_count"
    }
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var currentProject: Project?
    @Published var chapters: [Chapter] = []
    @Published var currentChapter: Chapter?
    @Published var chapterContent: String = ""
    @Published var isDirty: Bool = false

    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var streamBuffer: String = ""

    @Published var isBackendReady: Bool = false
    @Published var backendError: String?

    @Published var statusMessage: String = "Ready"
    @Published var wordCount: Int = 0

    // Tracks the current async load to cancel stale requests
    private var projectsLoadTask: Task<Void, Never>?
    private var chaptersLoadTask: Task<Void, Never>?
    private var lastLoadedProjectId: String?

    func loadProjects() async {
        projectsLoadTask?.cancel()
        let task = Task { @MainActor in
            do {
                let fetched: [Project] = try await BackendService.shared.get("/api/projects")
                guard !Task.isCancelled else { return }
                self.projects = fetched
                self.isBackendReady = true
                self.backendError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.backendError = error.localizedDescription
                self.isBackendReady = false
            }
        }
        projectsLoadTask = task
        await task.value
    }

    func createProject(name: String) async {
        struct CreateResponse: Codable { let id: String; let name: String }
        do {
            let resp: CreateResponse = try await BackendService.shared.post(
                "/api/projects", body: ["name": name]
            )
            await loadProjects()
            if let project = projects.first(where: { $0.id == resp.id }) {
                currentProject = project
                await loadChapters()
            }
        } catch {
            backendError = error.localizedDescription
        }
    }

    func selectProject(_ project: Project) async {
        print("[Quill] selectProject: \(project.id)")
        // Avoid redundant work if same project clicked again
        if currentProject?.id == project.id && lastLoadedProjectId == project.id {
            print("[Quill] selectProject: skipping (already loaded)")
            return
        }
        currentProject = project
        chapterContent = ""
        currentChapter = nil
        isDirty = false
        wordCount = 0
        lastLoadedProjectId = project.id
        print("[Quill] selectProject: state reset, calling loadChapters")
        await loadChapters()
        print("[Quill] selectProject: loadChapters done, chapters count: \(chapters.count)")
    }

    func loadChapters() async {
        guard let project = currentProject else {
            print("[Quill] loadChapters: no current project")
            return
        }
        let targetProjectId = project.id
        print("[Quill] loadChapters: starting for \(targetProjectId)")
        chaptersLoadTask?.cancel()
        let task = Task { @MainActor in
            do {
                let fetched: [Chapter] = try await BackendService.shared.get(
                    "/api/projects/\(targetProjectId)/chapters"
                )
                print("[Quill] loadChapters: fetched \(fetched.count) chapters for \(targetProjectId)")
                guard !Task.isCancelled else {
                    print("[Quill] loadChapters: cancelled")
                    return
                }
                guard self.currentProject?.id == targetProjectId else {
                    print("[Quill] loadChapters: stale (current=\(self.currentProject?.id ?? "nil"))")
                    return
                }
                self.chapters = fetched
            } catch {
                print("[Quill] loadChapters: error: \(error)")
                guard !Task.isCancelled else { return }
                self.backendError = error.localizedDescription
            }
        }
        chaptersLoadTask = task
        await task.value
    }

    func createChapter(name: String) async {
        guard let project = currentProject else { return }
        do {
            let _: ChapterCreateResponse = try await BackendService.shared.post(
                "/api/projects/\(project.id)/chapters", body: ["name": name]
            )
            await loadChapters()
        } catch {
            backendError = error.localizedDescription
        }
    }

    func selectChapter(_ chapter: Chapter) async {
        if currentChapter != nil, isDirty {
            await saveCurrentChapter()
        }
        currentChapter = chapter
        await loadChapterContent(chapter)
    }

    func loadChapterContent(_ chapter: Chapter) async {
        guard let project = currentProject else { return }
        do {
            let content: ChapterContent = try await BackendService.shared.get(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/content"
            )
            chapterContent = content.content
            isDirty = false
            updateWordCount()
        } catch {
            backendError = error.localizedDescription
        }
    }

    func saveCurrentChapter() async {
        guard let chapter = currentChapter, let project = currentProject else { return }
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/content",
                body: ["content": chapterContent]
            )
            isDirty = false
            statusMessage = "Saved"
        } catch {
            backendError = error.localizedDescription
        }
    }

    func deleteChapter(_ chapter: Chapter) async {
        guard let project = currentProject else { return }
        do {
            try await BackendService.shared.delete(
                "/api/projects/\(project.id)/chapters/\(chapter.name)"
            )
            if currentChapter?.id == chapter.id {
                currentChapter = nil
                chapterContent = ""
            }
            await loadChapters()
        } catch {
            backendError = error.localizedDescription
        }
    }

    // ---- Scenes (sub-chapters) ----------------------------------------

    @Published var scenes: [Scene] = []
    @Published var currentScene: Scene?
    @Published var sceneContent: String = ""

    func loadScenes() async {
        guard let project = currentProject, let chapter = currentChapter else {
            scenes = []
            return
        }
        do {
            scenes = try await BackendService.shared.get(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes"
            )
        } catch {
            scenes = []
            backendError = error.localizedDescription
        }
    }

    func selectScene(_ scene: Scene) async {
        guard let project = currentProject, let chapter = currentChapter else { return }
        do {
            let content: SceneContent = try await BackendService.shared.get(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes/\(scene.name)/content"
            )
            currentScene = scene
            sceneContent = content.content
        } catch {
            backendError = error.localizedDescription
        }
    }

    func saveCurrentScene() async {
        guard let project = currentProject, let chapter = currentChapter, let scene = currentScene else { return }
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes/\(scene.name)/content",
                body: ["content": sceneContent]
            )
            statusMessage = "Scene saved"
        } catch {
            backendError = error.localizedDescription
        }
    }

    func createScene(name: String) async {
        guard let project = currentProject, let chapter = currentChapter else { return }
        do {
            let _: [String: String] = try await BackendService.shared.post(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes",
                body: ["name": name]
            )
            await loadScenes()
        } catch {
            backendError = error.localizedDescription
        }
    }

    // ---- Story Bible / Codex -------------------------------------------

    @Published var codex: Codex = Codex(
        characters: "", world: "", summary: "", style: "", plot: "", themes: ""
    )

    func loadCodex() async {
        guard let project = currentProject else { return }
        do {
            codex = try await BackendService.shared.get(
                "/api/projects/\(project.id)/codex"
            )
        } catch {
            backendError = error.localizedDescription
        }
    }

    func saveCodex() async {
        guard let project = currentProject else { return }
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/codex",
                body: [
                    "characters": codex.characters,
                    "world": codex.world,
                    "summary": codex.summary,
                    "style": codex.style,
                    "plot": codex.plot,
                    "themes": codex.themes,
                ]
            )
            statusMessage = "Story Bible saved"
        } catch {
            backendError = error.localizedDescription
        }
    }

    // ---- Stats + writing goals -----------------------------------------

    @Published var stats: WritingStats = WritingStats()
    @Published var sessionStartTime: Date?
    @Published var sessionWordsWritten: Int = 0

    func loadStats() async {
        guard currentProject != nil else { return }
        do {
            stats = try await BackendService.shared.get(
                "/api/projects/\(currentProject!.id)/stats"
            )
        } catch {
            backendError = error.localizedDescription
        }
    }

    func startSession() async {
        guard currentProject != nil else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        do {
            _ = try await BackendService.shared.put(
                "/api/projects/\(currentProject!.id)/stats",
                body: ["session_start": iso]
            );
            sessionStartTime = Date()
            sessionWordsWritten = 0
        } catch {
            // silent
        }
    }

    func endSession() async {
        guard currentProject != nil, let start = sessionStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 5 && sessionWordsWritten > 0 {
            let iso = ISO8601DateFormatter().string(from: Date())
            do {
                _ = try await BackendService.shared.put(
                    "/api/projects/\(currentProject!.id)/stats",
                    body: ["session_end": iso]
                );
            } catch {}
        }
        sessionStartTime = nil
    }

    func setDailyGoal(_ goal: Int) async {
        guard currentProject != nil else { return }
        do {
            _ = try await BackendService.shared.put(
                "/api/projects/\(currentProject!.id)/stats",
                body: ["daily_goal": goal]
            );
            stats.dailyGoal = goal
        } catch {
            backendError = error.localizedDescription
        }
    }

    // ---- Synopsis (corkboard) ------------------------------------------

    @Published var synopses: [String: String] = [:]

    func loadAllSynopses() async {
        guard let project = currentProject else { return }
        // Snapshot the chapters list so concurrent mutations don't break iteration
        let chaptersSnapshot = chapters
        print("[Quill] loadAllSynopses: starting for \(chaptersSnapshot.count) chapters in project \(project.id)")
        var loaded: [String: String] = [:]
        for chapter in chaptersSnapshot {
            do {
                let s: Synopsis = try await BackendService.shared.get(
                    "/api/projects/\(project.id)/chapters/\(chapter.name)/synopsis"
                )
                print("[Quill] loadAllSynopses: got synopsis for \(chapter.name): \(s.synopsis.prefix(30))")
                if !s.synopsis.isEmpty {
                    loaded[chapter.name] = s.synopsis
                }
            } catch {
                print("[Quill] loadAllSynopses: error for \(chapter.name): \(error)")
                // ignore
            }
        }
        print("[Quill] loadAllSynopses: done, loaded \(loaded.count) synopses")
        synopses = loaded
    }

    func setSynopsis(_ chapterName: String, synopsis: String) async {
        guard let project = currentProject else { return }
        do {
            _ = try await BackendService.shared.put(
                "/api/projects/\(project.id)/chapters/\(chapterName)/synopsis",
                body: ["synopsis": synopsis]
            );
            if synopsis.isEmpty {
                synopses.removeValue(forKey: chapterName)
            } else {
                synopses[chapterName] = synopsis
            }
        } catch {
            backendError = error.localizedDescription
        }
    }

    func updateWordCount() {
        let words = chapterContent
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        wordCount = words.count
    }

    enum GenerationMode: String {
        case short = "short"
        case long = "long"
    }

    func sendMessage(_ text: String, mode: GenerationMode = .short, chapter: String = "", outline: String = "", style: String = "") async {
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        // Build the conversation history to send to /api/chat
        let history = messages.filter { !$0.isStreaming }.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }
        var enhancedHistory = history
        if !chapter.isEmpty {
            enhancedHistory.append([
                "role": "user",
                "content": "[CONTEXT] Target chapter: \(chapter).md. Project style: \(style.isEmpty ? "literary, vivid prose" : style)",
            ])
        }
        // Prepend existing current chapter content so Dross can continue it
        if !chapterContent.isEmpty && !chapter.isEmpty {
            let preview = String(chapterContent.prefix(2000))
            enhancedHistory.append([
                "role": "user",
                "content": "[CURRENT CHAPTER CONTENT — continue from where this leaves off]\n\n\(preview)\n[END OF PREVIEW]",
            ])
        }

        let projectId = currentProject?.id ?? "default"
        let payload: [String: Any] = [
            "project_id": projectId,
            "messages": enhancedHistory,
            "stream": true,
        ]

        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        isStreaming = true
        streamBuffer = ""

        // Track if Dross wrote to a chapter file (so we can refresh the editor)
        var chapterWritten: String? = nil

        do {
            // Use BackendService.streamChat which routes through /api/chat
            try await BackendService.shared.streamChat(
                payload: payload,
                onToken: { [weak self] token in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.streamBuffer += token
                        if var last = self.messages.popLast() {
                            last.content = self.streamBuffer
                            self.messages.append(last)
                        }
                    }
                },
                onDone: { [weak self] meta in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.isStreaming = false
                        if var last = self.messages.popLast() {
                            last.isStreaming = false
                            self.messages.append(last)
                        }
                        // If Dross wrote to a chapter, refresh the editor
                        if let written = meta["chapter_written"] as? String,
                           let pid = meta["project_id"] as? String {
                            chapterWritten = written
                            print("[Quill] Dross wrote to chapter: \(written)")
                            // Reload the chapter into the editor
                            if self.currentChapter?.name == written || self.currentChapter == nil {
                                if let ch = self.chapters.first(where: { $0.name == written }) {
                                    await self.selectChapter(ch)
                                }
                            } else {
                                // Force reload of the current chapter's content
                                if let ch = self.currentChapter {
                                    await self.loadChapterContent(ch)
                                }
                            }
                            // Show a confirmation in the chat
                            let confirm = ChatMessage(
                                role: .system,
                                content: "✓ Dross wrote to `\(written).md` — open the chapter to read it."
                            )
                            self.messages.append(confirm)
                        }
                        if let email = meta["email"] as? [String: Any] {
                            let ok = email["ok"] as? Bool ?? false
                            let summary = ok
                                ? "✓ Email sent to \((email["to"] as? [String])?.first ?? "")"
                                : "✗ Email failed: \(email["error"] ?? "unknown")"
                            self.messages.append(ChatMessage(role: .system, content: summary))
                        }
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.isStreaming = false
                        if var last = self.messages.popLast() {
                            last.content = (last.content.isEmpty ? "" : last.content)
                                + "\n[error: \(err)]"
                            last.isStreaming = false
                            self.messages.append(last)
                        }
                    }
                }
            )
        } catch {
            await MainActor.run {
                isStreaming = false
                if var last = messages.popLast() {
                    last.isStreaming = false
                    last.content += "\n[error: \(error.localizedDescription)]"
                    messages.append(last)
                }
            }
        }
    }
}
