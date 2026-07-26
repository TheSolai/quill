import SwiftUI
import AppKit

@MainActor
final class AppCommandsState: ObservableObject {
    static let shared = AppCommandsState()

    @Published var showSettings: Bool = false
    @Published var showExport: Bool = false
    @Published var showNewProject: Bool = false
    @Published var showNewChapter: Bool = false
    @Published var showSaveAs: Bool = false
    @Published var showEmailBook: Bool = false

    /// Most recently opened chapters (file paths) — max 10.
    @Published var recentFiles: [String] = []
    private static let recentKey = "Quill.recentFiles"
    private static let recentLimit = 10

    init() {
        // Load recent files from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: Self.recentKey) as? [String] {
            self.recentFiles = saved
        }
    }

    func recordRecentFile(_ path: String) {
        var list = recentFiles
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > Self.recentLimit { list = Array(list.prefix(Self.recentLimit)) }
        recentFiles = list
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    func clearRecentFiles() {
        recentFiles = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    /// Reveal a file or directory in Finder.
    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Parent dir if file missing
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.activateFileViewerSelecting([parent])
            }
        }
    }

    /// Open Terminal.app in the given directory.
    func openInTerminal(_ path: String) {
        let dir: String
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            dir = path
        } else {
            dir = (path as NSString).deletingLastPathComponent
        }
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(dir.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        if let apple = NSAppleScript(source: script) {
            var errorInfo: NSDictionary?
            _ = apple.executeAndReturnError(&errorInfo)
        }
    }
}

extension Notification.Name {
    static let toggleSidebar = Notification.Name("Quill.toggleSidebar")
    static let toggleAIPanel = Notification.Name("Quill.toggleAIPanel")
    static let saveDocument = Notification.Name("Quill.saveDocument")
    static let saveAsDocument = Notification.Name("Quill.saveAsDocument")
    static let renameCurrent = Notification.Name("Quill.renameCurrent")
    static let duplicateCurrent = Notification.Name("Quill.duplicateCurrent")
    static let revealCurrentInFinder = Notification.Name("Quill.revealCurrentInFinder")
    static let openCurrentInTerminal = Notification.Name("Quill.openCurrentInTerminal")
    static let selectAIProvider = Notification.Name("Quill.selectAIProvider")
    /// Send a prompt to the AI chat input. userInfo: { text: String, focus: Bool }
    static let sendToAI = Notification.Name("Quill.sendToAI")
    /// Cmd+L — request the editor view to grab focus
    static let focusEditor = Notification.Name("Quill.focusEditor")
    /// Cmd+K — request the AI chat input to grab focus
    static let focusChat = Notification.Name("Quill.focusChat")
}
