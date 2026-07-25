import SwiftUI

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
                } else {
                    Text("No chapter open")
                        .font(.system(size: 13))
                        .foregroundColor(textMuted)
                }
                Spacer()
                if state.isDirty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text("unsaved")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(accent)
                    }
                } else if state.currentChapter != nil {
                    Text("saved")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bgSecondary)

            Divider().background(border)

            if state.currentChapter != nil {
                TextEditor(text: $state.chapterContent)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(bgPrimary)
                    .padding(20)
                    .onChange(of: state.chapterContent) { _, _ in
                        state.isDirty = true
                        state.updateWordCount()
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundColor(textMuted.opacity(0.4))
                    Text("Select a chapter from the sidebar")
                        .font(.system(size: 13))
                        .foregroundColor(textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(bgPrimary)
            }

            Divider().background(border)

            HStack {
                Text("\(state.wordCount) words")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                if state.statusMessage == "Saved" {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(accent)
                        Text(state.statusMessage)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(accent)
                    }
                } else {
                    Text(state.statusMessage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(bgSecondary)
        }
        .background(bgPrimary)
    }
}
