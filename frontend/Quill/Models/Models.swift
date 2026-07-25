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
    let slotId: String?
    let slotName: String?
    let slotType: String?

    enum CodingKeys: String, CodingKey {
        case backend, ollama, model
        case slotId = "slot_id"
        case slotName = "slot_name"
        case slotType = "slot_type"
    }
}

/// Lightweight wrapper used internally for tracking connection state.
/// Currently just a Bool, but kept as a struct so we can extend with
/// latency, model name, etc. without breaking call sites.
struct BackendHealth: Equatable {
    var backendReady: Bool
    var ollamaReachable: Bool
    var model: String
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

/// Save state for the editor. Drives the status bar indicator and the
/// autosave debounce. `.saved` is transient — it transitions back to
/// `.idle` after a short delay so the UI can show "✓ saved" briefly.
enum SaveState: Equatable {
    case idle        // nothing pending
    case dirty       // has unsaved changes
    case saving      // save in flight
    case saved       // just saved (transient)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "saved"
        case .dirty: return "unsaved"
        case .saving: return "saving…"
        case .saved: return "✓ saved"
        case .error(let msg): return "save failed: \(msg)"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var currentProject: Project?
    @Published var chapters: [Chapter] = []
    @Published var currentChapter: Chapter?
    @Published var chapterContent: String = ""

    /// Save state for the editor. Tracks dirty/saving/saved transitions
    /// so the UI can show "unsaved" / "saving..." / "saved" indicators,
    /// and the autosave debounce can fire on transitions.
    @Published var saveState: SaveState = .idle

    /// Backward-compatible dirty flag (true when there's unsaved work or a
    /// save is in flight). New code should branch on `saveState` instead.
    var isDirty: Bool {
        switch saveState {
        case .dirty, .saving: return true
        default: return false
        }
    }

    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var streamBuffer: String = ""

    @Published var isBackendReady: Bool = false
    @Published var backendError: String?
    @Published var backendHealth: BackendHealth? = nil
    @Published var ollamaReachable: Bool = false
    private var healthPollTask: Task<Void, Never>?

    @Published var statusMessage: String = "Ready"
    @Published var wordCount: Int = 0

    // Inbox state — loaded on app start so the Inbox tab is always ready.
    // The InboxTab just observes this; the data is loaded here regardless
    // of which tab is currently active.
    @Published var inboxMessages: [InboxMessage] = []
    @Published var inboxLoading: Bool = false
    @Published var inboxStatus: String = ""
    private var inboxPollTask: Task<Void, Never>?

    // Tracks the current async load to cancel stale requests
    private var projectsLoadTask: Task<Void, Never>?
    private var chaptersLoadTask: Task<Void, Never>?
    private var lastLoadedProjectId: String?
    // Autosave debounce
    private var autosaveTask: Task<Void, Never>?
    private static let autosaveDelayNanos: UInt64 = 2_000_000_000  // 2s
    private static let savedIndicatorNanos: UInt64 = 2_000_000_000  // how long "saved" stays visible

    init() {
        // Listen for Cmd+S from the menu bar — save the current chapter/scene
        // from anywhere in the app.
        NotificationCenter.default.addObserver(
            forName: .saveDocument,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.saveNow()
            }
        }
        // Start polling the inbox right away so the Inbox tab has data on
        // first open. Without this, the Inbox tab would be empty until the
        // user explicitly opens it (and the .task on the tab view doesn't
        // fire reliably when the tab is in a ZStack with opacity 0).
        Task { @MainActor in
            await self.refreshInbox()
            await self.pollInboxLoop()
        }
        // Start polling backend health so the UI can show the AI status
        Task { @MainActor in
            await self.pollHealthLoop()
        }
    }

    // MARK: - Inbox

    /// Fetch the latest inbox messages from the backend.
    func refreshInbox() async {
        inboxLoading = true
        defer { inboxLoading = false }
        do {
            let resp = try await BackendService.shared.getRaw("/api/agentmail/inbox?limit=50")
            if let json = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
               let list = json["messages"] as? [[String: Any]] {
                let parsed = list.compactMap { InboxMessage.from(json: $0) }
                await MainActor.run {
                    self.inboxMessages = parsed
                    self.inboxStatus = "Updated \(Self.timeString())"
                }
            }
        } catch {
            await MainActor.run { self.inboxStatus = "Error: \(error.localizedDescription)" }
        }
    }

    /// Long-running poll loop — refreshes the inbox every 30s.
    private func pollInboxLoop() async {
        inboxPollTask?.cancel()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
                guard !Task.isCancelled else { return }
                await self?.refreshInbox()
            }
        }
        inboxPollTask = task
        await task.value
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Health

    /// Poll backend health every 10s. Updates `backendHealth` and
    /// `ollamaReachable` so the UI can show the AI status and toast on
    /// connection changes.
    private func pollHealthLoop() async {
        healthPollTask?.cancel()
        let task = Task { [weak self] in
            var lastReachable: Bool? = nil
            while !Task.isCancelled {
                guard !Task.isCancelled else { return }
                await self?.checkHealth()
                let reachable = self?.ollamaReachable ?? false
                if let last = lastReachable, last != reachable {
                    if reachable {
                        ToastCenter.shared.postSuccess("Backend reconnected")
                    } else {
                        ToastCenter.shared.postWarning("Backend unreachable — using cached state")
                    }
                }
                lastReachable = reachable
                try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10s
            }
        }
        healthPollTask = task
        await task.value
    }

    private func checkHealth() async {
        do {
            let h: HealthResponse = try await BackendService.shared.get("/api/health")
            await MainActor.run {
                self.backendHealth = BackendHealth(
                    backendReady: h.backend == "ok",
                    ollamaReachable: h.ollama == "ok",
                    model: h.model
                )
                self.isBackendReady = (h.backend == "ok")
                self.ollamaReachable = (h.ollama == "ok")
                if h.backend == "ok" { self.backendError = nil }
            }
        } catch {
            await MainActor.run {
                self.isBackendReady = false
                self.ollamaReachable = false
                self.backendError = error.localizedDescription
            }
        }
    }

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
        // If we have unsaved work in the previous project, flush it first
        if currentProject != nil, isDirty {
            await saveNow()
        }
        currentProject = project
        chapterContent = ""
        currentChapter = nil
        currentScene = nil
        sceneContent = ""
        autosaveTask?.cancel()
        saveState = .idle
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
            await saveNow()
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
            autosaveTask?.cancel()
            saveState = .idle
            updateWordCount()
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// Mark content as dirty and schedule an autosave after a short delay.
    /// Called by the editor's onChange when the user types.
    func markDirty() {
        // Don't downgrade saving → dirty
        if case .saving = saveState { return }
        saveState = .dirty
        scheduleAutosave()
    }

    /// Schedule a debounced autosave. If a save is already scheduled, it
    /// is cancelled and rescheduled — so quick typing batches into one save.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppState.autosaveDelayNanos)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Cancel any pending autosave without saving.
    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Save the current chapter (or scene) immediately. Updates saveState
    /// throughout the save so the UI can show a saving/saved indicator.
    func saveNow() async {
        guard let chapter = currentChapter, let project = currentProject else { return }
        autosaveTask?.cancel()
        let previousState = saveState
        // Capture the content we're about to save so we can detect later
        // changes that happened during the save.
        let contentToSave = currentScene != nil ? sceneContent : chapterContent
        saveState = .saving
        do {
            if let scene = currentScene {
                try await BackendService.shared.put(
                    "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes/\(scene.name)/content",
                    body: ["content": contentToSave]
                )
            } else {
                try await BackendService.shared.put(
                    "/api/projects/\(project.id)/chapters/\(chapter.name)/content",
                    body: ["content": contentToSave]
                )
            }
            saveState = .saved
            statusMessage = currentScene != nil ? "Scene saved" : "Saved"
            // If the user typed during the save, the content will now differ
            // from what we just persisted. Re-mark dirty so the next autosave
            // picks up the new changes.
            let currentContent = currentScene != nil ? sceneContent : chapterContent
            if currentContent != contentToSave {
                saveState = .dirty
                scheduleAutosave()
            } else {
                // Fade "saved" → idle after a short delay
                let snapshot = self
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: AppState.savedIndicatorNanos)
                    if case .saved = snapshot.saveState {
                        snapshot.saveState = .idle
                    }
                }
            }
        } catch let error as BackendError {
            handleSaveError(error: error, previousState: previousState, content: contentToSave)
        } catch {
            handleSaveError(error: BackendError.httpError(0, error.localizedDescription), previousState: previousState, content: contentToSave)
        }
    }

    /// Common error handling for saveNow — toasts the user, retries on
    /// transient failures, and sets the state appropriately.
    private func handleSaveError(error: Error, previousState: SaveState, content: String) {
        let msg = (error as? BackendError)?.errorDescription ?? error.localizedDescription
        let isNetworkError = msg.lowercased().contains("network") || msg.lowercased().contains("could not connect")
        saveState = .error(msg)
        backendError = msg
        // If we were dirty before, restore the dirty state and re-schedule
        // an autosave so transient errors (e.g. backend restart) heal.
        if case .dirty = previousState {
            saveState = .dirty
            scheduleAutosave()
        }
        // Toast the error so the user notices (the in-editor indicator is small)
        ToastCenter.shared.postError("Save failed: \(msg)")
        // Auto-retry network errors after 5s (backend might be restarting)
        if isNetworkError {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if case .dirty = self.saveState {
                    ToastCenter.shared.postInfo("Retrying save…")
                    await self.saveNow()
                }
            }
        }
    }

    /// Backward-compatible wrapper for callers that used the old name.
    func saveCurrentChapter() async {
        await saveNow()
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
        // If we're switching scenes with unsaved work, save the old scene first
        if currentScene != nil, isDirty {
            await saveNow()
        }
        do {
            let content: SceneContent = try await BackendService.shared.get(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes/\(scene.name)/content"
            )
            currentScene = scene
            sceneContent = content.content
            autosaveTask?.cancel()
            saveState = .idle
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

    func deleteScene(_ scene: Scene) async {
        guard let project = currentProject, let chapter = currentChapter else { return }
        do {
            try await BackendService.shared.delete(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/scenes/\(scene.name)"
            )
            // If the deleted scene was the current one, clear it from the editor
            if currentScene?.id == scene.id {
                currentScene = nil
                sceneContent = ""
            }
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
        // Prepend existing current chapter content so Quill can continue it
        if !chapterContent.isEmpty && !chapter.isEmpty {
            let preview = String(chapterContent.prefix(2000))
            enhancedHistory.append([
                "role": "user",
                "content": "[CURRENT CHAPTER CONTENT — continue from where this leaves off]\n\n\(preview)\n[END OF PREVIEW]",
            ])
        }

        // If no project is selected, the backend will auto-create a "default"
        // project when the user asks for a chapter. This lets the user start
        // writing without setting up a project first.
        let projectId = currentProject?.id ?? "default"
        let payload: [String: Any] = [
            "project_id": projectId,
            "messages": enhancedHistory,
            "stream": true,
        ]

        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        let assistantMsgId = assistantMsg.id  // capture for async updates
        isStreaming = true
        streamBuffer = ""

        // Track if Quill wrote to a chapter file (so we can refresh the editor)
        var chapterWritten: String? = nil

        do {
            // Use BackendService.streamChat which routes through /api/chat
            try await BackendService.shared.streamChat(
                payload: payload,
                onToken: { [weak self] token in
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Find the streaming message by id (avoids race with popLast/append
                        // when multiple async tokens could fire concurrently)
                        self.streamBuffer += token
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                            self.messages[idx].content = self.streamBuffer
                        }
                    }
                },
                onDone: { [weak self] meta in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.isStreaming = false
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                            self.messages[idx].isStreaming = false
                        }
                        // If Quill wrote to a chapter, refresh the editor.
                        // If the chapter was written to a different project (e.g.
                        // the auto-created "default" project), switch to it first.
                        if let written = meta["chapter_written"] as? String,
                           let pid = meta["project_id"] as? String {
                            chapterWritten = written
                            print("[Quill] Quill wrote to chapter: \(written) in project: \(pid)")
                            // If the server wrote to a project we're not currently on,
                            // switch to it so the user sees the file.
                            if self.currentProject?.id != pid {
                                print("[Quill] Switching to project: \(pid)")
                                await self.loadProjects()
                                if let newProj = self.projects.first(where: { $0.id == pid }) {
                                    await self.selectProject(newProj)
                                }
                            }
                            // Make sure the chapter list is loaded for this project
                            if self.chapters.isEmpty || self.currentProject?.id == pid && self.chapters.isEmpty {
                                await self.loadChapters()
                            }
                            // Select the new chapter (or reload current)
                            if let ch = self.chapters.first(where: { $0.name == written }) {
                                await self.selectChapter(ch)
                            } else if self.currentChapter?.name == written {
                                if let ch = self.currentChapter {
                                    await self.loadChapterContent(ch)
                                }
                            } else {
                                // Chapter not in list yet — refresh and try again
                                await self.loadChapters()
                                if let ch = self.chapters.first(where: { $0.name == written }) {
                                    await self.selectChapter(ch)
                                }
                            }
                            // Toast the success
                            let chars = meta["streamed_chars"] as? Int
                            let detail = chars.map { " (\($0) chars)" } ?? ""
                            ToastCenter.shared.postSuccess("Wrote \(written).md\(detail)")
                            // Show a confirmation in the chat
                            let confirm = ChatMessage(
                                role: .system,
                                content: "✓ Quill wrote to `\(written).md` — opened in the editor."
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
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                            let cur = self.messages[idx].content
                            self.messages[idx].content = (cur.isEmpty ? "" : cur)
                                + "\n[error: \(err)]"
                            self.messages[idx].isStreaming = false
                        }
                    }
                }
            )
        } catch {
            await MainActor.run {
                isStreaming = false
                if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    self.messages[idx].isStreaming = false
                    self.messages[idx].content += "\n[error: \(error.localizedDescription)]"
                }
            }
        }
    }
}
