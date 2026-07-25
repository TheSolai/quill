import SwiftUI
import AppKit

// MARK: - PanelState
//
// Tracks the bottom panel's tabs, current tab, and visibility. This is the
// shared state that the View menu and the panel container both observe.
//
// Tabs are declared by their `id` and the panel looks up the view builder
// from `PanelTabRegistry` (a singleton). This means views can be defined
// in their own files and just register themselves.

@MainActor
final class PanelState: ObservableObject {
    static let shared = PanelState()

    @Published var isVisible: Bool = true
    @Published var currentTabId: String = "assistant"
    @Published var height: CGFloat = 320
    @Published var hiddenTabIds: Set<String> = []

    /// All tabs that can appear in the bottom panel, in display order.
    /// Hidden tabs are filtered out when building the tab bar.
    let allTabs: [PanelTabDescriptor] = [
        PanelTabDescriptor(
            id: "assistant",
            title: "Assistant",
            icon: "sparkles",
            isVisibleByDefault: true
        ),
        PanelTabDescriptor(
            id: "terminal",
            title: "Terminal",
            icon: "terminal",
            isVisibleByDefault: true
        ),
        PanelTabDescriptor(
            id: "inbox",
            title: "Inbox",
            icon: "envelope",
            isVisibleByDefault: true
        ),
        PanelTabDescriptor(
            id: "logs",
            title: "Logs",
            icon: "doc.text.below.ecg",
            isVisibleByDefault: false
        ),
    ]

    var visibleTabs: [PanelTabDescriptor] {
        allTabs.filter { !hiddenTabIds.contains($0.id) }
    }

    func showTab(_ id: String) {
        hiddenTabIds.remove(id)
        currentTabId = id
    }

    func hideTab(_ id: String) {
        hiddenTabIds.insert(id)
        // If we hid the current tab, switch to the first visible one
        if currentTabId == id, let first = visibleTabs.first {
            currentTabId = first.id
        }
    }

    func toggleTab(_ id: String) {
        if hiddenTabIds.contains(id) {
            showTab(id)
        } else if currentTabId == id {
            hideTab(id)
        } else {
            currentTabId = id
        }
    }

    func togglePanel() {
        isVisible.toggle()
    }

    func selectTab(_ id: String) {
        // If tab is hidden, show it
        hiddenTabIds.remove(id)
        currentTabId = id
        isVisible = true
    }

    /// Clamp height to a sensible range when the window resizes.
    func clampHeight(for windowHeight: CGFloat) {
        let lo: CGFloat = 100
        let hi = Swift.max(120, windowHeight - 200)  // leave at least 200px for editor
        height = Swift.min(Swift.max(height, lo), hi)
    }
}

/// Static description of a panel tab (id, title, icon). The actual view is
/// looked up from `PanelTabRegistry` at render time.
struct PanelTabDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let isVisibleByDefault: Bool
}

// MARK: - PanelTabRegistry
//
// Maps tab id → view builder. Each tab registers itself at app launch.
// The panel container calls the builder to get the SwiftUI view.

@MainActor
final class PanelTabRegistry {
    static let shared = PanelTabRegistry()

    private var builders: [String: (AppState, AnyView) -> AnyView] = [:]
    // We need access to AppState, so builders take it as a parameter.

    func register(_ id: String, builder: @escaping (AppState) -> AnyView) {
        builders[id] = { state, _ in builder(state) }
    }

    func view(for id: String, state: AppState) -> AnyView {
        if let builder = builders[id] {
            return builder(state, AnyView(EmptyView()))
        }
        return AnyView(
            VStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                Text("Unknown tab: \(id)")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}
