import SwiftUI

/// Story Bible / Codex — the structured lore database the AI references.
/// Surfaces characters, world, summary, style, plot, themes.
struct StoryBibleView: View {
    @ObservedObject var state: AppState
    let bgPrimary: Color
    let bgSecondary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    @State private var localCodex: Codex = Codex(
        characters: "", world: "", summary: "", style: "", plot: "", themes: ""
    )
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "book.closed.fill")
                    .foregroundColor(accent)
                Text("STORY BIBLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Spacer()
                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                        localCodex = state.codex
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Save") {
                        Task {
                            state.codex = localCodex
                            await state.saveCodex()
                            isEditing = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Edit") { isEditing = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bgSecondary)

            Divider().background(border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    codexSection(
                        title: "Characters",
                        icon: "person.2.fill",
                        text: binding(for: \.characters)
                    )
                    codexSection(
                        title: "World & Setting",
                        icon: "globe",
                        text: binding(for: \.world)
                    )
                    codexSection(
                        title: "Summary",
                        icon: "doc.text.fill",
                        text: binding(for: \.summary)
                    )
                    codexSection(
                        title: "Style",
                        icon: "paintbrush.fill",
                        text: binding(for: \.style)
                    )
                    codexSection(
                        title: "Plot",
                        icon: "list.bullet.rectangle",
                        text: binding(for: \.plot)
                    )
                    codexSection(
                        title: "Themes",
                        icon: "tag.fill",
                        text: binding(for: \.themes)
                    )

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(textMuted)
                        Text("The AI references all of these when generating chapters.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                }
                .padding(16)
            }
            .background(bgPrimary)
        }
        .background(bgPrimary)
        .onAppear {
            Task { await state.loadCodex() }
            localCodex = state.codex
        }
    }

    private func binding(for keyPath: WritableKeyPath<Codex, String>) -> Binding<String> {
        Binding(
            get: { localCodex[keyPath: keyPath] },
            set: { localCodex[keyPath: keyPath] = $0 }
        )
    }

    private func codexSection(title: String, icon: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
            }
            if isEditing {
                TextEditor(text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(bgSecondary)
                    .frame(minHeight: 70)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(border, lineWidth: 1)
                    )
            } else {
                Text(text.wrappedValue.isEmpty ? "Not set — click Edit to add" : text.wrappedValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(text.wrappedValue.isEmpty ? textMuted : textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(bgSecondary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(border, lineWidth: 1)
                    )
                    .textSelection(.enabled)
            }
        }
    }
}
