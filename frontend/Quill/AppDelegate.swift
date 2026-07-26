import Cocoa
import SwiftUI

private func log(_ msg: String) {
    FileHandle.standardError.write(Data("[Quill] \(msg)\n".utf8))
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var backendProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        ProcessManager.shared.startBackend()
        buildMenuBar()
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func showWindow() {
        log("showWindow called")

        let contentView = MainView()
            .environmentObject(AppCommandsState.shared)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("QuillMainWindow")
        window.contentView = NSHostingView(rootView: contentView)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(hex: "1e1e2e")
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 600)

        // Activate the app and bring the window to front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        log("window shown: visible=\(window.isVisible)")
    }

    func buildMenuBar() {
        let mainMenu = NSMenu()

        // Quill menu
        let quillMenu = NSMenu()
        quillMenu.addItem(NSMenuItem(title: "About Quill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        quillMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        quillMenu.addItem(settingsItem)

        quillMenu.addItem(NSMenuItem.separator())
        quillMenu.addItem(NSMenuItem(title: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let quillMenuItem = NSMenuItem(title: "Quill", action: nil, keyEquivalent: "")
        quillMenuItem.submenu = quillMenu
        mainMenu.addItem(quillMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let newProjectItem = NSMenuItem(title: "New Project...", action: #selector(openNewProject), keyEquivalent: "n")
        newProjectItem.target = self
        fileMenu.addItem(newProjectItem)

        let newChapterItem = NSMenuItem(title: "New Chapter...", action: #selector(openNewChapter), keyEquivalent: "N")
        newChapterItem.keyEquivalentModifierMask = [.command, .shift]
        newChapterItem.target = self
        fileMenu.addItem(newChapterItem)

        fileMenu.addItem(NSMenuItem.separator())

        let saveItem = NSMenuItem(title: "Save", action: #selector(saveDocument), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(saveAsDocument), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)

        fileMenu.addItem(NSMenuItem.separator())

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealCurrentInFinder), keyEquivalent: "R")
        revealItem.keyEquivalentModifierMask = [.command, .shift]
        revealItem.target = self
        fileMenu.addItem(revealItem)

        // Recent Files submenu — populated dynamically via menuNeedsUpdate
        let recentSubmenu = NSMenu(title: "Open Recent")
        recentSubmenu.autoenablesItems = false
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentSubmenu
        fileMenu.addItem(recentItem)

        let clearRecentItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentFiles), keyEquivalent: "")
        clearRecentItem.target = self
        recentSubmenu.addItem(clearRecentItem)
        recentSubmenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(NSMenuItem.separator())

        let exportItem = NSMenuItem(title: "Export Book...", action: #selector(openExport), keyEquivalent: "e")
        exportItem.target = self
        fileMenu.addItem(exportItem)

        let compileItem = NSMenuItem(title: "Compile Preview", action: #selector(openExport), keyEquivalent: "p")
        compileItem.keyEquivalentModifierMask = [.command, .shift]
        compileItem.target = self
        fileMenu.addItem(compileItem)

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self  // so we can update Recent Files submenu

        // AI menu — pick the active provider from this menu
        let aiMenu = NSMenu(title: "AI")
        let useOllama = NSMenuItem(
            title: "Use Ollama (Local)",
            action: #selector(useOllamaProvider),
            keyEquivalent: "1"
        )
        useOllama.keyEquivalentModifierMask = [.command, .shift]
        useOllama.target = self
        aiMenu.addItem(useOllama)

        let useCloud = NSMenuItem(
            title: "Use MiniMax (Cloud)",
            action: #selector(useCloudProvider),
            keyEquivalent: "2"
        )
        useCloud.keyEquivalentModifierMask = [.command, .shift]
        useCloud.target = self
        aiMenu.addItem(useCloud)

        let useApple = NSMenuItem(
            title: "Use Apple Intelligence",
            action: #selector(useAppleIntelligenceProvider),
            keyEquivalent: "3"
        )
        useApple.keyEquivalentModifierMask = [.command, .shift]
        useApple.target = self
        aiMenu.addItem(useApple)

        aiMenu.addItem(NSMenuItem.separator())

        // Dynamic slots submenu — populated from LLMSlotRegistry on display
        let slotsSubmenu = NSMenu(title: "Other Models")
        slotsSubmenu.autoenablesItems = false
        let slotsItem = NSMenuItem(title: "Other Models", action: nil, keyEquivalent: "")
        slotsItem.submenu = slotsSubmenu
        aiMenu.addItem(slotsItem)

        aiMenu.addItem(NSMenuItem.separator())

        let aiSettings = NSMenuItem(
            title: "AI Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        aiSettings.keyEquivalentModifierMask = [.command]
        aiSettings.target = self
        aiMenu.addItem(aiSettings)

        let aiMenuItem = NSMenuItem(title: "AI", action: nil, keyEquivalent: "")
        aiMenuItem.submenu = aiMenu
        mainMenu.addItem(aiMenuItem)
        aiMenu.delegate = self
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Panel toggle (Cmd+J, like Zed)
        let togglePanelItem = NSMenuItem(title: "Toggle Panel", action: #selector(togglePanel), keyEquivalent: "j")
        togglePanelItem.target = self
        viewMenu.addItem(togglePanelItem)

        // Tab submenu
        let tabsSubmenu = NSMenu(title: "Tabs")
        for tab in PanelState.shared.allTabs {
            let item = NSMenuItem(
                title: tab.title,
                action: #selector(toggleTabFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tab.id
            tabsSubmenu.addItem(item)
        }
        let tabsMenuItem = NSMenuItem(title: "Panel Tabs", action: nil, keyEquivalent: "")
        tabsMenuItem.submenu = tabsSubmenu
        viewMenu.addItem(tabsMenuItem)

        viewMenu.addItem(NSMenuItem.separator())
        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Refresh menu state when items are about to display
        viewMenu.autoenablesItems = false
        tabsSubmenu.autoenablesItems = false

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "Quill Help", action: #selector(showHelp), keyEquivalent: "?"))
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    @objc func openSettings() {
        Task { @MainActor in
            AppCommandsState.shared.showSettings = true
        }
    }

    @objc func openExport() {
        Task { @MainActor in
            AppCommandsState.shared.showExport = true
        }
    }

    @objc func saveDocument() {
        // Post a notification so the editor can save the current chapter.
        // The EditorView / AppState handle the actual save logic.
        NotificationCenter.default.post(name: .saveDocument, object: nil)
    }

    @objc func openNewProject() {
        Task { @MainActor in
            AppCommandsState.shared.showNewProject = true
        }
    }

    @objc func openNewChapter() {
        Task { @MainActor in
            AppCommandsState.shared.showNewChapter = true
        }
    }

    @objc func saveAsDocument() {
        NotificationCenter.default.post(name: .saveAsDocument, object: nil)
    }

    @objc func revealCurrentInFinder() {
        NotificationCenter.default.post(name: .revealCurrentInFinder, object: nil)
    }

    @objc func clearRecentFiles() {
        Task { @MainActor in
            AppCommandsState.shared.clearRecentFiles()
        }
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Task { @MainActor in
            // The path is a chapter .md file inside a project. Find which project
            // it belongs to and tell AppState to select it.
            let url = URL(fileURLWithPath: path)
            let projectId = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            // The host view can handle this; we just post a notification
            NotificationCenter.default.post(
                name: .selectAIProvider,  // reuse the notification mechanism
                object: nil,
                userInfo: ["open_project": projectId, "open_chapter": url.deletingPathExtension().lastPathComponent]
            )
        }
    }

    @objc func useOllamaProvider() {
        Task { @MainActor in
            LLMRegistry.shared.selectedProviderId = "ollama"
        }
    }

    @objc func useCloudProvider() {
        Task { @MainActor in
            // Find the first minimax slot
            if let minimax = LLMSlotRegistry.shared.slots.first(where: { $0.type == "minimax" }) {
                await LLMSlotRegistry.shared.setActive(minimax.id)
            } else {
                LLMRegistry.shared.selectedProviderId = "ollama"
            }
        }
    }

    @objc func useAppleIntelligenceProvider() {
        Task { @MainActor in
            LLMRegistry.shared.selectedProviderId = "apple_intelligence"
        }
    }

    @objc func selectSlotFromMenu(_ sender: NSMenuItem) {
        guard let slotId = sender.representedObject as? String else { return }
        Task { @MainActor in
            await LLMSlotRegistry.shared.setActive(slotId)
        }
    }

    @objc func toggleSidebar() {
        NotificationCenter.default.post(name: .toggleSidebar, object: nil)
    }

    @objc func togglePanel() {
        Task { @MainActor in
            PanelState.shared.togglePanel()
        }
    }

    @objc func toggleTabFromMenu(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        Task { @MainActor in
            PanelState.shared.toggleTab(tabId)
        }
    }

    // Validate menu items: check/uncheck tabs based on PanelState, populate
    // Recent Files and Other Models submenus, mark active AI provider.
    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            for item in menu.items {
                // Tab submenu: check/uncheck based on visibility
                if let tabId = item.representedObject as? String,
                   menu.title == "Tabs" || menu.title == "Panel Tabs" {
                    let isHidden = PanelState.shared.hiddenTabIds.contains(tabId)
                    item.state = isHidden ? .off : .on
                }
                // Recent files
                if let path = item.representedObject as? String,
                   menu.title == "Open Recent" {
                    item.title = (path as NSString).lastPathComponent
                    item.action = #selector(openRecentFile(_:))
                    item.target = self
                }
            }
            // Rebuild Recent Files submenu if it exists
            for item in menu.items {
                guard item.title == "Open Recent", let sub = item.submenu else { continue }
                rebuildRecentFilesSubmenu(sub)
            }
            // Rebuild Other Models submenu if it exists
            for item in menu.items {
                guard item.title == "Other Models", let sub = item.submenu else { continue }
                rebuildOtherModelsSubmenu(sub)
            }
            // AI menu — mark the active provider
            if menu.title == "AI" {
                for item in menu.items {
                    let active: Bool
                    if item.title == "Use Ollama (Local)" {
                        active = LLMRegistry.shared.selectedProviderId == "ollama"
                    } else if item.title == "Use Apple Intelligence" {
                        active = LLMRegistry.shared.selectedProviderId == "apple_intelligence"
                    } else if item.title == "Use MiniMax (Cloud)" {
                        let active = LLMSlotRegistry.shared.activeSlot?.type == "minimax"
                        _ = active
                        // Use slot-based check
                        _ = LLMSlotRegistry.shared.activeSlotId
                        let usingMinimax = LLMSlotRegistry.shared.activeSlot?.type == "minimax"
                        item.state = usingMinimax ? .on : .off
                        continue
                    } else {
                        item.state = .off
                        continue
                    }
                    item.state = active ? .on : .off
                }
            }
        }
    }

    @MainActor
    private func rebuildRecentFilesSubmenu(_ menu: NSMenu) {
        // Keep the "Clear Menu" item and the separator; remove all others
        let toRemove = menu.items.filter { ($0.representedObject as? String) != nil }
        for item in toRemove { menu.removeItem(item) }
        let recents = AppCommandsState.shared.recentFiles
        if recents.isEmpty {
            let placeholder = NSMenuItem(title: "No recent files", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            // Insert at index 1 (after Clear Menu)
            if menu.items.count > 0 {
                menu.insertItem(placeholder, at: 1)
            } else {
                menu.addItem(placeholder)
            }
            return
        }
        for (i, path) in recents.enumerated() {
            let item = NSMenuItem(
                title: (path as NSString).lastPathComponent,
                action: #selector(openRecentFile(_:)),
                keyEquivalent: i < 9 ? "\(i + 1)" : ""
            )
            if i < 9 { item.keyEquivalentModifierMask = [.command] }
            item.target = self
            item.representedObject = path
            item.toolTip = path
            // Insert after Clear Menu + separator
            let insertIndex = min(2, menu.items.count)
            menu.insertItem(item, at: insertIndex + (i > 0 ? 0 : 0))
        }
    }

    @MainActor
    private func rebuildOtherModelsSubmenu(_ menu: NSMenu) {
        // Remove all currently displayed slot items
        let toRemove = menu.items.filter { ($0.representedObject as? String) != nil }
        for item in toRemove { menu.removeItem(item) }
        // Group slots by category
        let slots = LLMSlotRegistry.shared.slots
        if slots.isEmpty {
            let placeholder = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return
        }
        let activeId = LLMSlotRegistry.shared.activeSlotId
        for slot in slots {
            let title = slot.name + (slot.toolCalling == true ? "  🛠" : "")
            let item = NSMenuItem(
                title: title,
                action: #selector(selectSlotFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = slot.id
            item.state = (slot.id == activeId) ? .on : .off
            item.toolTip = "\(slot.type) · \(slot.modelId)"
            menu.addItem(item)
        }
    }

    @objc func showHelp() {
        if let url = URL(string: "https://github.com/your-repo/quill") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessManager.shared.stopBackend()
    }
}

extension NSColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
