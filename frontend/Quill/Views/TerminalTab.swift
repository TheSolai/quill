import SwiftUI
import AppKit

// MARK: - TerminalTab
//
// REPL-style embedded terminal. Each command is a one-shot Process. The
// output accumulates in a scrollable history. Arrow keys navigate command
// history. Tab is handled normally (insert tab into input).
//
// Why one-shot Process instead of full PTY?
//   - We don't need vim/htop — we need to run `quill chat`, `ls`, etc.
//   - Much simpler to implement and maintain
//   - No ANSI parsing required
//   - Each command is a fresh process so there's no state to corrupt
//
// The downside: no interactive programs (vim, less, top). If you need that,
// spawn `quill-ai-helper` from here as a child.

struct TerminalTab: View {
    @ObservedObject var state: AppState
    let bgPrimary: Color
    let bgSecondary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    @State private var entries: [TerminalEntry] = []
    @State private var input: String = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int = -1  // -1 = current input
    @State private var isRunning: Bool = false
    @State private var currentDir: String = NSHomeDirectory() + "/Projects/Quill"
    @State private var autoScroll: Bool = true
    @FocusState private var inputFocused: Bool

    private static let maxHistoryLines = 2000

    var body: some View {
        VStack(spacing: 0) {
            // Output area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            TerminalEntryView(entry: entry, accent: accent, textPrimary: textPrimary, textSecondary: textSecondary, textMuted: textMuted)
                                .id(entry.id)
                        }
                        // Spacer at the bottom so auto-scroll lands comfortably
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(bgPrimary)
                .onChange(of: entries.count) { _, _ in
                    if autoScroll {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            Divider().background(border)

            // Input row
            inputBar
                .background(bgSecondary)
        }
        .background(bgPrimary)
        .onAppear {
            inputFocused = true
            if entries.isEmpty {
                addEntry(.info("Quill terminal — type a command and press Return. ↑/↓ for history."))
                addEntry(.info("Tip: try `quill status`, `quill slots`, `quill projects list`"))
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            // Prompt
            Text(currentDirAbbrev + " ❯")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(accent)
            // Input
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textPrimary)
                .focused($inputFocused)
                .onSubmit { runCommand() }
                .onKeyPress(.upArrow) {
                    navigateHistory(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    navigateHistory(1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    // Try to complete the current command
                    if let completed = tryTabComplete(input) {
                        input = completed
                    }
                    return .handled
                }
                .overlay(alignment: .leading) {
                    if input.isEmpty {
                        Text("type a command…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textMuted)
                            .allowsHitTesting(false)
                    }
                }
            if isRunning {
                ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
            }
            // Toolbar
            Button(action: clearScreen) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
            }
            .buttonStyle(.plain)
            .help("Clear screen")
            Button(action: { autoScroll.toggle() }) {
                Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundColor(autoScroll ? accent : textMuted)
            }
            .buttonStyle(.plain)
            .help(autoScroll ? "Auto-scroll: on" : "Auto-scroll: off")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var currentDirAbbrev: String {
        let home = NSHomeDirectory()
        if currentDir.hasPrefix(home) {
            return "~" + currentDir.dropFirst(home.count)
        }
        return currentDir
    }

    // MARK: - Command execution

    private func runCommand() {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let cmd = raw
        // Echo the command
        addEntry(.command(cmd, dir: currentDir))
        // Push to history (deduped, max 200)
        if history.last != cmd {
            history.append(cmd)
            if history.count > 200 { history.removeFirst(history.count - 200) }
        }
        historyIndex = -1
        input = ""

        // Handle builtins
        if handleBuiltin(cmd) { return }

        // Run via Process
        isRunning = true
        Task {
            await runProcess(cmd)
            isRunning = false
        }
    }

    /// Returns true if the command was handled internally (no shell run).
    private func handleBuiltin(_ cmd: String) -> Bool {
        let parts = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return false }
        switch first {
        case "clear", "cls":
            clearScreen()
            return true
        case "pwd":
            addEntry(.output(currentDir))
            return true
        case "cd":
            let target = parts.count > 1 ? parts[1] : NSHomeDirectory()
            let resolved = resolvePath(target)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                currentDir = resolved
            } else {
                addEntry(.error("cd: no such directory: \(target)"))
            }
            return true
        case "exit", "quit":
            // Just clear and ignore — there's no way to really exit
            addEntry(.info("Quill terminal — type a command and press Return."))
            return true
        case "help":
            addEntry(.info("Builtins: clear, pwd, cd <path>, exit, help"))
            addEntry(.info("Anything else runs in /bin/sh -c. Try: quill status, ls, git status"))
            return true
        default:
            return false
        }
    }

    private func runProcess(_ cmd: String) async {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: currentDir)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"  // most programs respect this and skip ANSI
        env["NO_COLOR"] = "1"
        process.environment = env

        do {
            try process.run()
        } catch {
            addEntry(.error("failed to launch: \(error.localizedDescription)"))
            return
        }

        // Read stdout/stderr concurrently
        async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(stderrPipe.fileHandleForReading)

        let (out, err) = await (stdoutData, stderrData)
        process.waitUntilExit()

        let stdoutStr = String(data: out, encoding: .utf8) ?? ""
        let stderrStr = String(data: err, encoding: .utf8) ?? ""
        let status = process.terminationStatus

        if !stdoutStr.isEmpty {
            addEntry(.output(stdoutStr))
        }
        if !stderrStr.isEmpty {
            addEntry(.error(stderrStr))
        }
        if stdoutStr.isEmpty && stderrStr.isEmpty && status == 0 {
            addEntry(.info("(no output, exit 0)"))
        }
        if status != 0 {
            addEntry(.info("exit \(status)"))
        }
    }

    private func readAll(_ handle: FileHandle) async -> Data {
        return await withCheckedContinuation { continuation in
            // Read on a background queue so we don't block the main thread
            DispatchQueue.global(qos: .userInitiated).async {
                var collected = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    collected.append(chunk)
                }
                continuation.resume(returning: collected)
            }
        }
    }

    // MARK: - History navigation

    private func navigateHistory(_ direction: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            historyIndex = history.count  // one past end (about to go back)
        }
        let newIndex = historyIndex + direction
        if newIndex < 0 { return }  // already at start
        if newIndex >= history.count {
            // Past the end → restore the current input
            historyIndex = -1
            input = ""
            return
        }
        historyIndex = newIndex
        input = history[newIndex]
    }

    // MARK: - Tab completion (very basic)

    private func tryTabComplete(_ prefix: String) -> String? {
        // Just try to complete the last word
        let parts = prefix.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        let lastWord = parts.last!
        // Skip past the last word
        let base = String(prefix.dropLast(lastWord.count))
        let expanded = (base as NSString).expandingTildeInPath
        let searchDir: String
        let namePrefix: String
        if lastWord.contains("/") {
            let url = URL(fileURLWithPath: expanded)
            searchDir = url.deletingLastPathComponent().path
            namePrefix = url.lastPathComponent
        } else {
            searchDir = currentDir
            namePrefix = lastWord
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: searchDir) else {
            return nil
        }
        let matches = entries.filter { $0.hasPrefix(namePrefix) }.sorted()
        if matches.count == 1 {
            // Single match — complete it
            var completion = matches[0]
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: searchDir + "/" + completion, isDirectory: &isDir)
            if isDir.boolValue { completion += "/" }
            return base + completion
        } else if matches.count > 1 {
            // Multiple matches — show them
            addEntry(.info(matches.joined(separator: "  ")))
            return nil
        }
        return nil
    }

    // MARK: - Path helpers

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return currentDir + "/" + path
    }

    // MARK: - Output

    private func addEntry(_ entry: TerminalEntry) {
        entries.append(entry)
        // Trim to max
        if entries.count > Self.maxHistoryLines {
            entries.removeFirst(entries.count - Self.maxHistoryLines)
        }
    }

    private func clearScreen() {
        entries.removeAll()
    }
}

// MARK: - Terminal entry

struct TerminalEntry: Identifiable {
    enum Kind {
        case command(String, dir: String)
        case output(String)
        case error(String)
        case info(String)
    }
    let id = UUID()
    let kind: Kind
    let timestamp = Date()

    init(kind: Kind) {
        self.kind = kind
    }

    // Convenience factory methods
    static func command(_ cmd: String, dir: String) -> TerminalEntry {
        TerminalEntry(kind: .command(cmd, dir: dir))
    }
    static func output(_ text: String) -> TerminalEntry {
        TerminalEntry(kind: .output(text))
    }
    static func error(_ text: String) -> TerminalEntry {
        TerminalEntry(kind: .error(text))
    }
    static func info(_ text: String) -> TerminalEntry {
        TerminalEntry(kind: .info(text))
    }
}

struct TerminalEntryView: View {
    let entry: TerminalEntry
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color

    var body: some View {
        switch entry.kind {
        case .command(let cmd, let dir):
            HStack(spacing: 4) {
                Text(shortPath(dir) + " ❯")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(accent)
                Text(cmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .textSelection(.enabled)
            }
        case .output(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .info(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textMuted)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }
}
