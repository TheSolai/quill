import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var state: AppState
    let bgPrimary: Color
    let bgSecondary: Color
    let accent: Color
    let accentDim: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    @State private var showPreview: Bool = false
    @State private var previewMode: PreviewMode = .split
    @State private var isFixingInline: Bool = false
    @State private var inlineFixRange: NSRange? = nil
    @State private var inlineFixStatus: String = ""  // shown as transient banner
    @State private var focusToken: Int = 0
    @State private var showSaveAsSheet: Bool = false
    @State private var saveAsName: String = ""
    @FocusState private var editorFocused: Bool
    @ObservedObject private var slotRegistry = LLMSlotRegistry.shared

    enum PreviewMode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case split = "Split"
        case preview = "Preview"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let chapter = state.currentChapter {
                    Image(systemName: "book.fill")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                    Text(chapter.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(textPrimary)
                    // Inline word count badge for the open chapter
                    if state.wordCount > 0 {
                        Text("·")
                            .foregroundColor(textMuted)
                        Text("\(state.wordCount.formatted()) words")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                        Text("·")
                            .foregroundColor(textMuted)
                        Text(readingTime)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                    if let scene = state.currentScene {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        Text(scene.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(accentDim)
                    }
                } else {
                    Text("No chapter open")
                        .font(.system(size: 13))
                        .foregroundColor(textMuted)
                }

                Spacer()

                // Preview mode toggle
                if state.currentChapter != nil {
                    Picker("", selection: $previewMode) {
                        ForEach(PreviewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .controlSize(.small)
                }

                if state.currentChapter != nil {
                    saveStateIndicator
                }

                // Manual save button (Cmd+S also works via menu bar)
                if state.currentChapter != nil {
                    Button(action: {
                        Task { await state.saveNow() }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 9))
                            Text("Save")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Save (⌘S) — autosaves every 2s; press to save now")
                    // Disable when there's nothing to save or while saving
                    .disabled(!state.isDirty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bgSecondary)

            Divider().background(border)

            if state.currentChapter != nil {
                editorArea
                    .id("editor-\(state.currentChapter?.id ?? "unknown")")
            } else {
                emptyState
            }

            Divider().background(border)

            statusBar
        }
        .background(bgPrimary)
    }

    // MARK: - Editor Area

    @ViewBuilder
    private var editorArea: some View {
        switch previewMode {
        case .edit:
            markdownEditor
        case .preview:
            markdownPreview(content: activeContent)
        case .split:
            HSplitView {
                markdownEditor
                markdownPreview(content: activeContent)
            }
        }
    }

    private var markdownEditor: some View {
        // Use MarkdownTextEditor (NSTextView wrapper) for Tab-to-fix inline AI.
        // Tab triggers the edit-fix endpoint on the current selection or sentence.
        MarkdownTextEditor(
            text: currentTextBinding,
            isFixing: isFixingInline,
            onTabPressed: { snippet, range in
                Task { await runInlineFix(snippet: snippet, range: range) }
            },
            font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: NSColor(textPrimary),
            background: NSColor(bgPrimary),
            focusToken: focusToken
        )
        .id("editor-\(state.currentChapter?.id ?? "empty")")
        .padding(20)
        .overlay(alignment: .topTrailing) {
            if isFixingInline || !inlineFixStatus.isEmpty {
                HStack(spacing: 5) {
                    if isFixingInline {
                        ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                    Text(inlineFixStatus)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(bgSecondary.opacity(0.9))
                .cornerRadius(4)
                .padding(8)
                .transition(.opacity)
            }
        }
        .onChange(of: activeContent) { _, newValue in
            if state.currentChapter != nil {
                state.markDirty()
                state.updateWordCount()
            }
        }
        .onChange(of: state.currentChapter?.id) { _, _ in
            // Refocus the editor after a chapter switch
            focusToken += 1
            // Clear any pending fix state when switching chapters
            isFixingInline = false
            inlineFixStatus = ""
            inlineFixRange = nil
            print("[Quill] EditorView: chapter changed to \(state.currentChapter?.id ?? "nil"), activeContent length=\(activeContent.count)")
        }
        .onAppear {
            // Focus immediately so the user can start typing
            focusToken += 1
            print("[Quill] EditorView: appeared, currentChapter=\(state.currentChapter?.id ?? "nil"), activeContent length=\(activeContent.count)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
            // Cmd+S from the menu bar
            Task { await state.saveNow() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Quill.presentSaveAs"))) { _ in
            guard state.currentChapter != nil else { return }
            saveAsName = state.currentChapter?.name ?? ""
            showSaveAsSheet = true
        }
        .sheet(isPresented: $showSaveAsSheet) {
            VStack(spacing: 16) {
                Text("Save Chapter As")
                    .font(.system(size: 14, weight: .bold))
                Text("Creates a copy of the current chapter with a new name.")
                    .font(.system(size: 11))
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
                TextField("chapter-name", text: $saveAsName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack(spacing: 12) {
                    Button("Cancel") { showSaveAsSheet = false }
                        .buttonStyle(.bordered)
                    Button("Save") {
                        let name = saveAsName
                        showSaveAsSheet = false
                        Task { await state.saveChapterAs(newName: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saveAsName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
    }

    // MARK: - Inline fix

    /// Run /api/edit-fix on the given snippet, then replace the text at `range`
    /// with the corrected version. Updates the chapter content binding, which
    /// causes the NSTextView to re-render via updateNSView.
    @MainActor
    private func runInlineFix(snippet: String, range: NSRange) async {
        guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Capture the current chapter/scene so we can detect a switch mid-fix
        // and refuse to apply the result to the wrong place.
        let chapterAtStart = state.currentChapter
        let sceneAtStart = state.currentScene
        let contentAtStart = activeContent

        isFixingInline = true
        inlineFixStatus = "Quill is fixing…"
        let ns = (contentAtStart as NSString)
        // Clamp range to current text bounds
        let safeRange = NSRange(
            location: min(range.location, ns.length),
            length: min(range.length, max(0, ns.length - range.location))
        )
        do {
            let result = try await BackendService.shared.editFix(
                text: snippet,
                instruction: "fix typos and grammar",
                slotId: nil  // let the backend pick the best small local slot
            )
            // Bail if the user switched chapters/scenes while the API was in flight
            guard state.currentChapter?.id == chapterAtStart?.id,
                  state.currentScene?.id == sceneAtStart?.id else {
                inlineFixStatus = "Fix discarded (chapter switched)"
                isFixingInline = false
                let status = inlineFixStatus
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if inlineFixStatus == status { inlineFixStatus = "" }
                }
                return
            }
            // Replace the range in the captured content
            let mutable = NSMutableString(string: contentAtStart)
            if safeRange.location + safeRange.length <= mutable.length {
                mutable.replaceCharacters(in: safeRange, with: result.text)
            }
            let newContent = mutable as String
            // Update the binding (this fires onChange → markDirty)
            if state.currentScene != nil {
                state.sceneContent = newContent
            } else {
                state.chapterContent = newContent
            }
            state.markDirty()
            state.updateWordCount()
            inlineFixRange = NSRange(location: safeRange.location, length: (result.text as NSString).length)
            let original = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let fixed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            inlineFixStatus = original == fixed
                ? "Quill found it already correct"
                : "✓ Quill fixed it (⌘Z to undo)"
            // Fade the status after 2.5s
            let status = inlineFixStatus
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if inlineFixStatus == status { inlineFixStatus = "" }
            }
        } catch {
            inlineFixStatus = "✗ Fix failed: \(error.localizedDescription)"
            // Fade error after 3s
            let status = inlineFixStatus
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if inlineFixStatus == status { inlineFixStatus = "" }
            }
        }
        isFixingInline = false
    }

    // MARK: - Save state indicator

    @ViewBuilder
    private var saveStateIndicator: some View {
        switch state.saveState {
        case .idle:
            EmptyView()
        case .dirty:
            HStack(spacing: 4) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                Text("unsaved")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(accent)
            }
        case .saving:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 8, height: 8)
                Text("saving…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textSecondary)
            }
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text("saved")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
            }
        case .error(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                Text(msg)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func markdownPreview(content: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if content.isEmpty {
                    Text("Preview will appear here")
                        .font(.system(size: 13))
                        .foregroundColor(textMuted)
                        .padding(20)
                } else {
                    ForEach(Array(MarkdownParser.parse(content).enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block, accent: accent, textPrimary: textPrimary, textSecondary: textSecondary, textMuted: textMuted, border: border)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .textSelection(.enabled)
        }
        .background(bgPrimary)
    }

    // MARK: - Status Bar (with session timer + word goal)

    private var statusBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 9))
                    .foregroundColor(textMuted)
                Text("\(state.wordCount) words")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
            }

            // Reading time
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(textMuted)
                Text("\(readingTime)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
            }

            // Session timer
            if state.sessionStartTime != nil {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(sessionDuration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green)
                }
            }

            // Daily word goal progress
            if state.stats.dailyGoal > 0 {
                HStack(spacing: 6) {
                    Text("\(state.stats.wordsToday)/\(state.stats.dailyGoal)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textMuted)
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(border)
                                .frame(height: 3)
                                .cornerRadius(1.5)
                            Rectangle()
                                .fill(goalProgressColor)
                                .frame(width: geo.size.width * goalProgress, height: 3)
                                .cornerRadius(1.5)
                        }
                    }
                    .frame(width: 80, height: 3)
                }
            }

            Spacer()

            // Server indicator — click to change (Quill's "Change server" button)
            ServerButton(
                activeSlotId: slotRegistry.activeSlotId,
                activeSlotName: slotRegistry.activeSlot?.name ?? "—",
                accent: accent,
                textPrimary: textPrimary,
                textMuted: textMuted,
                border: border,
                onSelect: { slotId in
                    Task { await slotRegistry.setActive(slotId) }
                }
            )

            if state.statusMessage == "Saved" || state.statusMessage == "Scene saved" || state.statusMessage == "Story Bible saved" {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accent)
                    Text(state.statusMessage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(accent)
                }
            } else if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(bgSecondary)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 56))
                .foregroundColor(textMuted.opacity(0.35))
            VStack(spacing: 6) {
                Text(state.currentProject == nil
                     ? "Welcome to Quill"
                     : "No chapter open")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textPrimary)
                Text(state.currentProject == nil
                     ? "Create a project from the sidebar to start writing."
                     : "Click **+** above CHAPTERS, or right-click in the sidebar to create one.")
                    .font(.system(size: 12))
                    .foregroundColor(textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if state.currentProject == nil {
                Button(action: { AppCommandsState.shared.showNewProject = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("New Project…")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgPrimary)
    }

    // MARK: - Helpers

    private var activeContent: String {
        // Scene is the "active" content if a scene is selected
        if state.currentScene != nil {
            return state.sceneContent
        }
        return state.chapterContent
    }

    private var currentTextBinding: Binding<String> {
        Binding(
            get: { activeContent },
            set: { newValue in
                if state.currentScene != nil {
                    state.sceneContent = newValue
                } else {
                    state.chapterContent = newValue
                }
            }
        )
    }

    private var readingTime: String {
        let minutes = max(1, state.wordCount / 200)
        return "\(minutes) min read"
    }

    private var sessionDuration: String {
        guard let start = state.sessionStartTime else { return "" }
        let elapsed = Int(Date().timeIntervalSince(start))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%d:%02d", m, s)
    }

    private var goalProgress: Double {
        guard state.stats.dailyGoal > 0 else { return 0 }
        return min(1.0, Double(state.stats.wordsToday) / Double(state.stats.dailyGoal))
    }

    private var goalProgressColor: Color {
        if goalProgress >= 1.0 {
            return .green
        } else if goalProgress >= 0.5 {
            return accent
        } else {
            return textMuted
        }
    }
}

// MARK: - Markdown Parser (robust, in-house)

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph([MarkdownInline])
    case codeBlock(language: String?, code: String)
    case listItem([MarkdownInline], ordered: Bool, index: Int)
    case blockquote([MarkdownInline])
    case rule
    case blank
}

enum MarkdownInline {
    case text(String)
    case bold(String)
    case italic(String)
    case code(String)
    case link(String, String)
    case linebreak

    func render(accent: Color, textPrimary: Color, textSecondary: Color, textMuted: Color, border: Color) -> AnyView {
        switch self {
        case .text(let s):
            return AnyView(Text(s).foregroundColor(textPrimary))
        case .bold(let s):
            return AnyView(Text(s).bold().foregroundColor(textPrimary))
        case .italic(let s):
            return AnyView(Text(s).italic().foregroundColor(textPrimary))
        case .code(let s):
            return AnyView(
                Text(s)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(border.opacity(0.3))
                    .cornerRadius(3)
            )
        case .link(let label, _):
            return AnyView(Text(label).underline().foregroundColor(accent))
        case .linebreak:
            return AnyView(Text("\n"))
        }
    }

    func join(other: MarkdownInline) -> [MarkdownInline] {
        return [self, other]
    }
}

enum MarkdownParser {
    /// Robust markdown parser. Handles:
    /// - ATX headings (# ## ### etc.)
    /// - Fenced code blocks (```)
    /// - Bold, italic, inline code, links
    /// - Ordered + unordered lists
    /// - Blockquotes
    /// - Horizontal rules
    static func parse(_ md: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // Blank line
            if stripped.isEmpty {
                blocks.append(.blank)
                i += 1
                continue
            }

            // Heading
            if let m = stripped.range(of: #"^(#{1,6})\s+(.+)$"#, options: .regularExpression) {
                let text = String(stripped[m])
                let hashes = text.prefix(while: { $0 == "#" }).count
                let level = min(hashes, 6)
                let content = text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                _ = parseInlines(String(content))
                blocks.append(.heading(level: level, text: String(content)))
                i += 1
                continue
            }

            // Horizontal rule
            if stripped == "---" || stripped == "***" || stripped == "___" {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Code block (fenced)
            if stripped.hasPrefix("```") {
                let lang = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code = ""
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    }
                    code += codeLine + "\n"
                    i += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: code))
                i += 1
                continue
            }

            // Blockquote (collect consecutive > lines)
            if stripped.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix("> ") {
                        quoteLines.append(String(ql.dropFirst(2)))
                        i += 1
                    } else {
                        break
                    }
                }
                let combined = quoteLines.joined(separator: " ")
                let inlines = parseInlines(combined)
                blocks.append(.blockquote(inlines))
                continue
            }

            // Unordered list
            if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") {
                let content = String(stripped.dropFirst(2))
                let inlines = parseInlines(content)
                blocks.append(.listItem(inlines, ordered: false, index: 0))
                i += 1
                continue
            }

            // Ordered list
            if let _ = stripped.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = stripped.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                let inlines = parseInlines(content)
                blocks.append(.listItem(inlines, ordered: true, index: 0))
                i += 1
                continue
            }

            // Paragraph (collect until blank line)
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextStripped = next.trimmingCharacters(in: .whitespaces)
                if nextStripped.isEmpty { break }
                if nextStripped.hasPrefix("#") || nextStripped.hasPrefix("```") ||
                   nextStripped.hasPrefix("> ") || nextStripped.hasPrefix("- ") ||
                   nextStripped.hasPrefix("* ") { break }
                if nextStripped.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil { break }
                paraLines.append(next)
                i += 1
            }
            let paraText = paraLines.joined(separator: " ")
            blocks.append(.paragraph(parseInlines(paraText)))
        }
        return blocks
    }

    /// Parse inline elements: bold, italic, code, links
    static func parseInlines(_ text: String) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var buffer = ""
        var i = text.startIndex

        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer = ""
            }
        }

        while i < text.endIndex {
            let c = text[i]
            // Inline code
            if c == "`" {
                if let endRange = text[text.index(after: i)...].range(of: "`") {
                    let code = String(text[text.index(after: i)..<endRange.lowerBound])
                    flush()
                    result.append(.code(code))
                    i = endRange.upperBound
                    continue
                }
            }
            // Bold **text**
            if c == "*" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "*" {
                let after = text.index(i, offsetBy: 2)
                if let endRange = text[after...].range(of: "**") {
                    let bold = String(text[after..<endRange.lowerBound])
                    flush()
                    result.append(.bold(bold))
                    i = endRange.upperBound
                    continue
                }
            }
            // Italic *text*
            if c == "*" {
                let after = text.index(after: i)
                if let endRange = text[after...].range(of: "*") {
                    let italic = String(text[after..<endRange.lowerBound])
                    flush()
                    result.append(.italic(italic))
                    i = endRange.upperBound
                    continue
                }
            }
            // Link [text](url)
            if c == "[" {
                if let closeBracket = text[i...].firstIndex(of: "]"),
                   text.index(after: closeBracket) < text.endIndex,
                   text[text.index(after: closeBracket)] == "(" {
                    let afterParen = text.index(after: closeBracket)
                    if let closeParen = text[afterParen...].firstIndex(of: ")") {
                        let label = String(text[text.index(after: i)..<closeBracket])
                        let urlStart = text.index(after: closeBracket)
                        let url = String(text[urlStart..<closeParen])
                        flush()
                        result.append(.link(label, url))
                        i = text.index(after: closeParen)
                        continue
                    }
                }
            }
            buffer.append(c)
            i = text.index(after: i)
        }
        flush()
        return result.isEmpty ? [.text(text)] : result
    }
}

// MARK: - Block View

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    var body: some View {
        switch block {
        case .heading(let level, let text):
            switch level {
            case 1:
                Text(text)
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundColor(textPrimary)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case 2:
                Text(text)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundColor(textPrimary)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(border).frame(height: 1)
                    }
            case 3:
                Text(text)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Text(text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let inline):
            inlineText(inline)
        case .codeBlock(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .padding(12)
            }
            .background(border.opacity(0.3))
            .cornerRadius(6)
        case .listItem(let inline, let ordered, _):
            HStack(alignment: .top, spacing: 6) {
                Text(ordered ? "•" : "•")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(accent)
                inlineText(inline)
            }
        case .blockquote(let inline):
            HStack(spacing: 0) {
                Rectangle().fill(accent.opacity(0.5)).frame(width: 3)
                inlineText(inline)
                    .padding(.leading, 12)
                    .italic()
                    .foregroundColor(textSecondary)
            }
            .padding(.vertical, 4)
        case .rule:
            Rectangle()
                .fill(border)
                .frame(height: 1)
                .padding(.vertical, 8)
        case .blank:
            Color.clear.frame(height: 6)
        }
    }

    private func inlineText(_ inlines: [MarkdownInline]) -> some View {
        // Render inlines as concatenated Text views
        let rendered: [AnyView] = inlines.map { inline in
            inline.render(
                accent: accent, textPrimary: textPrimary,
                textSecondary: textSecondary, textMuted: textMuted, border: border
            )
        }
        if rendered.isEmpty {
            return AnyView(Text("").foregroundColor(textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading))
        }
        return AnyView(HStack(spacing: 0) {
            ForEach(0..<rendered.count, id: \.self) { idx in rendered[idx] }
            Spacer()
        })
    }
}

// MARK: - ServerButton
// A compact dropdown showing the active AI server (slot). Click to switch.
// Slots are organized into sections: Creative / Local / Cloud (MiniMax).
// Each slot shows a "🛠 tools" badge if it supports tool/function calling,
// and a "🧠 thinking" badge if it supports reasoning tokens.

struct ServerButton: View {
    let activeSlotId: String
    let activeSlotName: String
    let accent: Color
    let textPrimary: Color
    let textMuted: Color
    let border: Color
    let onSelect: (String) -> Void

    @State private var isHovered: Bool = false
    @State private var showMenu: Bool = false

    /// Sections in display order
    private static let sectionOrder: [(key: String, title: String, icon: String)] = [
        ("creative", "Creative (writing)", "pencil.and.outline"),
        ("local", "Ollama / Local (tool-calling)", "wrench.and.screwdriver"),
        ("research", "Research & outlines", "magnifyingglass"),
        ("code", "Code", "chevron.left.forwardslash.chevron.right"),
        ("minimax", "MiniMax (Cloud)", "cloud"),
        ("cloud", "Other cloud", "cloud.fill"),
    ]

    private var groupedSlots: [(title: String, icon: String, slots: [LLMSlot])] {
        let allSlots = LLMSlotRegistry.shared.slots
        return Self.sectionOrder.compactMap { section in
            let matching = allSlots.filter { ($0.category ?? "local") == section.key }
            return matching.isEmpty ? nil : (section.title, section.icon, matching)
        }
    }

    var body: some View {
        Button(action: { showMenu.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: iconForType(slotTypeForId(activeSlotId)))
                    .font(.system(size: 9))
                    .foregroundColor(accent)
                Text(displayName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(isHovered ? textPrimary : textMuted)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? accent.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHovered ? accent.opacity(0.4) : border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Click to change AI server — slots are grouped by category")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "cpu").foregroundColor(accent)
                    Text("AI Server").font(.system(size: 11, weight: .bold))
                    Spacer()
                    if let active = LLMSlotRegistry.shared.slots.first(where: { $0.id == activeSlotId }),
                       active.toolCalling == true {
                        HStack(spacing: 3) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 9))
                                .foregroundColor(accent)
                            Text("tools")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(accent)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.15))
                        .cornerRadius(3)
                    }
                }
                .padding(8)
                .background(accent.opacity(0.1))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(groupedSlots, id: \.title) { section in
                            sectionView(title: section.title, icon: section.icon, slots: section.slots)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }
            .frame(width: 340)
        }
    }

    @ViewBuilder
    private func sectionView(title: String, icon: String, slots: [LLMSlot]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(accent)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            ForEach(slots) { slot in
                slotRow(slot: slot)
            }
        }
    }

    @ViewBuilder
    private func slotRow(slot: LLMSlot) -> some View {
        let isActive = slot.id == activeSlotId
        Button(action: {
            onSelect(slot.id)
            showMenu = false
        }) {
            HStack(spacing: 8) {
                Image(systemName: iconForType(slot.type))
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? accent : textMuted)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(slot.name)
                            .font(.system(size: 11, weight: isActive ? .bold : .medium))
                            .foregroundColor(isActive ? textPrimary : Color.secondary)
                            .lineLimit(1)
                        if slot.isDefault {
                            Text("DEFAULT")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(accent.opacity(0.2))
                                .foregroundColor(accent)
                                .cornerRadius(2)
                        }
                        if slot.toolCalling == true {
                            HStack(spacing: 2) {
                                Image(systemName: "wrench.fill")
                                    .font(.system(size: 7))
                                Text("tools")
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(.green)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(2)
                        }
                        if slot.thinking == true {
                            HStack(spacing: 2) {
                                Image(systemName: "brain")
                                    .font(.system(size: 7))
                                Text("think")
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(.purple)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(2)
                        }
                    }
                    Text("\(slot.type) · \(slot.modelId)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isActive ? accent.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var displayName: String {
        if activeSlotName.count > 30 {
            return String(activeSlotName.prefix(27)) + "..."
        }
        return activeSlotName
    }

    private func slotTypeForId(_ id: String) -> String {
        LLMSlotRegistry.shared.slots.first { $0.id == id }?.type ?? "ollama"
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "ollama": return "server.rack"
        case "mlx": return "cpu"
        case "minimax": return "cloud"
        case "lmstudio": return "desktopcomputer"
        case "custom": return "wrench.and.screwdriver"
        default: return "questionmark.circle"
        }
    }
}
