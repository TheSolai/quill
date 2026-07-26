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
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID = UUID()
    var role: MessageRole
    var content: String
    var isStreaming: Bool = false
    var ts: Date? = nil  // server-side timestamp (optional, used when loading sessions)

    enum MessageRole: String, Codable {
        case user
        case assistant
        case system
    }
}

// MARK: - Chat Session
/// A persisted AI conversation, stored on the backend at
/// `<project>/.sessions/<id>.json`. Loaded on app start, autosaved
/// whenever a message is added.
struct ChatSession: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var createdAt: String?
    var updatedAt: String?
    var messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messages
    }
}

/// Lightweight session metadata (used for the session list — no messages
/// field, so the payload stays small even with hundreds of sessions).
struct ChatSessionMeta: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var createdAt: String?
    var updatedAt: String?
    var messageCount: Int
    var lastExcerpt: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case lastExcerpt = "last_excerpt"
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

// MARK: - Story Bible / Codex
// Structured + freeform fields. The freeform text fields are kept for the
// prose system prompt (which can ingest them as-is). The structured list
// fields are surfaced in the UI as editable lists.
struct Codex: Codable {
    // Freeform (back-compat with the original text fields)
    var characters: String
    var world: String
    var summary: String
    var style: String
    var plot: String
    var themes: String

    // Structured (new — populated by /extract)
    var charactersList: [StoryCharacter]
    var locations: [StoryLocation]
    var timeline: [StoryTimelineEvent]
    var relationships: [StoryRelationship]
    var themesList: [String]
    var motifs: [String]
    var glossary: [StoryGlossaryEntry]

    // Voice / structure
    var tone: String
    var pov: String
    var tense: String
    var incitingIncident: String
    var climax: String
    var resolution: String

    // Tolerate missing fields when decoding older codex files
    init(characters: String = "", world: String = "", summary: String = "",
         style: String = "", plot: String = "", themes: String = "",
         charactersList: [StoryCharacter] = [], locations: [StoryLocation] = [],
         timeline: [StoryTimelineEvent] = [], relationships: [StoryRelationship] = [],
         themesList: [String] = [], motifs: [String] = [],
         glossary: [StoryGlossaryEntry] = [],
         tone: String = "", pov: String = "", tense: String = "",
         incitingIncident: String = "", climax: String = "",
         resolution: String = "") {
        self.characters = characters
        self.world = world
        self.summary = summary
        self.style = style
        self.plot = plot
        self.themes = themes
        self.charactersList = charactersList
        self.locations = locations
        self.timeline = timeline
        self.relationships = relationships
        self.themesList = themesList
        self.motifs = motifs
        self.glossary = glossary
        self.tone = tone
        self.pov = pov
        self.tense = tense
        self.incitingIncident = incitingIncident
        self.climax = climax
        self.resolution = resolution
    }
}

// MARK: - Story Bible structured entries

struct StoryCharacter: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var role: String  // protagonist, antagonist, sidekick, etc.
    var description: String
    var goal: String
    var arc: String

    init(id: UUID = UUID(), name: String = "", role: String = "",
         description: String = "", goal: String = "", arc: String = "") {
        self.id = id; self.name = name; self.role = role
        self.description = description; self.goal = goal; self.arc = arc
    }
}

struct StoryLocation: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var significance: String

    init(id: UUID = UUID(), name: String = "", description: String = "",
         significance: String = "") {
        self.id = id; self.name = name; self.description = description
        self.significance = significance
    }
}

struct StoryTimelineEvent: Codable, Identifiable, Equatable {
    let id: UUID
    var order: Int
    var when: String
    var what: String

    init(id: UUID = UUID(), order: Int = 0, when: String = "", what: String = "") {
        self.id = id; self.order = order; self.when = when; self.what = what
    }
}

struct StoryRelationship: Codable, Identifiable, Equatable {
    let id: UUID
    var from: String
    var to: String
    var type: String
    var description: String

    init(id: UUID = UUID(), from: String = "", to: String = "",
         type: String = "", description: String = "") {
        self.id = id; self.from = from; self.to = to; self.type = type
        self.description = description
    }
}

struct StoryGlossaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String
    var definition: String

    init(id: UUID = UUID(), term: String = "", definition: String = "") {
        self.id = id; self.term = term; self.definition = definition
    }
}

extension Codex {
    /// Total number of structured entries across all list fields. Shown in
    /// the Story Bible header pill as a quick "how much lore do I have"
    /// indicator.
    var populationCount: Int {
        charactersList.count + locations.count + timeline.count
        + relationships.count + motifs.count + glossary.count
    }

    /// True if any field has structured content. Used to decide whether
    /// to show the empty state.
    var hasContent: Bool {
        populationCount > 0
            || !characters.isEmpty
            || !world.isEmpty
            || !summary.isEmpty
            || !style.isEmpty
            || !plot.isEmpty
            || !themes.isEmpty
            || !tone.isEmpty
            || !pov.isEmpty
            || !tense.isEmpty
            || !incitingIncident.isEmpty
            || !climax.isEmpty
            || !resolution.isEmpty
    }
}

// MARK: - Helpers for dict-shaped API responses
//
// The backend returns Story Bible entries as raw dicts (since they're
// stored in .quill_context.json with mixed types). These factories turn
// the loose dicts into our typed structs, falling back to safe defaults
// when fields are missing.

extension StoryCharacter {
    static func from(dict: [String: Any]) -> StoryCharacter {
        StoryCharacter(
            name: dict["name"] as? String ?? "",
            role: dict["role"] as? String ?? "",
            description: dict["description"] as? String ?? "",
            goal: dict["goal"] as? String ?? "",
            arc: dict["arc"] as? String ?? ""
        )
    }
}

extension StoryLocation {
    static func from(dict: [String: Any]) -> StoryLocation {
        StoryLocation(
            name: dict["name"] as? String ?? "",
            description: dict["description"] as? String ?? "",
            significance: dict["significance"] as? String ?? ""
        )
    }
}

extension StoryTimelineEvent {
    static func from(dict: [String: Any]) -> StoryTimelineEvent {
        StoryTimelineEvent(
            order: dict["order"] as? Int ?? 0,
            when: dict["when"] as? String ?? "",
            what: dict["what"] as? String ?? ""
        )
    }
}

extension StoryRelationship {
    static func from(dict: [String: Any]) -> StoryRelationship {
        StoryRelationship(
            from: dict["from"] as? String ?? "",
            to: dict["to"] as? String ?? "",
            type: dict["type"] as? String ?? "",
            description: dict["description"] as? String ?? ""
        )
    }
}

extension StoryGlossaryEntry {
    static func from(dict: [String: Any]) -> StoryGlossaryEntry {
        StoryGlossaryEntry(
            term: dict["term"] as? String ?? "",
            definition: dict["definition"] as? String ?? ""
        )
    }
}

extension Codex {
    /// Serialize to a dict for PUT /api/projects/<id>/codex. Keeps the
    /// wire format stable and lets the backend store everything in the
    /// single .quill_context.json file.
    func toJSON() -> [String: Any] {
        var d: [String: Any] = [
            "characters": characters,
            "world": world,
            "summary": summary,
            "style": style,
            "plot": plot,
            "themes": themes,
        ]
        if !charactersList.isEmpty {
            d["characters_list"] = charactersList.map { c in
                ["name": c.name, "role": c.role, "description": c.description,
                 "goal": c.goal, "arc": c.arc]
            }
        }
        if !locations.isEmpty {
            d["locations"] = locations.map { l in
                ["name": l.name, "description": l.description, "significance": l.significance]
            }
        }
        if !timeline.isEmpty {
            d["timeline"] = timeline.map { t in
                ["order": t.order, "when": t.when, "what": t.what]
            }
        }
        if !relationships.isEmpty {
            d["relationships"] = relationships.map { r in
                ["from": r.from, "to": r.to, "type": r.type, "description": r.description]
            }
        }
        if !themesList.isEmpty { d["themes_list"] = themesList }
        if !motifs.isEmpty { d["motifs"] = motifs }
        if !glossary.isEmpty {
            d["glossary"] = glossary.map { g in
                ["term": g.term, "definition": g.definition]
            }
        }
        if !tone.isEmpty { d["tone"] = tone }
        if !pov.isEmpty { d["pov"] = pov }
        if !tense.isEmpty { d["tense"] = tense }
        if !incitingIncident.isEmpty { d["inciting_incident"] = incitingIncident }
        if !climax.isEmpty { d["climax"] = climax }
        if !resolution.isEmpty { d["resolution"] = resolution }
        return d
    }
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

    /// True when in the error state. Used to force a retry even if the
    /// content happens to match the last saved version.
    var isError: Bool {
        if case .error = self { return true }
        return false
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
    @Published var sessions: [ChatSessionMeta] = []
    @Published var currentSessionId: String? = nil

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
    private static let autosaveMaxDelayNanos: UInt64 = 30_000_000_000  // 30s — trailing save
    private static let savedIndicatorNanos: UInt64 = 2_000_000_000  // how long "saved" stays visible

    /// Tracks when the user last typed. Used to enforce a trailing-save
    /// so we never go more than 30s without persisting, even if the user
    /// is typing continuously.
    private var lastTypedAt: Date = .distantPast

    /// True while a saveNow() is currently executing. Used to coalesce
    /// concurrent save requests (e.g. autosave + manual save racing).
    private var saveInFlight: Bool = false
    /// Content of the most recent successful save. Used to detect when a
    /// save is still needed after a coalesced wait.
    private var lastSavedContent: String = ""

    init() {
        // Listen for Cmd+S from the menu bar — save the current chapter
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
            let resp = try await BackendService.shared.getRawData("/api/agentmail/inbox?limit=50")
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
        autosaveTask?.cancel()
        trailingSaveTask?.cancel()
        saveState = .idle
        wordCount = 0
        lastSavedContent = ""
        lastLoadedProjectId = project.id
        print("[Quill] selectProject: state reset, calling loadChapters")
        await loadChapters()
        print("[Quill] selectProject: loadChapters done, chapters count: \(chapters.count)")
        // Reload the Story Bible + chat session for this project
        async let codexTask: Void = loadCodex()
        async let sessionTask: Void = loadCurrentSession()
        _ = await (codexTask, sessionTask)
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

    /// Ensure a project + chapter is open so the user can start typing
    /// immediately on launch. If no project exists, creates "Default". If
    /// the current project has no chapters, creates an "untitled.md"
    /// chapter. Idempotent — safe to call multiple times.
    func ensureReady() async {
        // Already ready? Done.
        if currentProject != nil, currentChapter != nil { return }
        if projects.isEmpty {
            print("[Quill] ensureReady: no projects — creating default")
            await createProject(name: "Default")
        } else if currentProject == nil {
            // Pick the first project
            print("[Quill] ensureReady: no current project — selecting first")
            currentProject = projects.first
            lastLoadedProjectId = currentProject?.id
        }
        guard let project = currentProject else { return }
        if chapters.isEmpty {
            await loadChapters()
        }
        if chapters.isEmpty {
            print("[Quill] ensureReady: no chapters — creating untitled.md")
            await createChapter(name: "untitled")
        }
        if currentChapter == nil, let first = chapters.first {
            print("[Quill] ensureReady: no current chapter — selecting first")
            await selectChapter(first)
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
            trailingSaveTask?.cancel()
            saveState = .idle
            lastSavedContent = content.content
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
        lastTypedAt = Date()
        scheduleAutosave()
    }

    /// Schedule a debounced autosave. If a save is already scheduled, it
    /// is cancelled and rescheduled — so quick typing batches into one save.
    ///
    /// Trailing-save: a separate task also fires after autosaveMaxDelay
    /// (30s) so we never go more than 30s without persisting, even if the
    /// user is typing continuously. This is the "kill switch" that
    /// guarantees the user's work hits disk eventually.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        let typedAt = lastTypedAt
        autosaveTask = Task { [weak self] in
            // First wait: the debounce window (2s after the LAST keystroke)
            try? await Task.sleep(nanoseconds: AppState.autosaveDelayNanos)
            guard !Task.isCancelled else { return }
            // If the user typed more during the debounce, defer to the
            // trailing-save timer below.
            if let self = self, self.lastTypedAt > typedAt { return }
            await self?.saveNow()
        }
        // Trailing-save: fires 30s after the LAST markDirty call, no matter what
        trailingSaveTask?.cancel()
        trailingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppState.autosaveMaxDelayNanos)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            if self.chapterContent == self.lastSavedContent { return }
            if self.saveState.isError || self.saveState == .dirty {
                await self.saveNow()
            }
        }
    }

    /// Separate task for the 30s trailing-save kill switch. Runs in
    /// parallel with `autosaveTask` and survives debounce cancellations.
    private var trailingSaveTask: Task<Void, Never>?

    /// Cancel any pending autosave without saving.
    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        trailingSaveTask?.cancel()
        trailingSaveTask = nil
    }

    /// Save the current chapter immediately. Updates saveState throughout
    /// the save so the UI can show a saving/saved indicator. Concurrent
    /// saves are guarded — if a save is already in flight, the call
    /// coalesces into a single save that picks up the latest content.
    func saveNow() async {
        guard let chapter = currentChapter, let project = currentProject else { return }
        // If a save is already in progress, wait for it to complete (max 10s)
        // then re-check whether we still need to save. This prevents the
        // "Save failed: HTTP 409" race that happens when autosave + manual
        // save overlap.
        if saveInFlight {
            let start = Date()
            while saveInFlight, Date().timeIntervalSince(start) < 10 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // After the in-flight save completes, the content may already match
            // what's on disk — only re-save if the user typed during the wait.
            if chapterContent == lastSavedContent { return }
        }
        // No-op short-circuit: if the content hasn't changed since the last
        // save, don't burn a network round-trip.
        if chapterContent == lastSavedContent, !saveState.isError { return }
        saveInFlight = true
        defer { saveInFlight = false }
        // Do NOT cancel autosaveTask/trailingSaveTask here — this method
        // is OFTEN running inside one of them. Cancelling the current
        // task cancels its URLSessionTask, which throws URLError -999
        // ("cancelled") and produces the noisy "Save failed: HTTP -999"
        // toast. The debounce / trailing tasks are self-managing.
        let previousState = saveState
        // Capture the content we're about to save so we can detect later
        // changes that happened during the save.
        let contentToSave = chapterContent
        lastSavedContent = contentToSave
        saveState = .saving
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/content",
                body: ["content": contentToSave]
            )
            saveState = .saved
            statusMessage = "Saved"
            // If the user typed during the save, the content will now differ
            // from what we just persisted. Re-mark dirty so the next autosave
            // picks up the new changes.
            if chapterContent != contentToSave {
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
        } catch is CancellationError {
            // Task was cancelled (e.g. user switched chapters mid-save).
            // Don't show an error toast — this is expected behavior.
            print("[Quill] saveNow: cancelled mid-save (no error to show)")
        } catch let error as BackendError {
            handleSaveError(error: error, previousState: previousState, content: contentToSave)
        } catch let error as URLError {
            // Common URLError codes:
            //   -1001 = request timed out, -1009 = no internet,
            //   -1004 = can't connect to host, -1005 = network lost
            let code = error.code.rawValue
            let desc = error.localizedDescription
            handleSaveError(
                error: BackendError.httpError(code, "URLError \(code): \(desc)"),
                previousState: previousState,
                content: contentToSave,
            )
        } catch {
            let typeName = String(describing: type(of: error))
            let desc = error.localizedDescription
            handleSaveError(
                error: BackendError.networkError(error),
                previousState: previousState,
                content: contentToSave,
            )
            print("[Quill] saveNow: unexpected error type=\(typeName) desc=\(desc)")
        }
    }

    /// Common error handling for saveNow — toasts the user, retries on
    /// transient failures, and sets the state appropriately.
    private func handleSaveError(error: Error, previousState: SaveState, content: String) {
        let msg = (error as? BackendError)?.errorDescription ?? error.localizedDescription
        let lower = msg.lowercased()
        // Network errors that should auto-retry after 5s (backend might be
        // restarting). Catch the common URLError code descriptions.
        let isNetworkError = lower.contains("network")
            || lower.contains("could not connect")
            || lower.contains("timed out")
            || lower.contains("urlerror")
            || lower.contains("not connected")
            || lower.contains("lost")
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

    /// Returns the on-disk path of the current chapter — used for
    /// Reveal in Finder, Recent Files, Save As, etc.
    func currentChapterURL() -> String? {
        guard let project = currentProject, let chapter = currentChapter else { return nil }
        let baseDir = BackendService.shared.baseDir
        return "\(baseDir)/\(project.id)/\(chapter.name).md"
    }

    /// Save the current chapter to a new file path. Updates the chapter
    /// metadata in the backend so the renamed chapter appears in the sidebar.
    func saveChapterAs(newName: String) async {
        guard let project = currentProject, let chapter = currentChapter else { return }
        let safeName = newName.trimmingCharacters(in: .whitespaces)
        guard !safeName.isEmpty else { return }
        do {
            let _: ChapterCreateResponse = try await BackendService.shared.post(
                "/api/projects/\(project.id)/chapters", body: ["name": safeName]
            )
            // Copy current content to the new chapter
            let content = chapterContent
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/chapters/\(safeName)/content",
                body: ["content": content]
            )
            // Reload chapters and select the new one
            await loadChapters()
            if let newChapter = chapters.first(where: { $0.name == safeName }) {
                await selectChapter(newChapter)
                ToastCenter.shared.postSuccess("Saved as \(safeName).md")
            }
        } catch {
            backendError = error.localizedDescription
            ToastCenter.shared.postError("Save As failed: \(error.localizedDescription)")
        }
    }

    /// Open a recent file: find the project, select it, then select the chapter.
    func openProjectAndChapter(projectId: String, chapterName: String) async {
        await loadProjects()
        guard let project = projects.first(where: { $0.id == projectId }) else {
            ToastCenter.shared.postError("Project '\(projectId)' not found")
            return
        }
        await selectProject(project)
        // loadChapters is triggered inside selectProject; find the chapter
        if let chapter = chapters.first(where: { $0.name == chapterName }) {
            await selectChapter(chapter)
            ToastCenter.shared.postInfo("Opened \(chapterName).md")
        } else {
            ToastCenter.shared.postWarning("Chapter '\(chapterName)' not found in \(projectId)")
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

    /// Reorder chapters in the sidebar. Called from the List's .onMove
    /// callback. Updates the local list immediately, then POSTs the new
    /// order to the backend so it persists across launches.
    func reorderChapters(from source: IndexSet, to destination: Int) async {
        guard let project = currentProject else { return }
        chapters.move(fromOffsets: source, toOffset: destination)
        let order = chapters.map { $0.name }
        do {
            struct R: Codable { let ok: Bool? }
            let _: R = try await BackendService.shared.post(
                "/api/projects/\(project.id)/chapters/reorder",
                body: ["order": order]
            )
        } catch {
            // Soft-fail: the local list is already updated; on next
            // loadChapters() the backend will return the saved order.
            backendError = "Reorder saved locally but failed to persist: \(error.localizedDescription)"
        }
    }

    /// Rename a chapter (uses the backend's /rename endpoint).
    func renameChapter(_ chapter: Chapter, to newName: String) async {
        guard let project = currentProject else { return }
        let safe = newName.trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty, safe != chapter.name else { return }
        do {
            struct RenameResponse: Codable { let name: String; let path: String }
            let _: RenameResponse = try await BackendService.shared.post(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/rename",
                body: ["name": safe]
            )
            let wasCurrent = currentChapter?.id == chapter.id
            await loadChapters()
            if wasCurrent, let renamed = chapters.first(where: { $0.name == safe }) {
                await selectChapter(renamed)
            }
            ToastCenter.shared.postSuccess("Renamed to \(safe).md")
        } catch {
            backendError = error.localizedDescription
            ToastCenter.shared.postError("Rename failed: \(error.localizedDescription)")
        }
    }

    /// Duplicate a chapter — creates a new chapter called "<name>-copy"
    /// with the same content.
    func duplicateChapter(_ chapter: Chapter) async {
        guard let project = currentProject else { return }
        let baseName = chapter.name + "-copy"
        // If already exists, append -2, -3, etc.
        var newName = baseName
        var counter = 2
        while chapters.contains(where: { $0.name == newName }) {
            newName = "\(baseName)-\(counter)"
            counter += 1
        }
        do {
            // Create the new chapter
            let _: ChapterCreateResponse = try await BackendService.shared.post(
                "/api/projects/\(project.id)/chapters", body: ["name": newName]
            )
            // Fetch the source content
            let source: ChapterContent = try await BackendService.shared.get(
                "/api/projects/\(project.id)/chapters/\(chapter.name)/content"
            )
            // Copy the content
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/chapters/\(newName)/content",
                body: ["content": source.content]
            )
            await loadChapters()
            if let dup = chapters.first(where: { $0.name == newName }) {
                await selectChapter(dup)
            }
            ToastCenter.shared.postSuccess("Duplicated as \(newName).md")
        } catch {
            backendError = error.localizedDescription
            ToastCenter.shared.postError("Duplicate failed: \(error.localizedDescription)")
        }
    }

    // ---- Story Bible / Codex -------------------------------------------

    @Published var codex: Codex = Codex(
        characters: "", world: "", summary: "", style: "", plot: "", themes: ""
    )

    func loadCodex() async {
        guard let project = currentProject else { return }
        do {
            let raw: [String: Any] = try await BackendService.shared.getRaw(
                "/api/projects/\(project.id)/codex"
            )
            // Manually decode so we can keep using the structured fields
            // even if the backend returns old-shape data with strings
            // instead of arrays.
            var c = codex
            c.characters = raw["characters"] as? String ?? ""
            c.world = raw["world"] as? String ?? ""
            c.summary = raw["summary"] as? String ?? ""
            c.style = raw["style"] as? String ?? ""
            c.plot = raw["plot"] as? String ?? ""
            c.themes = raw["themes"] as? String ?? ""
            // New fields (may be missing in old data)
            if let list = raw["characters_list"] as? [[String: Any]] {
                c.charactersList = list.map(StoryCharacter.from(dict:))
            }
            if let list = raw["locations"] as? [[String: Any]] {
                c.locations = list.map(StoryLocation.from(dict:))
            }
            if let list = raw["timeline"] as? [[String: Any]] {
                c.timeline = list.map(StoryTimelineEvent.from(dict:))
            }
            if let list = raw["relationships"] as? [[String: Any]] {
                c.relationships = list.map(StoryRelationship.from(dict:))
            }
            if let list = raw["themes_list"] as? [String] {
                c.themesList = list
            } else if let list = raw["themes"] as? [String] {
                c.themesList = list
            }
            if let list = raw["motifs"] as? [String] { c.motifs = list }
            if let list = raw["glossary"] as? [[String: Any]] {
                c.glossary = list.map(StoryGlossaryEntry.from(dict:))
            }
            c.tone = raw["tone"] as? String ?? ""
            c.pov = raw["pov"] as? String ?? ""
            c.tense = raw["tense"] as? String ?? ""
            c.incitingIncident = raw["inciting_incident"] as? String ?? ""
            c.climax = raw["climax"] as? String ?? ""
            c.resolution = raw["resolution"] as? String ?? ""
            codex = c
        } catch {
            backendError = error.localizedDescription
        }
    }

    func saveCodex() async {
        guard let project = currentProject else { return }
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/codex",
                body: codex.toJSON()
            )
            statusMessage = "Story Bible saved"
        } catch {
            backendError = error.localizedDescription
        }
    }

    // ---- Email the book (failsafe) ---------------------------------------
    //
    // One-shot — bundle the project, send to a recipient, show a toast.
    // The user picked ⌥⌘M ("Email the Book...") in the File menu. There
    // is intentionally no inbox / reply / archive UI; if the user wanted
    // a mail client they'd use Mail.app. This is the panic button.

    /// Result shape for /api/projects/<id>/email-the-book.
    struct EmailBookResult: Codable {
        let ok: Bool?
        let message_id: String?
        let subject: String?
        let would_send_to: String?
        let attachment_filename: String?
        let dry_run: Bool?
        let book: BookSummary?
        struct BookSummary: Codable {
            let title: String?
            let author: String?
            let words: Int?
            let format: String?
            let size_bytes: Int?
        }
    }

    /// Returns the parsed response on success, or throws on failure.
    /// Both dry-run and real-send return the same shape.
    func emailTheBook(to recipient: String, format: String = "html",
                      includeAttachments: Bool = true,
                      dryRun: Bool = false) async throws -> EmailBookResult {
        guard let project = currentProject else {
            throw NSError(domain: "Quill", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No project open"
            ])
        }
        let body: [String: Any] = [
            "to": recipient,
            "format": format,
            "include_attachments": includeAttachments,
            "dry_run": dryRun,
        ]
        let result: EmailBookResult = try await BackendService.shared.post(
            "/api/projects/\(project.id)/email-the-book",
            body: body
        )
        if dryRun { return result }
        guard result.ok == true else {
            throw NSError(domain: "Quill", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Email send failed"
            ])
        }
        return result
    }

    // ---- AI chat sessions ------------------------------------------------

    /// Load the current session for the project (creates one if none
    /// exists). Called on project select / app start.
    func loadCurrentSession() async {
        guard let project = currentProject else {
            messages = []
            sessions = []
            currentSessionId = nil
            return
        }
        do {
            // Load the session list in parallel with the current session.
            async let listTask: [String: Any] = BackendService.shared.getRaw(
                "/api/projects/\(project.id)/sessions"
            )
            let session: ChatSession = try await BackendService.shared.get(
                "/api/projects/\(project.id)/sessions/current"
            )
            self.currentSessionId = session.id
            self.messages = session.messages
            // Session list (no messages — small payload)
            if let list = try? await listTask, let arr = list["sessions"] as? [[String: Any]] {
                let decoder = JSONDecoder()
                self.sessions = arr.compactMap { dict in
                    guard let data = try? JSONSerialization.data(withJSONObject: dict),
                          let meta = try? decoder.decode(ChatSessionMeta.self, from: data)
                    else { return nil }
                    return meta
                }
            }
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// List all sessions for the current project.
    func loadSessions() async {
        guard let project = currentProject else { return }
        do {
            let raw: [String: Any] = try await BackendService.shared.getRaw(
                "/api/projects/\(project.id)/sessions"
            )
            if let arr = raw["sessions"] as? [[String: Any]] {
                let decoder = JSONDecoder()
                self.sessions = arr.compactMap { dict in
                    guard let data = try? JSONSerialization.data(withJSONObject: dict),
                          let meta = try? decoder.decode(ChatSessionMeta.self, from: data)
                    else { return nil }
                    return meta
                }
            }
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// Start a brand new session. The backend auto-saves it and points
    /// the project's current_session at the new id.
    func startNewSession() async {
        guard let project = currentProject else { return }
        do {
            // Use the first user message as the title if we have one queued
            let firstUser = messages.first(where: { $0.role == .user })?.content
            let title = firstUser.map { String($0.prefix(60)) } ?? "New session"
            let body: [String: Any] = [
                "title": title,
                "messages": [] as [[String: Any]],
            ]
            let newSess: ChatSession = try await BackendService.shared.post(
                "/api/projects/\(project.id)/sessions", body: body
            )
            self.currentSessionId = newSess.id
            self.messages = []  // start fresh
            await loadSessions()
            ToastCenter.shared.postSuccess("New session started")
        } catch {
            backendError = error.localizedDescription
            ToastCenter.shared.postError("New session failed: \(error.localizedDescription)")
        }
    }

    /// Switch to an existing session by id.
    func switchToSession(_ id: String) async {
        guard let project = currentProject else { return }
        do {
            let session: ChatSession = try await BackendService.shared.get(
                "/api/projects/\(project.id)/sessions/\(id)"
            )
            self.currentSessionId = session.id
            self.messages = session.messages
            // Mark this as the current on the backend too
            // (set via a side-channel — for now we just load and rely on
            // auto-save to keep the new current in sync)
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// Delete a session by id.
    func deleteSession(_ id: String) async {
        guard let project = currentProject else { return }
        do {
            try await BackendService.shared.delete(
                "/api/projects/\(project.id)/sessions/\(id)"
            )
            if currentSessionId == id {
                // The deleted one was current — fall back to a new one
                await loadCurrentSession()
            }
            await loadSessions()
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// Rename the current session.
    func renameCurrentSession(to newTitle: String) async {
        guard let project = currentProject, let sid = currentSessionId else { return }
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/sessions/\(sid)",
                body: ["title": newTitle]
            )
            await loadSessions()
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// Autosave the current session. Called after each user/assistant
    /// message. Debounced via `sessionSaveTask` so we don't write on
    /// every keystroke.
    private var sessionSaveTask: Task<Void, Never>?
    func scheduleSessionSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s debounce
            guard !Task.isCancelled else { return }
            await self?.saveCurrentSession()
        }
    }
    func saveCurrentSession() async {
        guard let project = currentProject, let sid = currentSessionId else { return }
        // Only autosave the messages, not the title (so we don't fight
        // the user if they're typing a custom title)
        let payload: [String: Any] = [
            "messages": messages.map { m -> [String: Any] in
                var d: [String: Any] = ["role": m.role.rawValue, "content": m.content]
                if let ts = m.ts { d["ts"] = ISO8601DateFormatter().string(from: ts) }
                return d
            }
        ]
        do {
            try await BackendService.shared.put(
                "/api/projects/\(project.id)/sessions/\(sid)", body: payload
            )
        } catch {
            // Silent — don't bother the user for autosave failures
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
        // Slash commands for chat sessions
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "/new" || lower == "/new session" {
            await startNewSession()
            return
        }
        if lower == "/list" || lower == "/sessions" {
            await loadSessions()
            let list = sessions.map { "• [\($0.id.prefix(20))…] \($0.title) (\($0.messageCount) msg)" }.joined(separator: "\n")
            messages.append(ChatMessage(role: .system,
                content: sessions.isEmpty
                    ? "No previous sessions. Use **/new** to start one."
                    : "Sessions (newest first):\n\n\(list)\n\nUse `/switch <id>` or click one in the sidebar."))
            return
        }
        if lower.hasPrefix("/switch ") {
            let id = String(trimmed.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty {
                await switchToSession(id)
                return
            }
        }
        if lower.hasPrefix("/delete ") {
            let id = String(trimmed.dropFirst("/delete ".count)).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty {
                await deleteSession(id)
                return
            }
        }
        if lower.hasPrefix("/rename ") {
            let newTitle = String(trimmed.dropFirst("/rename ".count)).trimmingCharacters(in: .whitespaces)
            if !newTitle.isEmpty {
                await renameCurrentSession(to: newTitle)
                return
            }
        }

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        scheduleSessionSave()

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
                        // Persist the new turn to disk
                        self.scheduleSessionSave()
                        // If this is a brand-new session (no title yet) and we
                        // just had our first user/assistant exchange, set a
                        // sensible title from the first user message.
                        if self.currentSessionId != nil, self.messages.count == 2,
                           let firstUser = self.messages.first(where: { $0.role == .user })?.content {
                            let title = String(firstUser.prefix(60))
                            Task { await self.renameCurrentSession(to: title) }
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
                        // If the AI used the write_chapter tool (or any tool
                        // that mutates a chapter file), refresh the editor
                        // so the user sees the new content immediately.
                        if let toolsUsed = meta["tools_used"] as? [[String: Any]] {
                            let writeChapters = toolsUsed.compactMap { entry -> String? in
                                guard let name = entry["name"] as? String,
                                      name == "write_chapter" else { return nil }
                                let args = entry["args"] as? [String: Any] ?? [:]
                                return (args["chapter"] as? String) ?? (args["name"] as? String)
                            }
                            if !writeChapters.isEmpty {
                                // Reload chapters and switch to the first one
                                // the AI wrote (most recent write wins).
                                let target = writeChapters.last!
                                print("[Quill] AI used write_chapter for: \(target) — refreshing")
                                if self.chapters.isEmpty {
                                    await self.loadChapters()
                                }
                                if let ch = self.chapters.first(where: { $0.name == target }) {
                                    await self.selectChapter(ch)
                                } else {
                                    await self.loadChapters()
                                    if let ch = self.chapters.first(where: { $0.name == target }) {
                                        await self.selectChapter(ch)
                                    }
                                }
                                let summary = "✓ Quill wrote to `\(target).md` via the `write_chapter` tool."
                                self.messages.append(ChatMessage(role: .system, content: summary))
                                ToastCenter.shared.postSuccess("Saved \(target).md")
                            }
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
