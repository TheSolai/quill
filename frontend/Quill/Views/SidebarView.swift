import SwiftUI

struct SidebarView: View {
    @ObservedObject var state: AppState
    let bg: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    @Binding var showNewProject: Bool
    @Binding var newProjectName: String
    @Binding var showNewChapter: Bool
    @Binding var newChapterName: String
    let width: CGFloat
    @Binding var viewMode: ViewMode
    @Binding var showStoryBible: Bool

    enum ViewMode: String, CaseIterable, Identifiable {
        case editor = "Outline"
        case corkboard = "Corkboard"
        case storyBible = "Story Bible"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .editor: return "list.bullet"
            case .corkboard: return "rectangle.grid.2x2"
            case .storyBible: return "book.closed.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 12))
                    .foregroundColor(accent)
                Text("QUILL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Spacer()
                Button(action: { showNewProject = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
                .help("New Project (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bg)

            Divider().background(border)

            // View mode picker
            HStack(spacing: 4) {
                ForEach(ViewMode.allCases) { mode in
                    Button(action: {
                        // Story Bible is a sheet, not a main view mode
                        if mode == .storyBible {
                            showStoryBible = true
                        } else {
                            showStoryBible = false
                            viewMode = mode
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 9))
                            Text(mode.rawValue)
                                .font(.system(size: 10))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(viewMode == mode && mode != .storyBible ? accent.opacity(0.2) : Color.clear)
                        .foregroundColor(viewMode == mode && mode != .storyBible ? accent : textMuted)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().background(border)

            VStack(alignment: .leading, spacing: 4) {
                Text("PROJECTS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.projects) { project in
                            projectButton(project)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }

            Divider().background(border)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CHAPTERS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                    Spacer()
                    if state.currentProject != nil {
                        Button(action: { showNewChapter = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("New Chapter")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                if state.currentProject == nil {
                    Text("Select a project")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 12)
                } else {
                    // List gives us native drag-to-reorder via .onMove.
                    // We style it to match the rest of the sidebar.
                    List {
                        ForEach(state.chapters) { chapter in
                            chapterRow(chapter)
                                .listRowBackground(
                                    state.currentChapter?.id == chapter.id
                                        ? accent.opacity(0.12)
                                        : bg
                                )
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        }
                        .onMove { from, to in
                            Task { await state.reorderChapters(from: from, to: to) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(bg)
                    .frame(maxHeight: viewMode == .corkboard ? 0 : 180)
                    .opacity(viewMode == .corkboard ? 0 : 1)
                }

                Spacer()
            }
        }
        .background(bg)
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
    }

    private func projectButton(_ project: Project) -> some View {
        Button(action: {
            Task { await state.selectProject(project) }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(state.currentProject?.id == project.id ? accent : textMuted)
                    .frame(width: 14)
                Text(project.name)
                    .font(.system(size: 12))
                    .foregroundColor(state.currentProject?.id == project.id ? textPrimary : textSecondary)
                    .lineLimit(1)
                Spacer()
                if project.chapterCount > 0 {
                    Text("\(project.chapterCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(state.currentProject?.id == project.id ? accent.opacity(0.12) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    /// Chapter row used inside the drag-to-reorder List. Looks the same
    /// as the old chapterButton but uses a `.onTapGesture` instead of
    /// wrapping in a Button (which swallows drag gestures in List).
    @ViewBuilder
    private func chapterRow(_ chapter: Chapter) -> some View {
        let isCurrent = state.currentChapter?.id == chapter.id
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(isCurrent ? accent : textMuted)
                .frame(width: 14)
            Text(chapter.name)
                .font(.system(size: 12))
                .foregroundColor(isCurrent ? textPrimary : textSecondary)
                .lineLimit(1)
            Spacer()
            // Word-count badge — rough estimate from file size
            if chapter.size > 0 {
                Text(Self.estimateWords(chapter.size))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(textMuted.opacity(0.7))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(bg.opacity(0.5))
                    .cornerRadius(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await state.selectChapter(chapter) }
        }
        .contextMenu {
            Button("Rename…") {
                renameTarget = .chapter(chapter)
                renameValue = chapter.name
                showRenameSheet = true
            }
            Button("Duplicate") {
                Task { await state.duplicateChapter(chapter) }
            }
            Divider()
            Button("Send to AI…") {
                sendToAI(preset: .extend(chapter))
            }
            Menu("Send to AI") {
                Button("Extend this chapter") {
                    sendToAI(preset: .extend(chapter))
                }
                Button("Continue from this chapter") {
                    sendToAI(preset: .continue(chapter))
                }
                Button("Summarize this chapter") {
                    sendToAI(preset: .summarize(chapter))
                }
                Button("Rewrite tighter") {
                    sendToAI(preset: .tighten(chapter))
                }
            }
            Divider()
            if let path = chapterPath(chapter) {
                Button("Reveal in Finder") {
                    AppCommandsState.shared.revealInFinder(path)
                }
                Button("Open in Terminal") {
                    AppCommandsState.shared.openInTerminal(path)
                }
                Divider()
            }
            Button("Delete", role: .destructive) {
                Task { await state.deleteChapter(chapter) }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - AI prompts

    private enum AIPreset {
        case extend(Chapter)
        case `continue`(Chapter)
        case summarize(Chapter)
        case tighten(Chapter)
    }

    private func sendToAI(preset: AIPreset) {
        let text: String
        switch preset {
        case .extend(let ch):
            text = "extend @\(ch.name) — "
        case .continue(let ch):
            text = "continue from @\(ch.name) — "
        case .summarize(let ch):
            text = "summarize @\(ch.name)"
        case .tighten(let ch):
            text = "rewrite @\(ch.name) tighter"
        }
        NotificationCenter.default.post(
            name: .sendToAI,
            object: nil,
            userInfo: ["text": text, "focus": true, "select": false]
        )
    }

    // MARK: - Path helpers

    /// Rough word-count estimate from file size in bytes. Avg prose is
    /// ~5.5 chars/word including spaces, but a markdown file is heavier
    /// on punctuation so we use 6. Used for the chapter-list badge.
    static func estimateWords(_ bytes: Int) -> String {
        let words = max(0, bytes / 6)
        if words >= 1000 {
            return String(format: "%.1fk", Double(words) / 1000.0)
        }
        return "\(words)w"
    }

    private func chapterPath(_ chapter: Chapter) -> String? {
        guard let project = state.currentProject else { return nil }
        return "\(BackendService.shared.baseDir)/\(project.id)/\(chapter.name).md"
    }

    // MARK: - Rename sheet state

    private enum RenameTarget {
        case chapter(Chapter)
    }
    @State private var renameTarget: RenameTarget?
    @State private var renameValue: String = ""
    @State private var showRenameSheet: Bool = false

    private var renameSheet: some View {
        VStack(spacing: 14) {
            Text("Rename")
                .font(.system(size: 14, weight: .bold))
            TextField("new-name", text: $renameValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack(spacing: 12) {
                Button("Cancel") {
                    showRenameSheet = false
                    renameTarget = nil
                }
                .buttonStyle(.bordered)
                Button("Rename") {
                    let target = renameTarget
                    let name = renameValue
                    showRenameSheet = false
                    renameTarget = nil
                    Task {
                        switch target {
                        case .chapter(let ch):
                            await state.renameChapter(ch, to: name)
                        case .none:
                            break
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
