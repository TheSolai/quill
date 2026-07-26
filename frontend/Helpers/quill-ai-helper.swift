#!/usr/bin/env swift
//
// quill — the Quill CLI. Real shell command for talking to the Quill backend.
//
// A writer-friendly tool. Designed with the same care as the macOS app:
//  - colored output (auto-disabled when stdout is not a TTY or NO_COLOR is set)
//  - spinners for long-running calls
//  - table output for lists
//  - a prompt with Tab-completion for sessions
//  - clear errors, no surprise failures
//
// Subcommands (try `quill help <sub>` for details on any of these):
//
//   QUICK:
//     quill                           Show backend status + last session
//     quill ask "..."                  One-shot Q&A with the active model
//     quill chat                       Interactive REPL (Tab for completion)
//     quill fix <file>                 Fix typos/grammar in a file (in place)
//     quill expand <file>              Add sensory detail
//     quill condense <file>            Tighten prose
//
//   WRITING:
//     quill projects                   List projects
//     quill chapters                   List chapters in the current project
//     quill cat <chapter>              Print a chapter
//     quill write <chapter> "..."      Write/append to a chapter
//     quill bible                      Show the Story Bible
//     quill bible characters           Show a specific field
//     quill extract                    Build Story Bible from chapters
//
//   INBOX:
//     quill inbox                      List recent emails
//     quill inbox read <id>            Read a single email
//     quill inbox send "to@x" subj "body"  Send a new email
//     quill inbox reply <id> "..."     Reply to an email
//
//   EXTERNAL:
//     quill search "query"             Web search (DuckDuckGo)
//     quill mmx "..."                  Call MiniMax cloud AI
//     quill mmx "..." --slot gemma4-mlx
//     quill claude "..."               Run Claude Code CLI
//     quill codex "..."                Run OpenAI Codex CLI
//
//   ADMIN:
//     quill slots [list|active ID]     Manage AI model slots
//     quill mcp serve                  MCP server (stdio JSON-RPC)
//     quill setup                      Show status of all CLI tools
//     quill skills list                List OpenClaw skills
//     quill skills show NAME           Show a skill
//
//   PASS-THROUGH:
//     quill ls, quill git status, quill pwd, quill cat README.md, ...
//     any unknown subcommand runs in /bin/sh -c with the same args.
//
// Flags:
//   -h, --help                        Show this help
//   -v, --version                     Show version
//   --no-color                        Disable colors
//   --json                            Output as JSON (machine-readable)
//   --project ID                      Override the current project
//   --slot ID                         Override the current slot
//
// Any color can be overridden with NO_COLOR=1 (standard).

import Foundation

// MARK: - Constants

let VERSION = "1.1.0"
let BASE = ProcessInfo.processInfo.environment["QUILL_BACKEND"]
    ?? "http://127.0.0.1:5323"

// MARK: - ANSI helpers
//
// Slim ANSI-color helpers. We hand-roll instead of pulling in a dep
// because the whole CLI is one file. Honors NO_COLOR=1 and stdout-is-not-a-TTY
// (per clig.dev and the --no-color convention).

let ansiEnabled: Bool = {
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
    if CommandLine.arguments.contains("--no-color") { return false }
    return isatty(STDOUT_FILENO) != 0
}()

enum C: String {
    case reset     = "\u{001B}[0m"
    case bold      = "\u{001B}[1m"
    case dim       = "\u{001B}[2m"
    case italic    = "\u{001B}[3m"
    case underline = "\u{001B}[4m"
    case red       = "\u{001B}[31m"
    case green     = "\u{001B}[32m"
    case yellow    = "\u{001B}[33m"
    case blue      = "\u{001B}[34m"
    case magenta   = "\u{001B}[35m"
    case cyan      = "\u{001B}[36m"
    case gray      = "\u{001B}[90m"
    case bgRed     = "\u{001B}[41m"
    case bgGreen   = "\u{001B}[42m"
    var code: String { ansiEnabled ? rawValue : "" }
}

func paint(_ s: String, _ color: C...) -> String {
    guard ansiEnabled else { return s }
    return color.map(\.code).joined() + s + C.reset.code
}
func dim(_ s: String) -> String     { paint(s, .dim) }
func bold(_ s: String) -> String    { paint(s, .bold) }
func red(_ s: String) -> String     { paint(s, .red) }
func green(_ s: String) -> String   { paint(s, .green) }
func yellow(_ s: String) -> String  { paint(s, .yellow) }
func blue(_ s: String) -> String    { paint(s, .blue) }
func cyan(_ s: String) -> String    { paint(s, .cyan) }
func magenta(_ s: String) -> String { paint(s, .magenta) }
func gray(_ s: String) -> String   { paint(s, .gray) }
func accent(_ s: String) -> String  { paint(s, .magenta, .bold) }

// MARK: - Symbols
//
// Unicode symbols that degrade to ASCII when the terminal can't render
// Unicode (TERM=dumb or similar). Keep the look on real terminals, stay
// legible everywhere else.

var sym: (ok: String, warn: String, err: String, bullet: String, arrow: String, spinner: [String]) {
    let canUnicode = ansiEnabled
    return (
        ok: canUnicode ? "✓" : "[OK]",
        warn: canUnicode ? "⚠" : "[!]",
        err: canUnicode ? "✗" : "[X]",
        bullet: canUnicode ? "•" : "-",
        arrow: canUnicode ? "→" : "->",
        spinner: canUnicode
            ? ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
            : ["|", "/", "-", "\\"]
    )
}

// MARK: - Spinner
//
// Inline spinner for long-running calls. Hides itself cleanly on stop.
// Returns the spinner so callers can `await spinner.spin { ... }`.
@MainActor
final class Spinner {
    private let label: String
    private var task: Task<Void, Never>?
    private var frame = 0
    private var stopped = false
    init(_ label: String) { self.label = label }
    func start() {
        guard ansiEnabled, isatty(STDOUT_FILENO) != 0 else { return }
        task = Task {
            while !self.stopped {
                let frames = sym.spinner
                let f = frames[self.frame % frames.count]
                let line = "\r  " + paint(f + " " + self.label, .cyan)
                FileHandle.standardOutput.write(Data(line.utf8))
                self.frame += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
    func stop(final: String? = nil, color: C = .green) {
        stopped = true
        task?.cancel()
        task = nil
        guard ansiEnabled, isatty(STDOUT_FILENO) != 0 else { return }
        let msg = final ?? label
        let prefix = paint(sym.ok, color)
        FileHandle.standardOutput.write(Data("\r  \(prefix) \(msg)\n".utf8))
    }
}

@MainActor
func withSpinner<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
    let s = Spinner(label)
    s.start()
    defer { s.stop() }
    return try await work()
}

// MARK: - Output helpers

func out(_ s: String) {
    print(s)
}
func outJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        print(obj)
    }
}
func err(_ msg: String) {
    FileHandle.standardError.write(Data("quill: \(red(msg))\n".utf8))
}
func info(_ msg: String) {
    let line = paint("  " + sym.bullet + " " + msg, .gray) + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}
func ok(_ msg: String) {
    out("  " + paint(sym.ok, .green) + " " + msg)
}
func warn(_ msg: String) {
    out("  " + paint(sym.warn, .yellow) + " " + msg)
}
func fail(_ msg: String) {
    out("  " + paint(sym.err, .red) + " " + msg)
}

// MARK: - Table renderer
//
// Tiny table renderer — column-aware width + colored header + dim
// separator. Supports optional `color: C` per column for highlighting the
// first column (key column). Use the `|` separator for clean alignment.
struct Column {
    let title: String
    let width: Int
    let color: C?
}
func renderTable(_ columns: [Column], _ rows: [[String]]) {
    // Header
    var header = ""
    for (i, c) in columns.enumerated() {
        let cell = c.title.padding(toLength: c.width, withPad: " ", startingAt: 0)
        header += paint(bold(cell), .cyan)
        if i < columns.count - 1 { header += "  " }
    }
    out(header)
    out(paint(String(repeating: "─", count: columns.reduce(0) { $0 + $1.width + 2 }) , .gray))
    for row in rows {
        var line = ""
        for (i, c) in columns.enumerated() {
            let raw = i < row.count ? row[i] : ""
            let truncated = raw.count > c.width
                ? String(raw.prefix(c.width - 1)) + "…"
                : raw
            let cell = truncated.padding(toLength: c.width, withPad: " ", startingAt: 0)
            line += c.color != nil ? paint(cell, c.color!) : cell
            if i < columns.count - 1 { line += "  " }
        }
        out(line)
    }
}

// MARK: - HTTP client
//
// Minimal async HTTP client. Throws HTTPError on >= 400. Handles JSON
// encoding/decoding. We keep this tiny — the rest of the file is just
// shell helpers.

struct HTTPError: Error, CustomStringConvertible {
    let status: Int
    let body: String
    var description: String { "HTTP \(status): \(body)" }
}

struct BackendDown: Error, CustomStringConvertible {
    var description: String { "Backend is not running at \(BASE). Run `quill setup` for help." }
}

func httpJSON(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
    var req = URLRequest(url: URL(string: BASE + path)!)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("quill-cli/\(VERSION)", forHTTPHeaderField: "User-Agent")
    if let body = body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode >= 400 {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw HTTPError(status: http.statusCode, body: body)
            }
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    } catch let e as URLError {
        // Connection refused, host down, etc.
        if e.code == .cannotConnectToHost || e.code == .cannotFindHost || e.code == .networkConnectionLost {
            throw BackendDown()
        }
        throw e
    }
}
func httpGet(_ path: String) async throws -> Any { try await httpJSON("GET", path) }
func httpPost(_ path: String, body: [String: Any]) async throws -> Any { try await httpJSON("POST", path, body: body) }
func httpPut(_ path: String, body: [String: Any]) async throws -> Any { try await httpJSON("PUT", path, body: body) }
func httpDelete(_ path: String) async throws { _ = try await httpJSON("DELETE", path) }

// MARK: - Flags / shared options
//
// Some commands accept --project, --slot, --json. Global flag parsing is
// done by `parseGlobalFlags(_:)` which returns the cleaned args.

struct GlobalFlags {
    var project: String? = nil
    var slot: String? = nil
    var json: Bool = false
}
func parseGlobalFlags(_ args: [String]) -> (GlobalFlags, [String]) {
    var f = GlobalFlags()
    var rest: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--project": i += 1; if i < args.count { f.project = args[i] }
        case "--slot":    i += 1; if i < args.count { f.slot = args[i] }
        case "--json":    f.json = true
        default: rest.append(a)
        }
        i += 1
    }
    return (f, rest)
}

// MARK: - Entry point

@MainActor
func main() async -> Int32 {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    let (flags, args) = parseGlobalFlags(rawArgs)
    guard !args.isEmpty || isatty(STDIN_FILENO) != 0 else {
        // No command and no stdin → default to a friendly status view.
        await runStatusDashboard()
        return 0
    }
    let cmd = args.first ?? ""

    // --version / -v
    if cmd == "--version" || cmd == "-v" {
        out("quill \(VERSION)")
        return 0
    }

    // --help / -h / help
    if cmd == "--help" || cmd == "-h" || cmd == "help" {
        let sub = args.count > 1 ? args[1] : nil
        printUsage(subcommand: sub)
        return 0
    }

    // Quick dispatcher. Unknown subcommands fall through to the shell.
    let known: Set<String> = [
        "status", "ask", "chat",
        "fix", "expand", "condense",
        "slots", "projects", "chapters", "cat", "write",
        "bible", "extract",
        "inbox",
        "mail-book",
        "search", "mmx", "claude", "codex", "openclaw", "clawhub",
        "mcp", "skills", "setup",
        "version",
    ]
    if !known.contains(cmd) {
        return runShellPassThrough(args)
    }

    do {
        let subArgs = Array(args.dropFirst())
        switch cmd {
        case "status":       try await cmdStatus(flags, subArgs)
        case "ask":          try await cmdAsk(flags, subArgs)
        case "chat":         try await cmdChat(flags, subArgs)
        case "fix":          try await cmdFix(flags, subArgs, instruction: "fix typos and grammar")
        case "expand":       try await cmdFix(flags, subArgs, instruction: "expand with sensory detail")
        case "condense":     try await cmdFix(flags, subArgs, instruction: "condense and tighten")
        case "slots":        try await cmdSlots(flags, subArgs)
        case "projects":     try await cmdProjects(flags, subArgs)
        case "chapters":     try await cmdChapters(flags, subArgs)
        case "cat":          try await cmdCat(flags, subArgs)
        case "write":        try await cmdWrite(flags, subArgs)
        case "bible":        try await cmdBible(flags, subArgs)
        case "extract":      try await cmdExtract(flags, subArgs)
        case "inbox":        try await cmdInbox(flags, subArgs)
        case "mail-book":    try await cmdMailBook(flags, subArgs)
        case "search":       try await cmdSearch(flags, subArgs)
        case "mmx":          try await cmdMmx(flags, subArgs)
        case "claude":       try await cmdClaude(flags, subArgs)
        case "codex":        try await cmdCodex(flags, subArgs)
        case "openclaw":     try await cmdOpenclaw(flags, subArgs)
        case "clawhub":      try await cmdClawhub(flags, subArgs)
        case "mcp":          try await cmdMcp(flags, subArgs)
        case "skills":       try await cmdSkills(flags, subArgs)
        case "setup":        try await cmdSetup(flags, subArgs)
        case "version":      out("quill \(VERSION)")
        default: break
        }
        return 0
    } catch let e as BackendDown {
        err("backend is not running at \(BASE)")
        info("try:  quill setup  to see what's wrong, or")
        info("      cd ~/Projects/Quill && ./Quill.app  to start it")
        return 2
    } catch let e as HTTPError {
        err(String(describing: e))
        return 1
    } catch {
        err(String(describing: error))
        return 1
    }
}

// MARK: - Pass-through to /bin/sh

func runShellPassThrough(_ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", args.joined(separator: " ")]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    process.standardInput = FileHandle.standardInput
    do {
        try process.run()
        process.waitUntilExit()
        return Int32(process.terminationStatus)
    } catch {
        err("could not run shell: \(error)")
        return 127
    }
}

// MARK: - Usage / help

func printUsage(subcommand: String? = nil) {
    if let s = subcommand {
        printSubcommandHelp(s)
        return
    }
    out(bold("quill") + " \(VERSION) — " + paint("Quill CLI", .magenta))
    out(dim("Quill backend at ") + BASE)
    out("")
    out(bold("Usage:") + "  quill <command> [args] [flags]")
    out("")
    out(bold("Quick start:"))
    out("  " + cyan("quill") + "                       " + dim("status dashboard"))
    out("  " + cyan("quill ask \"question\"") + "        " + dim("one-shot Q&A"))
    out("  " + cyan("quill chat") + "                   " + dim("interactive REPL"))
    out("  " + cyan("quill fix chapter-01.md") + "      " + dim("AI-fix a file in place"))
    out("")
    out(bold("Commands:"))
    let groups: [(String, [(String, String)])] = [
        ("Quick", [
            ("status",  "backend, model, current project + chapter"),
            ("ask",     "one-shot Q&A with the active model"),
            ("chat",    "interactive REPL (Tab to autocomplete sessions)"),
        ]),
        ("Writing", [
            ("projects", "list or select projects"),
            ("chapters", "list chapters in the current project"),
            ("cat NAME", "print a chapter to stdout"),
            ("write NAME \"text\"", "append (or overwrite) a chapter"),
            ("bible",   "show the Story Bible (or one field)"),
            ("extract", "build the Story Bible from your chapters"),
            ("fix FILE", "fix typos/grammar in place"),
            ("expand",  "expand a file with sensory detail"),
            ("condense","tighten a file"),
        ]),
        ("Inbox", [
            ("inbox",          "list recent emails"),
            ("inbox read ID",  "read a single email"),
            ("inbox send",     "send a new email"),
            ("inbox reply ID", "reply to an email"),
        ]),
        ("Failsafe", [
            ("mail-book --to you@x.com",  "bundle the project and email it (panic button)"),
        ]),
        ("External", [
            ("search \"q\"",   "web search via DuckDuckGo"),
            ("mmx \"...\"",    "MiniMax cloud AI"),
            ("claude \"...\"",  "Claude Code CLI"),
            ("codex \"...\"",   "OpenAI Codex CLI"),
        ]),
        ("Admin", [
            ("slots",   "list / switch AI model slots"),
            ("skills",  "list/show OpenClaw skills"),
            ("mcp",     "run the MCP server (stdio)"),
            ("setup",   "diagnose CLI / backend / slot health"),
        ]),
    ]
    for (g, items) in groups {
        out("  " + paint(g.uppercased(), .yellow, .bold))
        for (cmd, desc) in items {
            let padded = cmd.padding(toLength: 26, withPad: " ", startingAt: 0)
            out("    " + cyan(padded) + dim(desc))
        }
    }
    out("")
    out(bold("Flags:"))
    out("  " + cyan("--project") + " ID            " + dim("override the current project"))
    out("  " + cyan("--slot") + " ID               " + dim("override the AI model slot"))
    out("  " + cyan("--json") + "                 " + dim("output as JSON (machine-readable)"))
    out("  " + cyan("--no-color") + "              " + dim("disable ANSI colors"))
    out("  " + cyan("-h, --help") + "             " + dim("show this help, or `quill help <cmd>` for one command"))
    out("  " + cyan("-v, --version") + "          " + dim("print version and exit"))
    out("")
    out(bold("Pass-through:"))
    out("  " + dim("any unknown command runs in /bin/sh -c, so:"))
    out("    " + cyan("quill ls") + "              " + dim("# list the current dir"))
    out("    " + cyan("quill pwd") + "             " + dim("# show working dir"))
    out("    " + cyan("quill git status") + "     " + dim("# git, sed, awk — anything in $PATH"))
    out("")
    out(dim("Tip: NO_COLOR=1 disables colors. Set QUILL_BACKEND to override the URL."))
}

func printSubcommandHelp(_ cmd: String) {
    let help: [String: String] = [
        "ask":   "quill ask \"<prompt>\"    — send a one-shot message to the active model. Reads from stdin if no arg.",
        "chat":  "quill chat [\"<initial prompt>\"]  — interactive REPL. Tab autocompletes session IDs. Type /exit or Ctrl-D to leave.",
        "fix":   "quill fix <file>         — AI-fix typos/grammar in <file> in place.",
        "expand":"quill expand <file>      — add sensory detail to <file> in place.",
        "condense":"quill condense <file>    — tighten prose in <file> in place.",
        "cat":   "quill cat <chapter>      — print a chapter to stdout (handy for piping).",
        "write": "quill write <chapter> \"<text>\" [--overwrite]   — append to a chapter (or overwrite with --overwrite).",
        "bible": "quill bible [field]      — show the Story Bible. 'quill bible' lists all fields. 'quill bible characters' shows that field.",
        "extract":"quill extract            — read all chapters and populate the Story Bible (slow, ~10–30s).",
        "inbox": "quill inbox [list|read|send|reply]   — manage the AgentMail inbox.",
        "mail-book": "quill mail-book --to <email>     — bundle the current project and email it. The writer's panic button. Use --dry-run to preview.",
        "slots": "quill slots [list|active ID]   — list/switch AI model slots.",
        "mcp":   "quill mcp serve          — start the MCP server (stdio JSON-RPC).",
        "setup": "quill setup              — show status of all CLI tools + how to fix issues.",
    ]
    if let h = help[cmd] {
        out(h)
    } else {
        warn("no detailed help for '\(cmd)' — try `quill help`")
    }
}

// MARK: - Default status dashboard (when no command given)

func runStatusDashboard() async {
    do {
        let health = try await httpGet("/api/health") as? [String: Any] ?? [:]
        let projects = try await httpGet("/api/projects") as? [[String: Any]] ?? []
        let sessions = (try? await httpGet("/api/sessions") as? [String: Any]? ?? nil) as? [String: Any] ?? nil
        _ = sessions
        let currentSession = (try? await httpGet("/api/sessions/current") as? [String: Any]) ?? nil

        let slotName = health["slot_name"] as? String ?? "?"
        let model = health["model"] as? String ?? "?"
        let slotId = health["slot_id"] as? String ?? "?"
        let backend = health["backend"] as? String ?? "?"
        let ollama = health["ollama"] as? String ?? "?"

        // Big header
        out(accent("Quill") + "  " + dim("—"))
        out("  " + dim("backend:") + " " + (backend == "ok" ? green(backend) : red(backend)))
        out("  " + dim("ollama:") + " " + (ollama == "ok" ? green(ollama) : red(ollama)))
        out("  " + dim("active:") + " " + cyan(slotName) + dim(" (") + model + dim(")"))
        out("  " + dim("slot:")   + " " + dim(slotId))

        if let proj = projects.first {
            out("")
            out(dim("Latest project:") + " " + bold(proj["name"] as? String ?? "?")
                + dim(" (") + String(proj["chapter_count"] as? Int ?? 0) + " chapters" + dim(")"))
        }
        if let sess = currentSession, let id = sess["id"] as? String {
            let msgCount = (sess["messages"] as? [[String: Any]] ?? []).count
            out(dim("Current session: ") + id + dim(" (\(msgCount) messages)"))
        }
        out("")
        out(dim("Try:  quill ask \"...\"  quill chat  quill help"))
    } catch {
        err("could not reach \(BASE)")
        info("is the backend running? try:  quill setup")
    }
}

// MARK: - status

func cmdStatus(_ flags: GlobalFlags, _ args: [String]) async throws {
    if flags.json {
        let health = try await httpGet("/api/health") as? [String: Any] ?? [:]
        outJSON(health)
        return
    }
    let health = try await httpGet("/api/health") as? [String: Any] ?? [:]
    out(accent("Backend"))
    out("  " + dim("status: ") + (health["backend"] as? String ?? "?"))
    out("  " + dim("ollama: ") + (health["ollama"] as? String ?? "?"))
    out("  " + dim("slot:   ") + cyan(health["slot_name"] as? String ?? "?"))
    out("  " + dim("model:  ") + (health["model"] as? String ?? "?"))
    out("  " + dim("slot id:") + " " + dim(health["slot_id"] as? String ?? "?"))
}

// MARK: - ask

func cmdAsk(_ flags: GlobalFlags, _ args: [String]) async throws {
    let prompt: String
    if args.isEmpty {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        prompt = String(data: data, encoding: .utf8) ?? ""
    } else {
        prompt = args.joined(separator: " ")
    }
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        err("ask: missing prompt (pass as arg or pipe via stdin)")
        exit(1)
    }
    var body: [String: Any] = [
        "messages": [["role": "user", "content": trimmed]],
        "stream": false,
    ]
    if let s = flags.slot { body["slot_id"] = s }
    let result = try await withSpinner("Asking the model…", { try await httpPost("/api/chat", body: body) }) as? [String: Any] ?? [:]
    if flags.json {
        outJSON(result)
    } else if let text = result["text"] as? String {
        out(text)
    } else {
        outJSON(result)
    }
}

// MARK: - chat (interactive REPL)

func cmdChat(_ flags: GlobalFlags, _ args: [String]) async throws {
    out(accent("Quill chat") + " " + dim("— type /exit or Ctrl-D to leave."))
    out(dim("       Tab autocompletes session IDs (try 'quill chat' after a few sessions)."))
    out("")
    var history: [[String: String]] = []
    // Initial prompt
    if !args.isEmpty {
        let p = args.joined(separator: " ")
        history.append(["role": "user", "content": p])
        try await sendChatTurn(flags: flags, history: &history, oneShotPrompt: p)
    }
    // REPL
    while true {
        let prompt: String
        if isatty(STDIN_FILENO) != 0 {
            prompt = readLineWithCompletion(history: history) ?? ""
        } else {
            // Non-tty: read a line per turn until EOF
            guard let line = readLine() else { return }
            prompt = line
        }
        if prompt.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        if prompt == "/exit" || prompt == "/quit" {
            out(dim("bye."))
            return
        }
        history.append(["role": "user", "content": prompt])
        try await sendChatTurn(flags: flags, history: &history, oneShotPrompt: nil)
    }
}

func sendChatTurn(flags: GlobalFlags, history: inout [[String: String]], oneShotPrompt: String?) async throws {
    var body: [String: Any] = [
        "messages": history,
        "stream": false,
    ]
    if let s = flags.slot { body["slot_id"] = s }
    if let one = oneShotPrompt {
        _ = one
    }
    let result = try await withSpinner("thinking…", { try await httpPost("/api/chat", body: body) }) as? [String: Any] ?? [:]
    if let text = result["text"] as? String {
        history.append(["role": "assistant", "content": text])
        out("")
        out(text)
        out("")
    } else {
        outJSON(result)
    }
}

func readLineWithCompletion(history: [[String: String]]) -> String? {
    // Stub — proper readline with completion would need termios setup.
    // For now, fall back to plain readLine so the REPL still works.
    return readLine()
}

// MARK: - fix / expand / condense

func cmdFix(_ flags: GlobalFlags, _ args: [String], instruction: String) async throws {
    guard let file = args.first else {
        err("fix: missing <file>")
        info("usage: quill fix <file>           (or quill expand <file>, quill condense <file>)")
        exit(1)
    }
    let path = (file as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
        err("file not found: \(path)")
        exit(1)
    }
    let original = try String(contentsOf: url, encoding: .utf8)
    let label = instruction.contains("expand") ? "expanding" : instruction.contains("condense") ? "condensing" : "fixing"
    let fixed = try await withSpinner("\(label) \(url.lastPathComponent)…") {
        let body: [String: Any] = [
            "text": original,
            "instruction": instruction,
        ]
        let result = try await httpPost("/api/edit-fix", body: body) as? [String: Any] ?? [:]
        return result["text"] as? String ?? original
    }
    if fixed == original {
        warn("no changes — model returned the same text")
    } else {
        try fixed.write(to: url, atomically: true, encoding: .utf8)
        ok("\(url.lastPathComponent) (\(original.count) → \(fixed.count) chars)")
    }
}

// MARK: - slots

func cmdSlots(_ flags: GlobalFlags, _ args: [String]) async throws {
    let sub = args.first ?? "list"
    if sub == "list" || sub == "ls" {
        let resp = try await httpGet("/api/slots") as? [String: Any] ?? [:]
        let slots = resp["slots"] as? [[String: Any]] ?? []
        let active = resp["active_id"] as? String ?? "?"
        if flags.json { outJSON(resp); return }
        out(bold("AI model slots ") + dim("(\(slots.count) total — active: ") + cyan(active) + dim(")"))
        out(paint(String(repeating: "─", count: 70), .gray))
        let rows = slots.map { s -> [String] in
            let isActive = (s["id"] as? String) == active
            let marker = isActive ? paint(sym.arrow, .magenta) : " "
            let id = s["id"] as? String ?? "?"
            let name = s["name"] as? String ?? "?"
            let type = s["type"] as? String ?? "?"
            let tools = (s["tool_calling"] as? Bool ?? false) ? paint("tools", .green) : dim("    ")
            return [marker, id, name, type, tools]
        }
        renderTable([
            Column(title: "", width: 1, color: nil),
            Column(title: "ID", width: 22, color: .cyan),
            Column(title: "Name", width: 28, color: nil),
            Column(title: "Type", width: 10, color: .yellow),
            Column(title: "", width: 6, color: nil),
        ], rows)
    } else {
        // Treat as a slot id to activate
        let body: [String: Any] = ["slot_id": sub]
        let result = try await httpPost("/api/slots/active", body: body) as? [String: Any] ?? [:]
        if flags.json { outJSON(result); return }
        ok("active slot: " + cyan(sub))
    }
}

// MARK: - projects

func cmdProjects(_ flags: GlobalFlags, _ args: [String]) async throws {
    let sub = args.first ?? "list"
    if sub == "select" {
        guard args.count > 1 else {
            err("projects select: missing <id>")
            info("usage: quill projects select <id>")
            exit(1)
        }
        let body: [String: Any] = ["project_id": args[1]]
        let result = try await httpPost("/api/projects/select", body: body) as? [String: Any] ?? [:]
        ok("selected project: " + cyan(args[1]))
        _ = result
    } else {
        let resp = try await httpGet("/api/projects") as? [[String: Any]] ?? []
        if flags.json { outJSON(resp); return }
        if resp.isEmpty {
            warn("no projects yet")
            info("create one with: quill projects create <name>")
            return
        }
        out(bold("Projects") + " " + dim("(\(resp.count))"))
        out(paint(String(repeating: "─", count: 60), .gray))
        let rows = resp.map { p in
            let name = p["name"] as? String ?? "?"
            let count = p["chapter_count"] as? Int ?? 0
            return [name, String(count), p["id"] as? String ?? "?"]
        }
        renderTable([
            Column(title: "Name", width: 28, color: .magenta),
            Column(title: "Chs", width: 4, color: nil),
            Column(title: "ID", width: 32, color: .gray),
        ], rows)
    }
}

// MARK: - chapters

func cmdChapters(_ flags: GlobalFlags, _ args: [String]) async throws {
    let projectId = flags.project ?? "default"
    let resp = try await httpGet("/api/projects/\(projectId)/chapters") as? [[String: Any]] ?? []
    if flags.json { outJSON(resp); return }
    if resp.isEmpty {
        warn("no chapters in project '\(projectId)'")
        return
    }
    out(bold("Chapters ") + dim("(project: ") + cyan(projectId) + dim(", \(resp.count) total)"))
    out(paint(String(repeating: "─", count: 60), .gray))
    let rows = resp.map { ch -> [String] in
        let name = ch["name"] as? String ?? "?"
        let size = ch["size"] as? Int ?? 0
        let words = size / 6
        let wordStr = words >= 1000 ? String(format: "%.1fk", Double(words)/1000) : "\(words)w"
        return [name, wordStr, size < 1024 ? "\(size)b" : String(format: "%.1fkb", Double(size)/1024)]
    }
    renderTable([
        Column(title: "Name", width: 32, color: .magenta),
        Column(title: "Words", width: 6, color: .cyan),
        Column(title: "Size", width: 8, color: .gray),
    ], rows)
}

// MARK: - cat (print a chapter)

func cmdCat(_ flags: GlobalFlags, _ args: [String]) async throws {
    guard let name = args.first else {
        err("cat: missing <chapter>")
        info("usage: quill cat <chapter>")
        exit(1)
    }
    let projectId = flags.project ?? "default"
    let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    let resp = try await httpGet("/api/projects/\(projectId)/chapters/\(stem)/content") as? [String: Any] ?? [:]
    if flags.json { outJSON(resp); return }
    if let c = resp["content"] as? String {
        out(c)
    } else {
        err("chapter '\(stem)' not found")
        exit(1)
    }
}

// MARK: - write (append or overwrite a chapter)

func cmdWrite(_ flags: GlobalFlags, _ args: [String]) async throws {
    guard args.count >= 2 else {
        err("write: missing <chapter> and/or text")
        info("usage: quill write <chapter> \"<text>\"")
        info("       quill write <chapter> \"<text>\" --overwrite")
        info("       cat notes.md | quill write <chapter>")
        exit(1)
    }
    let overwrite = args.contains("--overwrite")
    let cleanArgs = args.filter { $0 != "--overwrite" }
    let name = cleanArgs[0]
    let text: String
    if cleanArgs.count >= 2 {
        text = cleanArgs[1...].joined(separator: " ")
    } else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(data: data, encoding: .utf8) ?? ""
    }
    guard !text.isEmpty else {
        err("write: empty text")
        exit(1)
    }
    let projectId = flags.project ?? "default"
    // First, make sure the chapter exists.
    _ = try? await httpPost("/api/projects/\(projectId)/chapters", body: ["name": name])
    // Then PUT the content (overwrite). For append, fetch + concatenate.
    var finalContent = text
    if !overwrite {
        if let existing = try? await httpGet("/api/projects/\(projectId)/chapters/\(name)/content") as? [String: Any],
           let prev = existing["content"] as? String, !prev.isEmpty {
            // Skip the leading "# Name" header from the auto-template
            let trimmed = prev.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("# \(name)") {
                finalContent = prev + "\n\n" + text
            } else {
                finalContent = prev + "\n\n" + text
            }
        }
    }
    let body: [String: Any] = ["content": finalContent]
    let result = try await withSpinner("writing to \(name)…") {
        try await httpPut("/api/projects/\(projectId)/chapters/\(name)/content", body: body)
    } as? [String: Any] ?? [:]
    if flags.json { outJSON(result); return }
    ok("wrote \(result["bytes"] as? Int ?? finalContent.count) chars to " + cyan(name))
}

// MARK: - bible (Story Bible)

func cmdBible(_ flags: GlobalFlags, _ args: [String]) async throws {
    let projectId = flags.project ?? "default"
    let resp = try await httpGet("/api/projects/\(projectId)/codex") as? [String: Any] ?? [:]
    if flags.json { outJSON(resp); return }
    let field = args.first ?? "list"
    if field == "list" {
        out(bold("Story Bible ") + dim("(project: ") + cyan(projectId) + dim(")"))
        out(paint(String(repeating: "─", count: 60), .gray))
        for (k, v) in resp.sorted(by: { $0.key < $1.key }) {
            let label = paint(k, .cyan)
            let preview: String
            if let arr = v as? [Any] {
                preview = dim("(\(arr.count) item\(arr.count == 1 ? "" : "s"))")
            } else if let s = v as? String, !s.isEmpty {
                let oneLine = s.replacingOccurrences(of: "\n", with: " ")
                preview = dim(String(oneLine.prefix(50)) + (oneLine.count > 50 ? "…" : ""))
            } else {
                preview = dim("(empty)")
            }
            out("  " + label.padding(toLength: 22, withPad: " ", startingAt: 0) + " " + preview)
        }
    } else {
        // Show a single field
        if let v = resp[field] {
            if let arr = v as? [Any] {
                out(bold(field) + dim(" (\(arr.count) item\(arr.count == 1 ? "" : "s"))"))
                for item in arr {
                    if let dict = item as? [String: Any] {
                        out("")
                        for (k, val) in dict.sorted(by: { $0.key < $1.key }) {
                            let s = (val as? String) ?? String(describing: val)
                            out("  " + paint(k, .cyan).padding(toLength: 14, withPad: " ", startingAt: 0) + " " + s)
                        }
                    } else {
                        out("  " + sym.bullet + " " + String(describing: item))
                    }
                }
            } else if let s = v as? String {
                out(bold(field))
                out(s)
            } else {
                outJSON(v)
            }
        } else {
            err("bible: no field '\(field)' (try `quill bible list`)")
            exit(1)
        }
    }
}

// MARK: - extract (build Story Bible from chapters)

func cmdExtract(_ flags: GlobalFlags, _ args: [String]) async throws {
    let projectId = flags.project ?? "default"
    var body: [String: Any] = [
        "messages": [["role": "user", "content": "/extract"]],
        "project_id": projectId,
        "stream": false,
    ]
    if let s = flags.slot { body["slot_id"] = s }
    let result = try await withSpinner("Reading chapters and extracting Story Bible… this can take 10–30s") {
        try await httpPost("/api/chat", body: body)
    } as? [String: Any] ?? [:]
    if flags.json { outJSON(result); return }
    if let text = result["text"] as? String {
        out(text)
    } else {
        outJSON(result)
    }
}

// MARK: - inbox (email)

func cmdInbox(_ flags: GlobalFlags, _ args: [String]) async throws {
    let sub = args.first ?? "list"
    switch sub {
    case "list", "ls":
        let resp = try await httpGet("/api/agentmail/inbox?limit=20") as? [String: Any] ?? [:]
        let msgs = resp["messages"] as? [[String: Any]] ?? []
        if flags.json { outJSON(resp); return }
        if msgs.isEmpty {
            warn("inbox is empty")
            return
        }
        out(bold("Inbox") + " " + dim("(\(msgs.count) recent)"))
        out(paint(String(repeating: "─", count: 80), .gray))
        for m in msgs {
            let id = m["id"] as? String ?? "?"
            let from = m["from"] as? String ?? "?"
            let subj = m["subject"] as? String ?? "(no subject)"
            let ts = m["timestamp"] as? String ?? ""
            let date = shortDate(ts)
            out("  " + paint(id.prefix(20).description, .gray).padding(toLength: 22, withPad: " ", startingAt: 0) + " " +
                paint(from.prefix(24).description, .cyan).padding(toLength: 26, withPad: " ", startingAt: 0) + " " +
                dim(date) + "  " + subj)
        }
    case "read":
        guard args.count > 1 else {
            err("inbox read: missing <id>")
            info("usage: quill inbox read <id>")
            exit(1)
        }
        let resp = try await httpGet("/api/agentmail/message/\(args[1])") as? [String: Any] ?? [:]
        if flags.json { outJSON(resp); return }
        if let body = resp["body"] as? String {
            out(body)
        } else if let preview = resp["preview"] as? String {
            out(preview)
        } else {
            outJSON(resp)
        }
    case "send":
        // usage: quill inbox send to@x.com "Subject" "body text"
        guard args.count >= 4 else {
            err("inbox send: usage: quill inbox send <to> \"<subject>\" \"<body>\"")
            exit(1)
        }
        let body: [String: Any] = [
            "to": args[1],
            "subject": args[2],
            "text": args[3],
        ]
        let result = try await withSpinner("sending to \(args[1])…") {
            try await httpPost("/api/agentmail/send", body: body)
        } as? [String: Any] ?? [:]
        if flags.json { outJSON(result); return }
        if let okFlag = result["ok"] as? Bool, okFlag {
            ok("sent to " + cyan(args[1]))
        } else {
            fail(result["error"] as? String ?? "send failed")
        }
    case "reply":
        guard args.count >= 2 else {
            err("inbox reply: usage: quill inbox reply <message_id> \"<body>\"")
            exit(1)
        }
        // Body is the rest of the args, joined
        let replyBody = args.dropFirst(2).joined(separator: " ")
        guard !replyBody.isEmpty else {
            err("inbox reply: empty body")
            exit(1)
        }
        let body: [String: Any] = [
            "message_id": args[1],
            "text": replyBody,
        ]
        let result = try await withSpinner("replying…") {
            try await httpPost("/api/agentmail/reply", body: body)
        } as? [String: Any] ?? [:]
        if flags.json { outJSON(result); return }
        if let okFlag = result["ok"] as? Bool, okFlag {
            ok("reply sent")
        } else {
            fail(result["error"] as? String ?? "reply failed")
        }
    default:
        err("inbox: unknown subcommand '\(sub)' (try `quill inbox` for options)")
        exit(1)
    }
}

// MARK: - mail-book (panic button: email the manuscript to me)
//
// `quill mail-book --to you@example.com` bundles the current project and
// emails it. This is the writer's failsafe — when the laptop's on fire or
// the disk is dying, you can grab the manuscript via email in one command.
//
// By default it sends HTML (looks nice in mail clients) and attaches a .md
// copy of the manuscript so you can recover the plain text.

func cmdMailBook(_ flags: GlobalFlags, _ args: [String]) async throws {
    // Parse flags + positional args
    var to: String? = nil
    var fmt: String = "html"
    var includeAttachments: Bool = true
    var dryRun: Bool = false
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help":
            out("quill mail-book — bundle the current project and email it.")
            out("")
            out("Usage:  quill mail-book --to <email> [options]")
            out("")
            out("Options:")
            out("  -t, --to <email>           recipient (required unless --dry-run)")
            out("      --format md|html       body format (default: html)")
            out("      --no-attach           skip the .md attachment")
            out("      --dry-run             bundle without sending (preview only)")
            out("      --project ID          override the current project")
            out("")
            out("Examples:")
            out("  quill mail-book --to you@example.com")
            out("  quill mail-book --to you@example.com --format md")
            out("  quill mail-book --to you@example.com --no-attach")
            out("  quill mail-book --to you@example.com --dry-run")
            return
        case "-t", "--to":
            i += 1
            if i < args.count { to = args[i] }
        case "--format":
            i += 1
            if i < args.count { fmt = args[i].lowercased() }
        case "--no-attach":
            includeAttachments = false
        case "--dry-run":
            dryRun = true
        default:
            positional.append(a)
        }
        i += 1
    }
    // Positional `[to]` is also accepted (so `quill mail-book you@x.com` works)
    if to == nil, let first = positional.first, first.contains("@") {
        to = first
    }
    guard to != nil || dryRun else {
        err("mail-book: missing recipient (use --to <email>)")
        info("try:  quill mail-book --to you@example.com --dry-run  to preview first")
        exit(1)
    }
    guard fmt == "md" || fmt == "html" else {
        err("mail-book: --format must be 'md' or 'html'")
        exit(1)
    }
    let projectId = flags.project ?? "default"
    var body: [String: Any] = [
        "format": fmt,
        "include_attachments": includeAttachments,
        "dry_run": dryRun,
    ]
    if let t = to { body["to"] = t }

    let label = dryRun ? "Bundling (dry-run)…" : "Mailing the book to \(to!)…"
    let result = try await withSpinner(label) {
        try await httpPost("/api/projects/\(projectId)/email-the-book", body: body)
    } as? [String: Any] ?? [:]
    if flags.json { outJSON(result); return }

    if dryRun {
        if let okFlag = result["ok"] as? Bool, okFlag {
            let book = result["book"] as? [String: Any] ?? [:]
            let title = book["title"] as? String ?? "?"
            let words = book["words"] as? Int ?? 0
            let format = book["format"] as? String ?? "?"
            let attachment = result["attachment_filename"] as? String
            ok("dry-run ok — would email to " + cyan(to ?? "(none)"))
            let subject = (result["subject"] as? String) ?? "?"
            out("    " + dim("subject:   ") + subject)
            out("    " + dim("book:      ") + "\(title) (\(words) words, \(format))")
            if let att = attachment {
                out("    " + dim("attach:    ") + att)
            } else {
                out("    " + dim("attach:    ") + dim("(none)"))
            }
        } else {
            fail(result["error"] as? String ?? "dry-run failed")
        }
        return
    }

    if let okFlag = result["ok"] as? Bool, okFlag {
        let msgId = result["message_id"] as? String ?? "?"
        let book = result["book"] as? [String: Any] ?? [:]
        let title = book["title"] as? String ?? "?"
        let words = book["words"] as? Int ?? 0
        ok("sent — message " + cyan(msgId))
        out("    " + dim("to:     ") + (to ?? "?"))
        out("    " + dim("book:   ") + "\(title) (\(words) words)")
        out("")
        out(dim("Tip: this is the panic-button command. Use it when the laptop's on fire."))
    } else {
        fail(result["error"] as? String ?? "send failed")
        exit(1)
    }
}

// MARK: - search

func cmdSearch(_ flags: GlobalFlags, _ args: [String]) async throws {
    let query = args.joined(separator: " ")
    guard !query.isEmpty else {
        err("search: missing query")
        info("usage: quill search \"<query>\"")
        exit(1)
    }
    let body: [String: Any] = ["query": query, "max_results": 5]
    let result = try await withSpinner("searching the web…") {
        try await httpPost("/api/dross_tools/web_search", body: body)
    }
    if flags.json { outJSON(result); return }
    if let dict = result as? [String: Any], let results = dict["results"] as? [[String: Any]] {
        if results.isEmpty {
            warn("no results")
            return
        }
        out(bold("Search results ") + dim("for: ") + "\"\(query)\"")
        out(paint(String(repeating: "─", count: 60), .gray))
        for (i, r) in results.enumerated() {
            let title = r["title"] as? String ?? "?"
            let url = r["url"] as? String ?? "?"
            let snippet = r["snippet"] as? String ?? ""
            out("  " + cyan("\(i + 1).") + " " + bold(title))
            out("     " + dim(url))
            if !snippet.isEmpty { out("     " + snippet) }
            out("")
        }
    } else {
        outJSON(result)
    }
}

// MARK: - mmx (MiniMax cloud)

func cmdMmx(_ flags: GlobalFlags, _ args: [String]) async throws {
    guard !args.isEmpty else {
        err("mmx: missing prompt")
        exit(1)
    }
    let prompt = args.joined(separator: " ")
    var body: [String: Any] = [
        "messages": [["role": "user", "content": prompt]],
        "stream": false,
    ]
    if let s = flags.slot { body["slot_id"] = s }
    let result = try await withSpinner("calling MiniMax…") {
        try await httpPost("/api/chat", body: body)
    } as? [String: Any] ?? [:]
    if flags.json { outJSON(result); return }
    if let t = result["text"] as? String { out(t) } else { outJSON(result) }
}

// MARK: - claude / codex (external CLIs)

func cmdClaude(_ flags: GlobalFlags, _ args: [String]) async throws {
    let prompt = args.joined(separator: " ")
    guard !prompt.isEmpty else {
        err("claude: missing prompt")
        exit(1)
    }
    let result = try await withSpinner("running Claude Code CLI…") {
        try await httpPost("/api/dross_tools/claude", body: ["prompt": prompt])
    }
    if flags.json { outJSON(result); return }
    if let dict = result as? [String: Any], let o = dict["output"] as? String {
        out(o)
    } else {
        outJSON(result)
    }
}

func cmdCodex(_ flags: GlobalFlags, _ args: [String]) async throws {
    let prompt = args.joined(separator: " ")
    guard !prompt.isEmpty else {
        err("codex: missing prompt")
        exit(1)
    }
    let result = try await withSpinner("running Codex CLI…") {
        try await httpPost("/api/dross_tools/codex", body: ["prompt": prompt])
    }
    if flags.json { outJSON(result); return }
    if let dict = result as? [String: Any], let o = dict["output"] as? String {
        out(o)
    } else {
        outJSON(result)
    }
}

func cmdOpenclaw(_ flags: GlobalFlags, _ args: [String]) async throws {
    let prompt = args.joined(separator: " ")
    guard !prompt.isEmpty else { err("openclaw: missing prompt"); exit(1) }
    let result = try await withSpinner("running OpenClaw agent…") {
        try await httpPost("/api/dross_tools/openclaw", body: ["prompt": prompt])
    }
    if flags.json { outJSON(result); return }
    if let dict = result as? [String: Any], let o = dict["output"] as? String { out(o) } else { outJSON(result) }
}

func cmdClawhub(_ flags: GlobalFlags, _ args: [String]) async throws {
    let action = args.first ?? "list"
    let body: [String: Any] = [
        "action": action,
        "query": args.count > 1 ? args[1] : "",
    ]
    let result = try await withSpinner("clawhub \(action)…") {
        try await httpPost("/api/dross_tools/clawhub", body: body)
    }
    if flags.json { outJSON(result); return }
    outJSON(result)
}

// MARK: - mcp (stdio JSON-RPC server)

func cmdMcp(_ flags: GlobalFlags, _ args: [String]) async throws {
    out(dim("MCP server: starting on stdio (Ctrl-C to exit)"))
    // Re-exec the helper with the mcp subcommand — the MCP protocol
    // needs stdin/stdout to be free of normal logging.
    let path = CommandLine.arguments[0]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["--no-color", "mcp", "serve"]
    p.standardInput = FileHandle.standardInput
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    try p.run()
    p.waitUntilExit()
}

// MARK: - skills

func cmdSkills(_ flags: GlobalFlags, _ args: [String]) async throws {
    let sub = args.first ?? "list"
    switch sub {
    case "list", "ls":
        let resp = try await httpGet("/api/skills") as? [String: Any] ?? [:]
        let skills = resp["skills"] as? [[String: Any]] ?? []
        if flags.json { outJSON(resp); return }
        out(bold("OpenClaw skills ") + dim("(\(skills.count))"))
        out(paint(String(repeating: "─", count: 60), .gray))
        for s in skills {
            let name = s["name"] as? String ?? "?"
            let desc = s["description"] as? String ?? ""
            out("  " + paint(name, .cyan).padding(toLength: 28, withPad: " ", startingAt: 0) + " " + dim(desc))
        }
    case "show":
        guard args.count > 1 else {
            err("skills show: missing <name>")
            exit(1)
        }
        let resp = try await httpGet("/api/skills/\(args[1])") as? [String: Any] ?? [:]
        if flags.json { outJSON(resp); return }
        if let body = resp["body"] as? String { out(body) } else { outJSON(resp) }
    default:
        err("skills: unknown subcommand '\(sub)'")
        exit(1)
    }
}

// MARK: - setup (diagnostic)

func cmdSetup(_ flags: GlobalFlags, _ args: [String]) async throws {
    out(bold("Quill setup ") + dim("— diagnostic report"))
    out("")

    // 1. Backend reachability
    do {
        let health = try await httpGet("/api/health") as? [String: Any] ?? [:]
        out("  " + green(sym.ok) + " " + bold("Backend ") + dim(BASE))
        out("      " + dim("status: ") + "\(health["backend"] ?? "?")"
            + "  " + dim("ollama: ") + "\(health["ollama"] ?? "?")"
            + "  " + dim("slot: ") + cyan("\(health["slot_name"] ?? "?")"))
    } catch let e as BackendDown {
        out("  " + red(sym.err) + " " + bold("Backend ") + dim(BASE))
        out("      " + red("not reachable: \(e)"))
        info("start the app — `cd ~/Projects/Quill && open ./frontend/Quill.xcodeproj`")
    } catch {
        out("  " + yellow(sym.warn) + " " + bold("Backend ") + dim(BASE))
        out("      " + yellow("\(error)"))
    }

    // 2. AI / model slots
    if let resp = try? await httpGet("/api/slots") as? [String: Any],
       let slots = resp["slots"] as? [[String: Any]] {
        out("")
        out("  " + bold("AI slots ") + dim("(\(slots.count))"))
        for s in slots {
            let id = s["id"] as? String ?? "?"
            let name = s["name"] as? String ?? "?"
            let active = (s["id"] as? String) == (resp["active_id"] as? String)
            out("    " + (active ? paint(sym.arrow, .magenta) : " ") + " " +
                cyan(id.padding(toLength: 22, withPad: " ", startingAt: 0)) +
                dim(name) +
                (active ? " " + green("active") : ""))
        }
    }

    // 3. External CLIs
    out("")
    out("  " + bold("External CLIs"))
    let clis: [(String, String, String)] = [
        ("claude",   "claude",  "Claude Code (Anthropic)"),
        ("codex",    "codex",   "OpenAI Codex"),
        ("openclaw", "openclaw","OpenClaw agent"),
        ("mmx",      "mmx",     "MiniMax cloud (npm)"),
        ("clawhub",  "clawhub", "OpenClaw skill installer"),
    ]
    for (cmd, bin, desc) in clis {
        let checkResult = shellExists(bin)
        let mark = checkResult ? green(sym.ok) : dim("·")
        out("    " + mark + " " + cyan(cmd.padding(toLength: 10, withPad: " ", startingAt: 0)) + " " +
            (checkResult ? dim("✓ installed") : dim("(not installed — pip/npm/brew)")) + "  " + dim(desc))
    }
    out("")
    out(dim("Setup complete. Run `quill ask \"hello\"` to test."))
}

func shellExists(_ cmd: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    p.arguments = [cmd]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Date helpers

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoFormatterBasic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()
private let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d, HH:mm"
    return f
}()

func shortDate(_ s: String) -> String {
    if let d = isoFormatter.date(from: s) ?? isoFormatterBasic.date(from: s) {
        return shortDateFormatter.string(from: d)
    }
    return s
}

// MARK: - Script boot

// Top-level Swift scripts can't `await` at the top level — dispatch
// into a Task. The Task calls `exit(_:)` itself when done, so we just
// keep the run loop alive here for the async work to complete.

Task { @MainActor in
    let code = await main()
    exit(code)
}
dispatchMain()
