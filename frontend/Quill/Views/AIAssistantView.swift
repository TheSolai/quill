import SwiftUI

struct AIAssistantView: View {
    @ObservedObject var state: AppState
    let bg: Color
    let bgPrimary: Color
    let accent: Color
    let accentDim: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    let width: CGFloat

    @State private var inputText: String = ""
    @State private var generationMode: AppState.GenerationMode = .long
    @State private var outlineHint: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundColor(accent)
                Text("AI ASSISTANT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                if state.isStreaming {
                    HStack(spacing: 5) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("generating")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(accent)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(bg)

            Divider().background(border)

            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    modeButton(label: "Short", icon: "bolt.fill", mode: .short)
                    modeButton(label: "Long", icon: "text.word.spacing", mode: .long)
                }
                .background(bg.opacity(0.3))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(border, lineWidth: 1)
                )

                if generationMode == .long {
                    hintText("📖 Long form: \"write chapter 3\" — full multi-pass generation")
                    hintText("🧠 \"research X, then populate chapter 4\"")
                    hintText("✏️ \"continue chapter 2\" — builds on existing content")

                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        TextField("Optional chapter outline or notes...", text: $outlineHint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textSecondary)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(bg.opacity(0.4))
                    .cornerRadius(4)
                } else {
                    hintText("💬 Short form: chat, brainstorm, ask questions")
                    hintText("🔍 \"what are good twists for chapter 2?\"")
                    hintText("🧪 \"help me develop this character: ...\"")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bg.opacity(0.4))

            Divider().background(border.opacity(0.5))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.messages) { msg in
                            MessageBubble(
                                message: msg,
                                accent: accent,
                                accentDim: accentDim,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                                textMuted: textMuted,
                                border: border,
                                bg: bg
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.messages.count) { _, _ in
                    if let last = state.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(bgPrimary.opacity(0.3))

            Divider().background(border)

            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextEditor(text: $inputText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(bg.opacity(0.5))
                        .cornerRadius(8)
                        .frame(minHeight: 38, maxHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(border, lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if inputText.isEmpty {
                                Text(generationMode == .long
                                     ? "Write a chapter, continue from existing, or research a topic..."
                                     : "Ask a question, brainstorm, get feedback...")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }

                    VStack(spacing: 4) {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(
                                    inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? textMuted : accent
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isStreaming)

                        if state.currentChapter != nil {
                            Button(action: applyToChapter) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(accentDim)
                            }
                            .buttonStyle(.plain)
                            .help("Apply last response to current chapter")
                        }
                    }
                }

                HStack {
                    Text(generationMode == .long ? "Long form · multi-pass · gemma4" : "Short form · chat · gemma4")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textMuted)
                    Spacer()
                    if let chapter = state.currentChapter {
                        Text("→ \(chapter.name).md")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(accent.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(bg)
        }
        .background(bgPrimary)
        .onAppear {
            if state.messages.isEmpty {
                state.messages.append(ChatMessage(
                    role: .assistant,
                    content: """
                    👋 I'm Quill — your writing partner.

                    **Long form mode** (default): I'll write full chapters using a multi-pass approach — scene generation, sensory enhancement, character tracking, and narrative summary updates.

                    **Short form mode**: Quick chat for brainstorming, plot questions, character development, feedback.

                    Try: *write chapter 3* or *what are the best plot twists for chapter 2?*
                    """
                ))
            }
        }
    }

    private func modeButton(label: String, icon: String, mode: AppState.GenerationMode) -> some View {
        Button(action: { generationMode = mode }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(generationMode == mode ? .white : textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(generationMode == mode ? accent : Color.clear)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(accentDim)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await state.sendMessage(
                text,
                mode: generationMode,
                chapter: state.currentChapter?.name ?? "",
                outline: outlineHint
            )
        }
    }

    private func applyToChapter() {
        guard let lastMsg = state.messages.last,
              lastMsg.role == .assistant,
              !lastMsg.isStreaming,
              !lastMsg.content.isEmpty else { return }
        if state.chapterContent.isEmpty {
            state.chapterContent = lastMsg.content
        } else {
            state.chapterContent += "\n\n" + lastMsg.content
        }
        state.isDirty = true
        state.updateWordCount()
        state.statusMessage = "Applied to chapter"
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let accent: Color
    let accentDim: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    let bg: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                    .frame(width: 20)
            } else {
                Spacer().frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                if message.role == .user {
                    Text(message.content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(textPrimary)
                        .textSelection(.enabled)
                } else {
                    Text(message.content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(message.isStreaming ? accent : textSecondary)
                        .textSelection(.enabled)
                        .overlay(alignment: .bottomTrailing) {
                            if message.isStreaming {
                                Text("▌")
                                    .foregroundColor(accent)
                                    .font(.system(size: 12))
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
