import SwiftUI
import AppKit

struct MainView: View {
    @StateObject private var state = AppState()
    @EnvironmentObject var commands: AppCommandsState
    @ObservedObject private var panel = PanelState.shared

    @State private var sidebarWidth: CGFloat = 240
    @State private var newProjectName = ""
    @State private var showNewChapter = false
    @State private var newChapterName = ""
    @State private var viewMode: SidebarView.ViewMode = .editor
    @State private var showStoryBible: Bool = false

    let bgPrimary = Color(hex: "1e1e2e")
    let bgSecondary = Color(hex: "181825")
    let accent = Color(hex: "cba6f7")
    let accentDim = Color(hex: "9399b2")
    let textPrimary = Color(hex: "cdd6f4")
    let textSecondary = Color(hex: "a6adc8")
    let textMuted = Color(hex: "6c7086")
    let border = Color(hex: "45475a")

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                SidebarView(
                    state: state,
                    bg: bgSecondary,
                    accent: accent,
                    textPrimary: textPrimary,
                    textSecondary: textSecondary,
                    textMuted: textMuted,
                    border: border,
                    showNewProject: $commands.showNewProject,
                    newProjectName: $newProjectName,
                    showNewChapter: $showNewChapter,
                    newChapterName: $newChapterName,
                    width: sidebarWidth,
                    viewMode: $viewMode,
                    showStoryBible: $showStoryBible
                )
                .frame(width: sidebarWidth)

                // Center column: editor area on top, bottom panel below
                VStack(spacing: 0) {
                    // Editor / Corkboard / Story Bible
                    Group {
                        if showStoryBible {
                            StoryBibleView(
                                state: state,
                                bgPrimary: bgPrimary,
                                bgSecondary: bgSecondary,
                                accent: accent,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                                textMuted: textMuted,
                                border: border
                            )
                        } else if viewMode == .corkboard {
                            CorkboardView(
                                state: state,
                                bgPrimary: bgPrimary,
                                bgSecondary: bgSecondary,
                                accent: accent,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                                textMuted: textMuted,
                                border: border,
                                onSelectChapter: { chapter in
                                    Task { await state.selectChapter(chapter) }
                                }
                            )
                        } else {
                            EditorView(
                                state: state,
                                bgPrimary: bgPrimary,
                                bgSecondary: bgSecondary,
                                accent: accent,
                                accentDim: accentDim,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                                textMuted: textMuted,
                                border: border
                            )
                        }
                    }
                    .frame(maxHeight: panel.isVisible ? max(100, geo.size.height - panel.height - 30) : .infinity)

                    if panel.isVisible {
                        PanelContainer(
                            state: state,
                            panel: panel,
                            bg: bgSecondary,
                            bgPrimary: bgPrimary,
                            accent: accent,
                            textPrimary: textPrimary,
                            textSecondary: textSecondary,
                            textMuted: textMuted,
                            border: border
                        )
                        .frame(height: panel.height)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(bgPrimary)
            .onAppear { panel.clampHeight(for: geo.size.height) }
            .onChange(of: geo.size.height) { _, h in panel.clampHeight(for: h) }
        }
        .ignoresSafeArea()
        .task {
            await state.loadProjects()
            await LLMRegistry.shared.detectAndSelect()
            registerPanelTabs()
        }
        .onChange(of: state.backendError) { _, newError in
            if let error = newError {
                print("[Quill] Backend error: \(error)")
            }
        }
        .sheet(isPresented: $commands.showSettings) {
            SettingsView(appState: state)
        }
        .sheet(isPresented: $commands.showExport) {
            ExportView(appState: state)
        }
        .sheet(isPresented: $commands.showNewProject) {
            NewProjectSheet(
                value: $newProjectName,
                onSave: {
                    Task {
                        await state.createProject(name: newProjectName)
                        newProjectName = ""
                        commands.showNewProject = false
                    }
                },
                onCancel: { commands.showNewProject = false }
            )
        }
        .sheet(isPresented: $showNewChapter) {
            NewItemSheet(
                title: "New Chapter",
                placeholder: "chapter-4",
                value: $newChapterName,
                onSave: {
                    Task {
                        await state.createChapter(name: newChapterName)
                        newChapterName = ""
                        showNewChapter = false
                    }
                },
                onCancel: { showNewChapter = false }
            )
        }
    }

    private func registerPanelTabs() {
        // Register each tab with the panel registry. Each builder takes the
        // AppState and returns an AnyView. Theme colors come from MainView's
        // stored properties.
        let bg = bgSecondary
        let bgP = bgPrimary
        let ac = accent
        let acD = accentDim
        let tP = textPrimary
        let tS = textSecondary
        let tM = textMuted
        let br = border

        PanelTabRegistry.shared.register("assistant") { state in
            AnyView(AIAssistantView(
                state: state,
                bg: bg, bgPrimary: bgP, accent: ac, accentDim: acD,
                textPrimary: tP, textSecondary: tS, textMuted: tM, border: br,
                width: 0
            ))
        }
        PanelTabRegistry.shared.register("terminal") { state in
            AnyView(TerminalTab(
                state: state,
                bgPrimary: bgP, bgSecondary: bg, accent: ac,
                textPrimary: tP, textSecondary: tS, textMuted: tM, border: br
            ))
        }
        PanelTabRegistry.shared.register("inbox") { state in
            AnyView(InboxTab(
                state: state,
                bg: bg, bgPrimary: bgP, accent: ac,
                textPrimary: tP, textSecondary: tS, textMuted: tM, border: br
            ))
        }
        PanelTabRegistry.shared.register("logs") { _ in
            AnyView(LogsTab(
                bg: bg, bgPrimary: bgP, accent: ac,
                textPrimary: tP, textSecondary: tS, textMuted: tM, border: br
            ))
        }
    }
}

struct NewProjectSheet: View {
    @Binding var value: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("New Project")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
            TextField("My Novel", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                Button("Create") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30)
        .frame(width: 380)
    }
}

struct NewItemSheet: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                Button("Create") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30)
        .frame(width: 380)
    }
}
