import SwiftUI

@MainActor
final class AppCommandsState: ObservableObject {
    static let shared = AppCommandsState()

    @Published var showSettings: Bool = false
    @Published var showExport: Bool = false
    @Published var showNewProject: Bool = false
}

extension Notification.Name {
    static let toggleSidebar = Notification.Name("Quill.toggleSidebar")
    static let toggleAIPanel = Notification.Name("Quill.toggleAIPanel")
    static let saveDocument = Notification.Name("Quill.saveDocument")
}
