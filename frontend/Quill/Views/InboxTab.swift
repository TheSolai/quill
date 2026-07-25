import SwiftUI
import AppKit

// MARK: - InboxTab
//
// Email UI backed by AppState.inboxMessages (which polls /api/agentmail/
// inbox every 30s). Showing a list + viewer + compose form.
//
// We observe AppState directly so messages appear the moment they're
// loaded — the user doesn't have to click the Inbox tab first to trigger
// the fetch.

struct InboxTab: View {
    @ObservedObject var state: AppState
    let bg: Color
    let bgPrimary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    @State private var selectedMessageId: String? = nil
    @State private var showCompose: Bool = false
    @State private var composeTo: String = ""
    @State private var composeSubject: String = ""
    @State private var composeBody: String = ""
    @State private var composeStatus: String = ""
    @State private var isSending: Bool = false

    var body: some View {
        HSplitView {
            // Left: message list
            messageList
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)

            // Right: viewer or compose
            if showCompose {
                composePane
            } else if let id = selectedMessageId,
                      let msg = state.inboxMessages.first(where: { $0.id == id }) {
                messageViewer(msg)
            } else {
                emptyState
            }
        }
        .background(bgPrimary)
        .onAppear {
            // Auto-select the first message so the right pane isn't blank
            if selectedMessageId == nil, let first = state.inboxMessages.first {
                selectedMessageId = first.id
            }
        }
        .onChange(of: state.inboxMessages) { _, msgs in
            // If the current selection was deleted or never set, pick the first
            if selectedMessageId == nil || !msgs.contains(where: { $0.id == selectedMessageId }) {
                selectedMessageId = msgs.first?.id
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("INBOX")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                Button(action: { Task { await state.refreshInbox() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button(action: { showCompose = true; selectedMessageId = nil }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
                .help("Compose new email")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(bg)
            Divider().background(border)

            if state.inboxLoading && state.inboxMessages.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.inboxMessages.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "envelope")
                        .font(.system(size: 32))
                        .foregroundColor(textMuted.opacity(0.5))
                    Text("Inbox is empty")
                        .font(.system(size: 12))
                        .foregroundColor(textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.inboxMessages) { msg in
                            messageRow(msg)
                            Divider().background(border)
                        }
                    }
                }
            }

            Divider().background(border)
            HStack {
                Text("\(state.inboxMessages.count) messages")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                Text(state.inboxStatus)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bg)
        }
        .background(bg)
    }

    private func messageRow(_ msg: InboxMessage) -> some View {
        let isSelected = selectedMessageId == msg.id
        return Button(action: { selectedMessageId = msg.id; showCompose = false }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(msg.from)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(shortDate(msg.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Text(msg.subject)
                    .font(.system(size: 11))
                    .foregroundColor(textSecondary)
                    .lineLimit(1)
                Text(msg.preview)
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
                    .lineLimit(2)
                if msg.labels.contains("unread") {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(accent)
                            .frame(width: 4, height: 4)
                        Text("unread")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(accent)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? accent.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Viewer

    private func messageViewer(_ msg: InboxMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(msg.subject)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(textPrimary)
                        HStack(spacing: 4) {
                            Text("From:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(textMuted)
                            Text(msg.from)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(textSecondary)
                        }
                        HStack(spacing: 4) {
                            Text("Date:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(textMuted)
                            Text(fullDate(msg.timestamp))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(textSecondary)
                        }
                    }
                    Spacer()
                    Button(action: { replyTo(msg) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 10))
                            Text("Reply")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.2))
                        .foregroundColor(accent)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                Divider().background(border)
                Text(msg.body.isEmpty ? msg.preview : msg.body)
                    .font(.system(size: 12))
                    .foregroundColor(textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(bgPrimary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "envelope.open")
                .font(.system(size: 48))
                .foregroundColor(textMuted.opacity(0.3))
            Text("Select a message")
                .font(.system(size: 12))
                .foregroundColor(textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgPrimary)
    }

    // MARK: - Compose

    private var composePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("COMPOSE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                Button("Cancel") {
                    showCompose = false
                    composeTo = ""
                    composeSubject = ""
                    composeBody = ""
                    composeStatus = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(bg)
            Divider().background(border)
            VStack(alignment: .leading, spacing: 8) {
                field("To", text: $composeTo, placeholder: "user@example.com")
                field("Subject", text: $composeSubject, placeholder: "Subject")
                Text("Message")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                TextEditor(text: $composeBody)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(border, lineWidth: 1)
                    )
                    .frame(minHeight: 120)
            }
            .padding(16)
            Divider().background(border)
            HStack {
                if !composeStatus.isEmpty {
                    Text(composeStatus)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(composeStatus.hasPrefix("✓") ? .green : .red)
                }
                Spacer()
                Button(action: sendCompose) {
                    HStack(spacing: 4) {
                        if isSending { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10) }
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10))
                        Text("Send")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(accent.opacity(canSend ? 0.3 : 0.1))
                    .foregroundColor(canSend ? accent : textMuted)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(bg)
        }
        .background(bgPrimary)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .frame(width: 50, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(border, lineWidth: 1)
                )
        }
    }

    private var canSend: Bool {
        !composeTo.isEmpty && !composeSubject.isEmpty && !composeBody.isEmpty
    }

    private func sendCompose() {
        isSending = true
        composeStatus = "Sending…"
        Task {
            do {
                _ = try await BackendService.shared.post(
                    "/api/agentmail/send",
                    body: [
                        "to": composeTo,
                        "subject": composeSubject,
                        "text": composeBody,
                    ]
                ) as [String: String]
                await MainActor.run {
                    composeStatus = "✓ Sent"
                    isSending = false
                    // Clear after 1.5s
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if composeStatus == "✓ Sent" {
                            showCompose = false
                            composeTo = ""
                            composeSubject = ""
                            composeBody = ""
                            composeStatus = ""
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    composeStatus = "✗ \(error.localizedDescription)"
                    isSending = false
                }
            }
        }
    }

    private func replyTo(_ msg: InboxMessage) {
        composeTo = msg.from
        composeSubject = msg.subject.lowercased().hasPrefix("re:") ? msg.subject : "Re: \(msg.subject)"
        composeBody = "\n\n---\nOn \(fullDate(msg.timestamp)), \(msg.from) wrote:\n\(msg.body.isEmpty ? msg.preview : msg.body)"
        showCompose = true
        selectedMessageId = nil
    }

    // MARK: - Date helpers

    private func shortDate(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
            let out = DateFormatter()
            out.dateFormat = "MM/dd HH:mm"
            return out.string(from: d)
        }
        return s
    }

    private func fullDate(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
            let out = DateFormatter()
            out.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return out.string(from: d)
        }
        return s
    }
}
