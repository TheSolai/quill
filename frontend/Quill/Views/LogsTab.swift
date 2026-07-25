import SwiftUI
import AppKit

// MARK: - LogsTab
//
// Shows three streams of logs:
//   1. Backend log (from /tmp/quill_backend.log, polled every 2s)
//   2. Action log (in-app actions like save, fix, send, etc.)
//   3. Filter by level (info/warn/error) and free-text search
//
// The action log is a singleton (ActionLog.shared) that any code in the
// app can append to. The backend log is fetched from disk.

struct LogsTab: View {
    let bg: Color
    let bgPrimary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    @State private var backendLines: [String] = []
    @State private var actions: [LogEntry] = []
    @State private var selectedStream: Stream = .actions
    @State private var filterLevel: Level = .all
    @State private var searchText: String = ""
    @State private var isPaused: Bool = false
    @State private var autoScroll: Bool = true
    @State private var lastFetchedBytes: Int = 0
    @State private var lastFetchedMtime: Date = .distantPast

    enum Stream: String, CaseIterable, Identifiable {
        case actions = "Actions"
        case backend = "Backend"
        case both = "Both"
        var id: String { rawValue }
    }

    enum Level: String, CaseIterable, Identifiable {
        case all = "All"
        case info = "Info"
        case warn = "Warn"
        case error = "Error"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Picker("", selection: $selectedStream) {
                    ForEach(Stream.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .controlSize(.small)

                Picker("", selection: $filterLevel) {
                    ForEach(Level.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                .controlSize(.small)

                TextField("search…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(border, lineWidth: 1)
                    )
                    .frame(maxWidth: 200)

                Spacer()

                Button(action: { isPaused.toggle() }) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isPaused ? .green : textMuted)
                }
                .buttonStyle(.plain)
                .help(isPaused ? "Resume" : "Pause")

                Button(action: { autoScroll.toggle() }) {
                    Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 10))
                        .foregroundColor(autoScroll ? accent : textMuted)
                }
                .buttonStyle(.plain)
                .help(autoScroll ? "Auto-scroll: on" : "Auto-scroll: off")

                Button(action: clearLogs) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bg)
            Divider().background(border)

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .background(bgPrimary)
                .onChange(of: filteredEntries.count) { _, _ in
                    if autoScroll && !isPaused {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(bgPrimary)
        .onAppear {
            actions = ActionLog.shared.entries
            Task { await fetchBackendLog() }
            Task { await pollLoop() }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(textMuted)
                .frame(width: 70, alignment: .leading)
            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(entry.level.color)
                .frame(width: 40, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Filtering

    private var filteredEntries: [LogEntry] {
        var combined: [LogEntry] = []
        if selectedStream == .actions || selectedStream == .both {
            combined.append(contentsOf: actions)
        }
        if selectedStream == .backend || selectedStream == .both {
            combined.append(contentsOf: backendLines.map { LogEntry(
                id: UUID(),
                time: timestampForBackend(),
                level: .info,
                message: $0
            ) })
        }
        if filterLevel != .all {
            let wanted = LogEntry.Level(rawValue: filterLevel.rawValue.lowercased()) ?? .info
            combined = combined.filter { $0.level == wanted }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            combined = combined.filter { $0.message.lowercased().contains(q) }
        }
        return combined.suffix(2000)  // cap
    }

    private func timestampForBackend() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Backend log fetch

    private func fetchBackendLog() async {
        let url = URL(fileURLWithPath: "/tmp/quill_backend.log")
        do {
            // Check mtime first — skip the read entirely if file hasn't changed
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let mtime = attrs[.modificationDate] as? Date, mtime == lastFetchedMtime {
                return
            }
            lastFetchedMtime = attrs[.modificationDate] as? Date ?? .distantPast
            let data = try Data(contentsOf: url)
            if data.count == lastFetchedBytes { return }
            lastFetchedBytes = data.count
            if let str = String(data: data, encoding: .utf8) {
                // Keep last 2000 lines
                let lines = str.components(separatedBy: "\n")
                let trimmed = Array(lines.suffix(2000))
                await MainActor.run { self.backendLines = trimmed }
            }
        } catch {
            // File doesn't exist yet — backend may not be running
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !isPaused {
                actions = ActionLog.shared.entries
                await fetchBackendLog()
            }
        }
    }

    private func clearLogs() {
        actions = []
        backendLines = []
    }
}

// MARK: - Log entry

struct LogEntry: Identifiable {
    enum Level: String {
        case info, warn, error
        var color: Color {
            switch self {
            case .info: return .blue
            case .warn: return .orange
            case .error: return .red
            }
        }
    }
    let id: UUID
    let time: String
    let level: Level
    let message: String
}

// MARK: - ActionLog singleton
//
// Append-only log of user actions. Any view can call:
//   ActionLog.shared.log(.info, "Saved chapter-3.md")
//   ActionLog.shared.log(.error, "Fix failed: timeout")
//
// This is a simple, thread-safe append store. The Logs tab polls it.

@MainActor
final class ActionLog: ObservableObject {
    static let shared = ActionLog()
    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 1000
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(
            id: UUID(),
            time: timeFormatter.string(from: Date()),
            level: level,
            message: message
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
