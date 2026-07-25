import SwiftUI
import AppKit

// MARK: - PanelContainer
//
// The bottom panel — Zed-style. Has:
//   - A drag handle on top for resizing
//   - A tab bar with all visible tabs
//   - A close (×) button to hide the whole panel
//   - The current tab's content
//
// The container observes PanelState for currentTabId, height, and visibility.

struct PanelContainer: View {
    @ObservedObject var state: AppState
    let panel: PanelState
    let bg: Color
    let bgPrimary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle (top edge — drag to resize)
            PanelResizeHandle(panel: panel, accent: accent, border: border)
                .frame(height: 4)

            // Header with tabs + close button
            PanelHeader(state: state, panel: panel, accent: accent, textPrimary: textPrimary, textMuted: textMuted, border: border, bg: bg)
                .background(bg)

            Divider().background(border)

            // Tab content
            PanelBody(state: state, panel: panel, bgPrimary: bgPrimary, textPrimary: textPrimary, textSecondary: textSecondary, textMuted: textMuted, accent: accent)
                .background(bgPrimary)
        }
        .background(bg)
    }
}

// MARK: - Resize handle

struct PanelResizeHandle: View {
    @ObservedObject var panel: PanelState
    let accent: Color
    let border: Color
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartHeight: CGFloat = 0
    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(border.opacity(0.3))
            Rectangle()
                .fill(isHovering || isDragging ? accent : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartY = value.startLocation.y
                        dragStartHeight = panel.height
                    }
                    // Dragging up = increase height, dragging down = decrease
                    let delta = dragStartY - value.location.y
                    panel.height = dragStartHeight + delta
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

// MARK: - Header (tab bar)

struct PanelHeader: View {
    @ObservedObject var state: AppState
    @ObservedObject var panel: PanelState
    let accent: Color
    let textPrimary: Color
    let textMuted: Color
    let border: Color
    let bg: Color
    @State private var isHoveringClose: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Tab buttons
            ForEach(panel.visibleTabs) { tab in
                tabButton(tab: tab)
            }
            Spacer()
            // Close button (hide panel)
            Button(action: { panel.isVisible = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isHoveringClose ? textPrimary : textMuted)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHoveringClose ? Color.red.opacity(0.5) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .help("Hide panel (⌘J)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(bg)
    }

    private func tabButton(tab: PanelTabDescriptor) -> some View {
        let isActive = panel.currentTabId == tab.id
        return Button(action: {
            if isActive {
                panel.hideTab(tab.id)  // Click active tab to hide it
            } else {
                panel.selectTab(tab.id)
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10))
                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                // Special badge for inbox unread count
                if tab.id == "inbox" {
                    InboxCountBadge(accent: accent, textMuted: textMuted)
                }
                // Streaming indicator for assistant
                if tab.id == "assistant" && state.isStreaming {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? accent.opacity(0.2) : Color.clear)
            )
            .foregroundColor(isActive ? textPrimary : textMuted)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close Tab") { panel.hideTab(tab.id) }
            if !panel.hiddenTabIds.isEmpty {
                Divider()
                ForEach(panel.allTabs.filter { panel.hiddenTabIds.contains($0.id) }) { hidden in
                    Button("Show \(hidden.title)") { panel.showTab(hidden.id) }
                }
            }
        }
    }
}

// MARK: - Body (current tab content)

struct PanelBody: View {
    @ObservedObject var state: AppState
    @ObservedObject var panel: PanelState
    let bgPrimary: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color

    var body: some View {
        PanelTabRegistry.shared.view(for: panel.currentTabId, state: state)
            .id(panel.currentTabId)  // remount on tab switch
    }
}

// MARK: - Inbox count badge

struct InboxCountBadge: View {
    let accent: Color
    let textMuted: Color
    @State private var count: Int = 0

    var body: some View {
        Group {
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(accent.opacity(0.2))
                    .cornerRadius(6)
            }
        }
        .onAppear { refresh() }
        .task { await pollLoop() }
    }

    private func refresh() {
        Task {
            guard let url = URL(string: "http://127.0.0.1:5323/api/agentmail/inbox?limit=20") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msgs = json["messages"] as? [[String: Any]] {
                    await MainActor.run { self.count = msgs.count }
                }
            } catch {}
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(nanoseconds: 30_000_000_000)  // every 30s
        }
    }
}
