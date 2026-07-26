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
    // When set (non-zero), the view pins to that width (used in side panel).
    // When 0 or negative, the view fills the available space (used in tabs).
    var width: CGFloat = 0

    @State private var inputText: String = ""
    @State private var generationMode: AppState.GenerationMode = .long
    @State private var outlineHint: String = ""
    @ObservedObject private var slotRegistry = LLMSlotRegistry.shared

    private var statusLine: String {
        let model = slotRegistry.activeSlot?.name ?? "—"
        let shortModel = model.components(separatedBy: " (").first ?? model
        return generationMode == .long
            ? "Long form · multi-pass · \(shortModel)"
            : "Chat · \(shortModel)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundColor(accent)
                Text("QUILL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Spacer()
                // Backend connection status
                BackendStatusDot(
                    ollamaReachable: state.ollamaReachable,
                    backendReady: state.isBackendReady,
                    textMuted: textMuted,
                    accent: accent
                )
                // Inbox unread count (data comes from AppState which polls
                // every 30s — no separate fetcher needed here)
                if !state.inboxMessages.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        Text("\(state.inboxMessages.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(accent)
                    }
                    .help("Inbox: \(state.inboxMessages.count) recent messages — open the Inbox tab in the bottom panel")
                }
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
                    ChatInputView(
                        text: $inputText,
                        placeholder: generationMode == .long
                            ? "Write a chapter, continue, or research... (⏎ to send, ⇧⏎ for newline)"
                            : "Ask a question, brainstorm... (⏎ to send, ⇧⏎ for newline)",
                        isDisabled: state.isStreaming,
                        onSend: send,
                        font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        textColor: NSColor(textPrimary),
                        background: NSColor(bg.opacity(0.5)),
                        border: NSColor(border),
                        placeholderColor: NSColor(textMuted)
                    )
                    .frame(minHeight: 38, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(border, lineWidth: 1)
                    )

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
                    Text(statusLine)
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
              !lastMsg.content.isEmpty,
              let chapter = state.currentChapter,
              let project = state.currentProject else { return }
        // Update local content
        if state.chapterContent.isEmpty {
            state.chapterContent = lastMsg.content
        } else {
            state.chapterContent += "\n\n" + lastMsg.content
        }
        state.markDirty()
        state.updateWordCount()
        state.statusMessage = "Applied to chapter"
        // Persist immediately (user clicked a button, not waiting for autosave)
        Task { await state.saveNow() }
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

// MARK: - Backend status indicator
// Small dot that shows whether the backend is reachable and Ollama is up.
// Green = both ready. Yellow = backend up, Ollama down. Red = backend down.

struct BackendStatusDot: View {
    let ollamaReachable: Bool
    let backendReady: Bool
    let textMuted: Color
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textMuted)
        }
        .help(helpText)
    }

    private var color: Color {
        if !backendReady { return Color.red }
        if !ollamaReachable { return Color.orange }
        return Color.green
    }
    private var label: String {
        if !backendReady { return "offline" }
        if !ollamaReachable { return "no-ollama" }
        return "ready"
    }
    private var helpText: String {
        if !backendReady { return "Backend is unreachable. Start the Python server." }
        if !ollamaReachable { return "Backend is up, but Ollama is not responding. Check `ollama serve`." }
        return "Backend and Ollama are ready."
    }
}
