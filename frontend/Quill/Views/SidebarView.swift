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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(state.chapters) { chapter in
                                chapterButton(chapter)
                            }
                        }
                    }
                    .frame(maxHeight: viewMode == .corkboard ? 0 : 180)
                    .opacity(viewMode == .corkboard ? 0 : 1)
                }

                // Scenes (only when a chapter is selected AND viewMode is not corkboard)
                if state.currentChapter != nil && viewMode != .corkboard {
                    Divider().background(border)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("SCENES")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            Spacer()
                            Button(action: {
                                Task { await state.createScene(name: "scene-\(state.scenes.count + 1)") }
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(state.scenes) { scene in
                                    sceneButton(scene)
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                    }
                }
                Spacer()
            }
        }
        .background(bg)
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
    }

    private func sceneButton(_ scene: Scene) -> some View {
        Button(action: {
            Task { await state.selectScene(scene) }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle")
                    .font(.system(size: 9))
                    .foregroundColor(state.currentScene?.id == scene.id ? accent : textMuted)
                    .frame(width: 14)
                Text(scene.name)
                    .font(.system(size: 11))
                    .foregroundColor(state.currentScene?.id == scene.id ? textPrimary : textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(state.currentScene?.id == scene.id ? accent.opacity(0.12) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                renameTarget = .scene(scene)
                renameValue = scene.name
                showRenameSheet = true
            }
            Button("Duplicate") {
                Task { await state.duplicateScene(scene) }
            }
            Divider()
            if let path = scenePath(scene) {
                Button("Reveal in Finder") {
                    AppCommandsState.shared.revealInFinder(path)
                }
                Button("Open in Terminal") {
                    AppCommandsState.shared.openInTerminal(path)
                }
                Divider()
            }
            Button("Delete", role: .destructive) {
                Task { await state.deleteScene(scene) }
            }
        }
        .padding(.horizontal, 6)
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

    private func chapterButton(_ chapter: Chapter) -> some View {
        Button(action: {
            Task { await state.selectChapter(chapter) }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(state.currentChapter?.id == chapter.id ? accent : textMuted)
                    .frame(width: 14)
                Text(chapter.name)
                    .font(.system(size: 12))
                    .foregroundColor(state.currentChapter?.id == chapter.id ? textPrimary : textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(state.currentChapter?.id == chapter.id ? accent.opacity(0.12) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
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

    // MARK: - Path helpers

    private func chapterPath(_ chapter: Chapter) -> String? {
        guard let project = state.currentProject else { return nil }
        return "\(BackendService.shared.baseDir)/\(project.id)/\(chapter.name).md"
    }

    private func scenePath(_ scene: Scene) -> String? {
        guard let project = state.currentProject, let chapter = state.currentChapter else { return nil }
        return "\(BackendService.shared.baseDir)/\(project.id)/\(chapter.name)/\(scene.name).md"
    }

    // MARK: - Rename sheet state

    private enum RenameTarget {
        case chapter(Chapter)
        case scene(Scene)
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
                        case .scene(let sc):
                            await state.renameScene(sc, to: name)
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
