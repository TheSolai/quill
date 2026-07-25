import Cocoa
import SwiftUI

private func log(_ msg: String) {
    FileHandle.standardError.write(Data("[Quill] \(msg)\n".utf8))
}

class AppDelegate: NSObject, NSApplicationDelegate {
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

        fileMenu.addItem(NSMenuItem.separator())

        let saveItem = NSMenuItem(title: "Save", action: #selector(saveDocument), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)

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

    // Validate menu items: check/uncheck tabs based on PanelState
    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            for item in menu.items {
                if let tabId = item.representedObject as? String {
                    let isHidden = PanelState.shared.hiddenTabIds.contains(tabId)
                    item.state = isHidden ? .off : .on
                }
            }
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
