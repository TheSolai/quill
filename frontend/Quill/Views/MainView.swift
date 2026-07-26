import SwiftUI
import AppKit

struct MainView: View {
    @StateObject private var state = AppState()
    @EnvironmentObject var commands: AppCommandsState
    @ObservedObject private var panel = PanelState.shared

    @State private var sidebarWidth: CGFloat = 240
    @State private var aiWidth: CGFloat = 360
    @State private var newProjectName = ""
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
                    showNewChapter: $commands.showNewChapter,
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

                // Right: AI Assistant (fixed side panel, always visible)
                AIAssistantView(
                    state: state,
                    bg: bgSecondary,
                    bgPrimary: bgPrimary,
                    accent: accent,
                    accentDim: accentDim,
                    textPrimary: textPrimary,
                    textSecondary: textSecondary,
                    textMuted: textMuted,
                    border: border,
                    width: aiWidth
                )
                .frame(width: aiWidth)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(bgPrimary)
            .overlay(alignment: .bottomTrailing) {
                ToastBanner(
                    center: ToastCenter.shared,
                    bg: bgSecondary,
                    textPrimary: textPrimary
                )
            }
            .onAppear {
                panel.clampHeight(for: geo.size.height)
                // Make sure everything is visible on start
                panel.isVisible = true
                panel.hiddenTabIds = []
            }
            .onChange(of: geo.size.height) { _, h in panel.clampHeight(for: h) }
        }
        .ignoresSafeArea()
        .task {
            await state.loadProjects()
            await LLMRegistry.shared.detectAndSelect()
            registerPanelTabs()
            // Make sure a project + chapter are open so the user can type
            // immediately. Runs after loadProjects and after the panel tabs
            // are registered (so the Inbox is ready in the background).
            await state.ensureReady()
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
        .sheet(isPresented: $commands.showNewChapter) {
            NewItemSheet(
                title: "New Chapter",
                placeholder: "chapter-4",
                value: $newChapterName,
                onSave: {
                    Task {
                        await state.createChapter(name: newChapterName)
                        newChapterName = ""
                        commands.showNewChapter = false
                    }
                },
                onCancel: { commands.showNewChapter = false }
            )
        }
        .sheet(isPresented: $commands.showEmailBook) {
            EmailTheBookSheet(state: state) {
                commands.showEmailBook = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveAsDocument)) { _ in
            // Defer to editor for save-as implementation
            NotificationCenter.default.post(name: Notification.Name("Quill.presentSaveAs"), object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealCurrentInFinder)) { _ in
            if let url = state.currentChapterURL() {
                AppCommandsState.shared.revealInFinder(url)
                AppCommandsState.shared.recordRecentFile(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAIProvider)) { note in
            // Re-used to handle "open recent" — extract project + chapter from userInfo
            if let info = note.userInfo,
               let projectId = info["open_project"] as? String,
               let chapterName = info["open_chapter"] as? String {
                Task { @MainActor in
                    await state.openProjectAndChapter(projectId: projectId, chapterName: chapterName)
                }
            }
        }
    }

    private func registerPanelTabs() {
        // Register each tab with the panel registry. Each builder takes the
        // AppState and returns an AnyView. Theme colors come from MainView's
        // stored properties.
        // Note: the Assistant is on the right side as a fixed panel, not a
        // bottom-panel tab.
        let bg = bgSecondary
        let bgP = bgPrimary
        let ac = accent
        let tP = textPrimary
        let tS = textSecondary
        let tM = textMuted
        let br = border

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

// MARK: - EmailTheBookSheet
//
// Failsafe panic button. Single field (recipient email) + dry-run preview +
// confirmation before sending. Intentionally minimal — the user has Mail.app
// for actual mail; this is just a "save my manuscript to my inbox" button.

struct EmailTheBookSheet: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void

    @State private var recipient: String = ""
    @State private var isSending: Bool = false
    @State private var isDryRun: Bool = false
    @State private var preview: AppState.EmailBookResult? = nil
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.accentColor)
                Text("Email the Book")
                    .font(.system(size: 16, weight: .bold))
            }
            Text("Bundle the current project and email it. Use this when the laptop's on fire or you need a copy of the manuscript in your inbox.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Send to")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("you@example.com", text: $recipient)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            if let preview = preview {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    previewLine("To", preview.would_send_to ?? recipient)
                    previewLine("Subject", preview.subject ?? "?")
                    if let book = preview.book {
                        previewLine("Book", "\(book.title ?? "?") (\(book.words ?? 0) words, \(book.format ?? "?"))")
                    }
                    previewLine("Attachment", preview.attachment_filename ?? "—")
                }
                .font(.system(size: 11, design: .monospaced))
            }

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
            if let ok = successMessage {
                Text(ok)
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Preview") { Task { await runDryRun() } }
                    .disabled(!canSend || isSending || isDryRun)
                Button("Send") { Task { await runSend() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend || isSending || preview == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func previewLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var canSend: Bool {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    private func runDryRun() async {
        errorMessage = nil
        successMessage = nil
        isDryRun = true
        defer { isDryRun = false }
        do {
            let result = try await state.emailTheBook(
                to: recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                dryRun: true
            )
            preview = result
        } catch {
            errorMessage = error.localizedDescription
            preview = nil
        }
    }

    private func runSend() async {
        errorMessage = nil
        successMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            let result = try await state.emailTheBook(
                to: recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let msgId = result.message_id ?? "?"
            successMessage = "Sent — message \(msgId). Check your inbox."
            preview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
