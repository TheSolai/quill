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
                .frame(maxHeight: 140)
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
                }
                Spacer()
            }
        }
        .background(bg)
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
            Button("Delete", role: .destructive) {
                Task { await state.deleteChapter(chapter) }
            }
        }
        .padding(.horizontal, 6)
    }
}
