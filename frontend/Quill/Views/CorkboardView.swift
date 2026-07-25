import SwiftUI

/// Corkboard view — chapters as visual cards with synopses.
/// Mirrors Scrivener's corkboard, novelWriter's Novel View, and Manuskript's Storyboard.
struct CorkboardView: View {
    @ObservedObject var state: AppState
    let bgPrimary: Color
    let bgSecondary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    let onSelectChapter: (Chapter) -> Void

    @State private var editingSynopsis: String? = nil
    @State private var synopsisDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .foregroundColor(accent)
                Text("CORKBOARD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Text("·")
                    .foregroundColor(textMuted)
                Text("\(state.chapters.count) chapter\(state.chapters.count == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                Text("Click a card to open · click synopsis to edit")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bgSecondary)

            Divider().background(border)

            if state.chapters.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(state.chapters) { chapter in
                            CorkboardCard(
                                chapter: chapter,
                                synopsis: state.synopses[chapter.name] ?? "",
                                isSelected: state.currentChapter?.id == chapter.id,
                                isEditing: editingSynopsis == chapter.name,
                                synopsisDraft: $synopsisDraft,
                                accent: accent,
                                bgSecondary: bgSecondary,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                                textMuted: textMuted,
                                border: border,
                                onTap: { onSelectChapter(chapter) },
                                onStartEdit: {
                                    editingSynopsis = chapter.name
                                    synopsisDraft = state.synopses[chapter.name] ?? ""
                                },
                                onCommit: {
                                    Task {
                                        await state.setSynopsis(chapter.name, synopsis: synopsisDraft)
                                        editingSynopsis = nil
                                    }
                                },
                                onCancel: { editingSynopsis = nil }
                            )
                        }
                    }
                    .padding(16)
                }
                .background(bgPrimary)
            }
        }
        .background(bgPrimary)
        .onAppear { Task { await state.loadAllSynopses() } }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(textMuted.opacity(0.4))
            Text("No chapters yet")
                .font(.system(size: 13))
                .foregroundColor(textMuted)
            Text("Create chapters in the sidebar to see them as cards")
                .font(.system(size: 11))
                .foregroundColor(textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgPrimary)
    }
}

struct CorkboardCard: View {
    let chapter: Chapter
    let synopsis: String
    let isSelected: Bool
    let isEditing: Bool
    @Binding var synopsisDraft: String
    let accent: Color
    let bgSecondary: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    let onTap: () -> Void
    let onStartEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "book.fill")
                    .font(.system(size: 10))
                    .foregroundColor(accent)
                Text(chapter.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .lineLimit(1)
                Spacer()
                if !synopsis.isEmpty || isEditing {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 9))
                        .foregroundColor(textMuted)
                }
            }

            // The "card" — yellow with a darker border, like a sticky note
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextEditor(text: $synopsisDraft)
                        .font(.system(size: 12, design: .serif))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 60, maxHeight: 100)
                    HStack {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                        Button("Save", action: onCommit)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                } else {
                    Text(synopsis.isEmpty ? "Click to add synopsis…" : synopsis)
                        .font(.system(size: 12, design: .serif))
                        .foregroundColor(synopsis.isEmpty ? textMuted : textSecondary)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                }
            }
            .padding(10)
            .background(Color(hex: "f5e9b8"))  // sticky note yellow
            .foregroundColor(.black)
            .cornerRadius(4)
            .shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 1)
            .onTapGesture(count: 2) {
                onStartEdit()
            }

            HStack {
                Text("\(formatSize(chapter.size))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                if let date = Date(timeIntervalSince1970: chapter.modified) as Date? {
                    Text(date, style: .relative)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(textMuted)
                }
            }
        }
        .padding(10)
        .background(isSelected ? accent.opacity(0.2) : bgSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? accent : border, lineWidth: isSelected ? 2 : 1)
        )
        .cornerRadius(6)
        .onTapGesture { onTap() }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
