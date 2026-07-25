#!/usr/bin/env swift
//
// quill — the Quill CLI. Real shell command for talking to the Quill backend.
//
// Subcommands:
//   quill status                  Show active model, project, etc.
//   quill ask "question"          One-shot Q&A with the active model
//   quill chat [prompt]           Interactive chat (or one-shot if prompt given)
//   quill fix <file>              Fix typos/grammar in a file in place
//   quill expand <file>           Add sensory detail to a file in place
//   quill condense <file>         Tighten a file in place
//   quill slots [list|active ID]  List slots, show active, or activate
//   quill projects [list|select]  List projects or select one
//   quill chapters [ls|cat]       List chapters or print one
//   quill scenes [ls|cat]         List scenes or print one
//   quill search "query"          Web search via DuckDuckGo
//   quill email [list|send]       List inbox or send an email
//   quill mcp serve               Start MCP server (stdio)
//   quill --help                  This help
//
// Any unknown subcommand is passed to /bin/sh -c, so you can just run
// `quill ls`, `quill git status`, `quill pwd`, etc. from anywhere.

import Foundation

let BASE = "http://127.0.0.1:5323"

// MARK: - Entry point
//
// Top-level Swift scripts can't use `await` directly — we have to dispatch
// into a Task and use a RunLoop to keep the script alive. This is a known
// quirk of the script runner. (For an Xcode-compiled binary with @main,
// you'd just use `await` directly.)

@MainActor
func main() async -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty || isatty(STDIN_FILENO) != 0 else {
        print("quill: no command given. Try `quill --help`.")
        return 1
    }

    let cmd = args.first ?? ""

    if cmd.isEmpty {
        await runREPL()
        return 0
    }

    if cmd == "--help" || cmd == "-h" {
        printUsage()
        return 0
    }

    if cmd == "--version" || cmd == "-v" {
        print("quill 1.0.0")
        return 0
    }

    // Pass-through: unknown subcommand → shell
    let known = ["status", "ask", "chat", "fix", "expand", "condense", "slots", "projects", "chapters", "scenes", "search", "email", "mcp", "skills", "help"]
    if !known.contains(cmd) {
        return runShellPassThrough(args)
    }

    let subArgs = Array(args.dropFirst())
    do {
        switch cmd {
        case "status":    try await cmdStatus()
        case "ask":       try await cmdAsk(subArgs)
        case "chat":      try await cmdChat(subArgs)
        case "fix":       try await cmdFix(subArgs, instruction: "fix typos and grammar")
        case "expand":    try await cmdFix(subArgs, instruction: "expand with sensory detail")
        case "condense":  try await cmdFix(subArgs, instruction: "condense and tighten")
        case "slots":     try await cmdSlots(subArgs)
        case "projects":  try await cmdProjects(subArgs)
        case "chapters":  try await cmdChapters(subArgs)
        case "scenes":    try await cmdScenes(subArgs)
        case "search":    try await cmdSearch(subArgs)
        case "email":     try await cmdEmail(subArgs)
        case "mcp":       try await cmdMcp(subArgs)
        case "skills":    try await cmdSkills(subArgs)
        case "help":      printUsage()
        default: break
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("quill: error: \(error)\n".utf8))
        return 1
    }
}

// Boot the main function asynchronously. Use RunLoop to keep the script
// alive (don't block the main thread — main() hops to the main actor).
Task {
    let code = await main()
    // We're on a background thread now, but exit() is safe to call from any
    // thread and immediately terminates the process.
    exit(code)
}

// Keep the script alive. RunLoop pumps the main thread's dispatch queue
// which lets the async work progress.
RunLoop.main.run()

// MARK: - Print helpers

func printUsage() {
    print("""
    quill — Quill CLI

    USAGE:
      quill <command> [args]

    COMMANDS:
      status                       Show backend, active model, current project
      ask "question"               One-shot Q&A with the active model
      chat [prompt]                Interactive chat (Ctrl-D to exit)
      fix <file>                   Fix typos/grammar in a file (in place)
      expand <file>                Add sensory detail (in place)
      condense <file>              Tighten prose (in place)
      slots [list|active ID]       Manage AI model slots
      projects [list|select ID]    List or select a project
      chapters [ls|cat NAME]       List chapters or print one's content
      scenes [ls|cat NAME]         List scenes or print one's content
      search "query"               Web search via DuckDuckGo
      email [list|send ...]        List inbox or send an email
      mcp serve                    Start MCP server (stdio JSON-RPC)
      skills [list|show NAME]      List/show OpenClaw skills

    Any other command is passed to /bin/sh -c, so you can run:
      quill ls
      quill git status
      quill pwd
      quill cd ~/Projects && ls

    OPTIONS:
      -h, --help                   Show this help
      -v, --version                Show version
    """)
}

func printJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        print(obj)
    }
}

func printError(_ msg: String) {
    FileHandle.standardError.write(Data("quill: \(msg)\n".utf8))
}

// MARK: - HTTP helpers

struct HTTPError: Error, CustomStringConvertible {
    let status: Int
    let body: String
    var description: String { "HTTP \(status): \(body)" }
}

func httpJSON(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
    var req = URLRequest(url: URL(string: BASE + path)!)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body = body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    // Use withCheckedContinuation so we don't deadlock the main thread.
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: req)
    } catch {
        throw error
    }
    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw HTTPError(status: http.statusCode, body: body)
    }
    if data.isEmpty { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
}

func httpGet(_ path: String) async throws -> Any {
    try await httpJSON("GET", path)
}

func httpPost(_ path: String, body: [String: Any]) async throws -> Any {
    try await httpJSON("POST", path, body: body)
}

func httpPut(_ path: String, body: [String: Any]) async throws -> Any {
    try await httpJSON("PUT", path, body: body)
}

func httpDelete(_ path: String) async throws -> Any {
    try await httpJSON("DELETE", path)
}

// MARK: - Commands

func cmdStatus() async throws {
    let health = try await httpGet("/api/health") as? [String: Any] ?? [:]
    let ctx = try await httpGet("/api/projects/__context__/context") as? [String: Any] ?? [:]

    print("Quill backend")
    print("  status:    \(health["backend"] ?? "?")")
    print("  ollama:    \(health["ollama"] ?? "?")")
    print("  slot:      \(health["slot_name"] ?? "?")")
    print("  model:     \(health["model"] ?? "?")")
    print("  slot_id:   \(health["slot_id"] ?? "?")")
    if let currentChapter = ctx["current_chapter"] as? String, !currentChapter.isEmpty {
        print("  chapter:   \(currentChapter)")
    }
}

func cmdAsk(_ args: [String]) async throws {
    let prompt: String
    if args.isEmpty {
        // Read from stdin
        let data = FileHandle.standardInput.readDataToEndOfFile()
        prompt = String(data: data, encoding: .utf8) ?? ""
    } else {
        prompt = args.joined(separator: " ")
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        printError("ask: missing prompt (pass as arg or pipe via stdin)")
        exit(1)
    }
    let result = try await httpPost("/api/chat", body: [
        "messages": [["role": "user", "content": prompt]],
        "stream": false,
    ]) as? [String: Any] ?? [:]
    if let text = result["text"] as? String {
        print(text)
    } else {
        printJSON(result)
    }
}

func cmdChat(_ args: [String]) async throws {
    let initialPrompt = args.joined(separator: " ")
    var history: [[String: String]] = []
    if !initialPrompt.isEmpty {
        history.append(["role": "user", "content": initialPrompt])
    }
    print("Quill chat (type 'exit' or Ctrl-D to quit, '/clear' to reset history)")
    print("")
    if !initialPrompt.isEmpty {
        await sendChatTurn(history: &history, printPrompt: false)
    }
    while true {
        print("> ", terminator: "")
        guard let line = readLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "exit" || trimmed == "quit" { break }
        if trimmed == "/clear" {
            history.removeAll()
            print("(history cleared)")
            continue
        }
        if trimmed.isEmpty { continue }
        history.append(["role": "user", "content": line])
        await sendChatTurn(history: &history, printPrompt: false)
    }
}

func sendChatTurn(history: inout [[String: String]], printPrompt: Bool) async {
    do {
        let result = try await httpPost("/api/chat", body: [
            "messages": history,
            "stream": false,
        ]) as? [String: Any] ?? [:]
        if let text = result["text"] as? String {
            print(text)
            history.append(["role": "assistant", "content": text])
        }
    } catch {
        printError("\(error)")
    }
}

func cmdFix(_ args: [String], instruction: String) async throws {
    guard let path = args.first else {
        printError("fix: missing file path")
        exit(1)
    }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let original = try String(contentsOf: url, encoding: .utf8)
    print("[\(instruction)] \(url.path) (\(original.count) chars)…")
    let result = try await httpPost("/api/edit-fix", body: [
        "text": original,
        "instruction": instruction,
    ]) as? [String: Any] ?? [:]
    guard let fixed = result["text"] as? String else {
        printError("fix: empty response")
        exit(1)
    }
    if fixed == original {
        print("(no changes needed)")
    } else {
        try fixed.write(to: url, atomically: true, encoding: .utf8)
        print("✓ fixed (\(original.count) → \(fixed.count) chars)")
    }
}

func cmdSlots(_ args: [String]) async throws {
    let sub = args.first ?? "list"
    if sub == "list" || sub == "ls" {
        let data = try await httpGet("/api/slots") as? [String: Any] ?? [:]
        let slots = data["slots"] as? [[String: Any]] ?? []
        let active = data["active_slot_id"] as? String ?? ""
        for s in slots {
            let id = s["id"] as? String ?? "?"
            let name = s["name"] as? String ?? "?"
            let type = s["type"] as? String ?? "?"
            let model = s["model_id"] as? String ?? "?"
            let tool = (s["tool_calling"] as? Bool) == true ? "🛠" : "  "
            let mark = id == active ? "*" : " "
            print("\(mark) \(tool) \(id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(name) (\(type), \(model))")
        }
    } else if sub == "active" {
        let data = try await httpGet("/api/slots/active") as? [String: Any] ?? [:]
        printJSON(data)
    } else {
        // sub is the slot id to activate
        _ = try await httpPost("/api/slots/\(sub)/activate", body: [:])
        print("✓ activated \(sub)")
    }
}

func cmdProjects(_ args: [String]) async throws {
    let sub = args.first ?? "list"
    if sub == "list" || sub == "ls" {
        let list = try await httpGet("/api/projects") as? [[String: Any]] ?? []
        for p in list {
            let id = p["id"] as? String ?? "?"
            let name = p["name"] as? String ?? "?"
            let count = p["chapter_count"] as? Int ?? 0
            print("  \(id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(name) (\(count) chapters)")
        }
    } else if sub == "select" {
        guard args.count > 1 else { printError("projects: select <id>"); exit(1) }
        let pid = args[1]
        // No select endpoint yet — print the project and tell the user
        let list = try await httpGet("/api/projects") as? [[String: Any]] ?? []
        if let p = list.first(where: { ($0["id"] as? String) == pid }) {
            print("selected: \(p["name"] ?? pid)")
            printJSON(p)
        } else {
            printError("no project with id \(pid)")
            exit(1)
        }
    } else {
        printError("projects: unknown subcommand \(sub)")
        exit(1)
    }
}

func cmdChapters(_ args: [String]) async throws {
    // Need a project id
    let projects = try await httpGet("/api/projects") as? [[String: Any]] ?? []
    guard let first = projects.first, let pid = first["id"] as? String else {
        printError("no projects exist — create one first")
        exit(1)
    }
    let sub = args.first ?? "ls"
    if sub == "ls" || sub == "list" {
        let list = try await httpGet("/api/projects/\(pid)/chapters") as? [[String: Any]] ?? []
        for c in list {
            let name = c["name"] as? String ?? "?"
            let size = c["size"] as? Int ?? 0
            print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(size) bytes")
        }
    } else if sub == "cat" {
        guard args.count > 1 else { printError("chapters: cat <name>"); exit(1) }
        let name = args[1]
        let data = try await httpGet("/api/projects/\(pid)/chapters/\(name)/content") as? [String: Any] ?? [:]
        if let content = data["content"] as? String {
            print(content)
        }
    }
}

func cmdScenes(_ args: [String]) async throws {
    let projects = try await httpGet("/api/projects") as? [[String: Any]] ?? []
    guard let first = projects.first, let pid = first["id"] as? String else {
        printError("no projects exist")
        exit(1)
    }
    let chapters = try await httpGet("/api/projects/\(pid)/chapters") as? [[String: Any]] ?? []
    guard let ch = chapters.first, let chapterName = ch["name"] as? String else {
        printError("no chapters exist")
        exit(1)
    }
    let sub = args.first ?? "ls"
    if sub == "ls" || sub == "list" {
        let list = try await httpGet("/api/projects/\(pid)/chapters/\(chapterName)/scenes") as? [[String: Any]] ?? []
        for s in list {
            let name = s["name"] as? String ?? "?"
            print("  \(chapterName)/\(name)")
        }
    } else if sub == "cat" {
        guard args.count > 1 else { printError("scenes: cat <name>"); exit(1) }
        let name = args[1]
        let data = try await httpGet("/api/projects/\(pid)/chapters/\(chapterName)/scenes/\(name)/content") as? [String: Any] ?? [:]
        if let content = data["content"] as? String {
            print(content)
        }
    }
}

func cmdSearch(_ args: [String]) async throws {
    let query = args.joined(separator: " ")
    guard !query.isEmpty else { printError("search: missing query"); exit(1) }
    let data = try await httpGet("/api/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") as? [String: Any] ?? [:]
    let results = data["results"] as? [[String: Any]] ?? []
    for (i, r) in results.enumerated() {
        let title = r["title"] as? String ?? "?"
        let url = r["url"] as? String ?? "?"
        let snippet = r["snippet"] as? String ?? ""
        print("\(i+1). \(title)")
        print("   \(url)")
        if !snippet.isEmpty { print("   \(snippet)") }
    }
}

func cmdEmail(_ args: [String]) async throws {
    let sub = args.first ?? "list"
    if sub == "list" || sub == "ls" {
        let data = try await httpGet("/api/agentmail/inbox?limit=20") as? [String: Any] ?? [:]
        let messages = data["messages"] as? [[String: Any]] ?? []
        for m in messages {
            let from = m["from"] as? String ?? "?"
            let subject = m["subject"] as? String ?? "(no subject)"
            let id = m["id"] as? String ?? "?"
            print("  \(id)  \(from) — \(subject)")
        }
    } else if sub == "send" {
        // quill email send <to> <subject> <text>
        guard args.count >= 4 else { printError("email send: <to> <subject> <text>"); exit(1) }
        let to = args[1]
        let subject = args[2]
        let text = args[3...].joined(separator: " ")
        let result = try await httpPost("/api/agentmail/send", body: [
            "to": to, "subject": subject, "text": text,
        ])
        printJSON(result)
    } else if sub == "read" {
        guard args.count > 1 else { printError("email read <id>"); exit(1) }
        let id = args[1]
        let data = try await httpGet("/api/agentmail/messages/\(id)") as? [String: Any] ?? [:]
        printJSON(data)
    }
}

func cmdMcp(_ args: [String]) async throws {
    let sub = args.first ?? ""
    if sub == "serve" {
        await runMCPServer()
    } else {
        printError("mcp: unknown subcommand \(sub). Try `quill mcp serve`")
        exit(1)
    }
}

func cmdSkills(_ args: [String]) async throws {
    let sub = args.first ?? "list"
    if sub == "list" || sub == "ls" {
        let data = try await httpGet("/api/skills") as? [String: Any] ?? [:]
        let status = data["status"] as? [String: Any] ?? [:]
        let skills = data["skills"] as? [[String: Any]] ?? []
        if let count = status["skill_count"] as? Int {
            print("\(count) skills available")
        }
        if let path = status["config_path"] as? String {
            print("config: \(path)")
        }
        print("")
        for s in skills {
            let name = s["name"] as? String ?? "?"
            let keywords = (s["keywords"] as? [String]) ?? []
            let kwPreview = keywords.prefix(5).joined(separator: ", ")
            print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(kwPreview)")
        }
    } else if sub == "show" {
        guard args.count > 1 else { printError("skills show <name>"); exit(1) }
        let name = args[1]
        let data = try await httpGet("/api/skills/\(name)") as? [String: Any] ?? [:]
        if let content = data["content"] as? String, !content.isEmpty {
            print(content)
        } else {
            print("(no SKILL.md content for \(name) — registry entry only)")
            if let k = data["keywords"] as? [String] {
                print("keywords: \(k.joined(separator: ", "))")
            }
        }
    } else if sub == "reload" {
        let data = try await httpPost("/api/skills/reload", body: [:]) as? [String: Any] ?? [:]
        printJSON(data)
    } else if sub == "find" {
        // Find a skill whose keywords match a phrase
        guard args.count > 1 else { printError("skills find <phrase>"); exit(1) }
        let phrase = args.dropFirst().joined(separator: " ")
        let data = try await httpGet("/api/skills") as? [String: Any] ?? [:]
        let skills = data["skills"] as? [[String: Any]] ?? []
        let phraseLower = phrase.lowercased()
        let matches = skills.filter { s in
            let kws = (s["keywords"] as? [String]) ?? []
            return kws.contains(where: { phraseLower.contains($0.lowercased()) })
        }
        if matches.isEmpty {
            print("no skills match \"\(phrase)\"")
        } else {
            print("\(matches.count) skills match \"\(phrase)\":")
            for s in matches {
                let n = s["name"] as? String ?? "?"
                let k = ((s["keywords"] as? [String]) ?? []).prefix(3).joined(separator: ", ")
                print("  \(n) — \(k)")
            }
        }
    } else {
        printError("skills: unknown subcommand \(sub). Try `quill skills list`")
        exit(1)
    }
}

// MARK: - REPL

func runREPL() async {
    print("Quill REPL — type 'help' for commands, 'exit' to quit")
    while true {
        print("quill> ", terminator: "")
        guard let line = readLine() else { break }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { continue }
        if parts[0] == "exit" || parts[0] == "quit" { break }
        if parts[0] == "help" { printUsage(); continue }
        do {
            switch parts[0] {
            case "status":    try await cmdStatus()
            case "ask":       try await cmdAsk(Array(parts.dropFirst()))
            case "slots":     try await cmdSlots(Array(parts.dropFirst()))
            case "projects":  try await cmdProjects(Array(parts.dropFirst()))
            case "chapters":  try await cmdChapters(Array(parts.dropFirst()))
            case "scenes":    try await cmdScenes(Array(parts.dropFirst()))
            case "search":    try await cmdSearch(Array(parts.dropFirst()))
            case "email":     try await cmdEmail(Array(parts.dropFirst()))
            case "mcp":       try await cmdMcp(Array(parts.dropFirst()))
            case "skills":    try await cmdSkills(Array(parts.dropFirst()))
            case "fix":       try await cmdFix(Array(parts.dropFirst()), instruction: "fix typos and grammar")
            case "expand":    try await cmdFix(Array(parts.dropFirst()), instruction: "expand with sensory detail")
            case "condense":  try await cmdFix(Array(parts.dropFirst()), instruction: "condense and tighten")
            default:
                _ = runShellPassThrough(parts)
            }
        } catch {
            printError("\(error)")
        }
    }
}

// MARK: - Shell pass-through

func runShellPassThrough(_ args: [String]) -> Int32 {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", args.joined(separator: " ")]
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    do {
        try process.run()
    } catch {
        printError("failed to launch shell: \(error)")
        return 1
    }
    process.waitUntilExit()
    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    if let s = String(data: outData, encoding: .utf8) { FileHandle.standardOutput.write(Data(s.utf8)) }
    if let s = String(data: errData, encoding: .utf8) { FileHandle.standardError.write(Data(s.utf8)) }
    return process.terminationStatus
}

// MARK: - MCP server (stdio JSON-RPC 2.0)
//
// Minimal Model Context Protocol server. Exposes the Quill backend as MCP
// tools. Any MCP-compatible client (Claude Desktop, Claude Code, etc.) can
// connect via stdio.
//
// Tools exposed:
//   list_projects          - list all projects
//   select_project         - select a project by id
//   list_chapters          - list chapters in the current project
//   read_chapter           - read a chapter's content
//   write_chapter          - write a chapter (creates if missing)
//   list_scenes            - list scenes in a chapter
//   read_scene             - read a scene's content
//   edit_fix               - fix typos/grammar on a snippet
//   search_web             - web search via DuckDuckGo
//   shell_exec             - run a shell command (safety-checked)
//   list_files             - list files in a directory
//   read_file              - read a text file
//   send_email             - send an email via AgentMail
//   list_inbox             - list recent emails

func runMCPServer() async {
    FileHandle.standardError.write(Data("[quill mcp] starting stdio server\n".utf8))
    // Read JSON-RPC 2.0 messages from stdin (newline-delimited)
    while let line = readLine() {
        guard !line.isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = msg["method"] as? String else { continue }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        let response = await handleMCPRequest(id: id, method: method, params: params)
        if let resp = response,
           let respData = try? JSONSerialization.data(withJSONObject: resp),
           let respStr = String(data: respData, encoding: .utf8) {
            print(respStr)
            fflush(stdout)
        }
    }
}

func handleMCPRequest(id: Any?, method: String, params: [String: Any]) async -> [String: Any]? {
    switch method {
    case "initialize":
        return jsonRPCResponse(id: id, result: [
            "protocolVersion": "2024-11-05",
            "serverInfo": ["name": "quill", "version": "1.0.0"],
            "capabilities": ["tools": [String: Any]()],
        ])
    case "tools/list":
        return jsonRPCResponse(id: id, result: ["tools": mcpToolsList()])
    case "tools/call":
        guard let name = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        return jsonRPCResponse(id: id, result: await mcpCallTool(name: name, args: args))
    default:
        return jsonRPCError(id: id, code: -32601, message: "method not found: \(method)")
    }
}

func jsonRPCResponse(id: Any?, result: Any) -> [String: Any] {
    return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
}
func jsonRPCError(id: Any?, code: Int, message: String) -> [String: Any] {
    return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

func mcpToolsList() -> [[String: Any]] {
    return [
        ["name": "list_projects", "description": "List all Quill projects", "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "select_project", "description": "Select a project by id", "inputSchema": ["type": "object", "properties": ["project_id": ["type": "string"]], "required": ["project_id"]]],
        ["name": "list_chapters", "description": "List chapters in the current project", "inputSchema": ["type": "object", "properties": ["project_id": ["type": "string"]]]],
        ["name": "read_chapter", "description": "Read a chapter's full content", "inputSchema": ["type": "object", "properties": ["project_id": ["type": "string"], "chapter": ["type": "string"]], "required": ["chapter"]]],
        ["name": "write_chapter", "description": "Write content to a chapter (creates if missing)", "inputSchema": ["type": "object", "properties": ["project_id": ["type": "string"], "chapter": ["type": "string"], "content": ["type": "string"]], "required": ["chapter", "content"]]],
        ["name": "list_scenes", "description": "List scenes in a chapter", "inputSchema": ["type": "object", "properties": ["project_id": ["type": "string"], "chapter": ["type": "string"]], "required": ["chapter"]]],
        ["name": "read_scene", "description": "Read a scene's content", "inputSchema": ["type": "object", "properties": ["project_id": ["type": "string"], "chapter": ["type": "string"], "scene": ["type": "string"]], "required": ["chapter", "scene"]]],
        ["name": "edit_fix", "description": "Fix typos/grammar in a text snippet via AI", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"], "instruction": ["type": "string"]], "required": ["text"]]],
        ["name": "search_web", "description": "Web search via DuckDuckGo", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "max_results": ["type": "integer"]], "required": ["query"]]],
        ["name": "shell_exec", "description": "Run a shell command (safety-checked)", "inputSchema": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]],
        ["name": "list_files", "description": "List files in a directory", "inputSchema": ["type": "object", "properties": ["path": ["type": "string"]]]],
        ["name": "read_file", "description": "Read a text file", "inputSchema": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]],
        ["name": "send_email", "description": "Send an email via AgentMail", "inputSchema": ["type": "object", "properties": ["to": ["type": "string"], "subject": ["type": "string"], "text": ["type": "string"]], "required": ["to", "subject", "text"]]],
        ["name": "list_inbox", "description": "List recent emails from the Quill inbox", "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer"]]]],
    ]
}

func mcpCallTool(name: String, args: [String: Any]) async -> [String: Any] {
    do {
        var resultText: String = ""
        var resultData: [String: Any] = [:]
        switch name {
        case "list_projects":
            let list = try await httpGet("/api/projects") as? [[String: Any]] ?? []
            resultData = ["projects": list]
            resultText = list.map { "\($0["id"] ?? "?"): \($0["name"] ?? "?")" }.joined(separator: "\n")
        case "select_project":
            guard let pid = args["project_id"] as? String else { throw MCPError("missing project_id") }
            let p = try await httpGet("/api/projects/\(pid)") as? [String: Any] ?? [:]
            resultData = p
            resultText = "Selected \(p["name"] ?? pid)"
        case "list_chapters":
            let pid = args["project_id"] as? String ?? "__default__"
            let list = try await httpGet("/api/projects/\(pid)/chapters") as? [[String: Any]] ?? []
            resultData = ["chapters": list]
            resultText = list.map { $0["name"] as? String ?? "?" }.joined(separator: "\n")
        case "read_chapter":
            let pid = args["project_id"] as? String ?? "__default__"
            let chapter = args["chapter"] as? String ?? ""
            let d = try await httpGet("/api/projects/\(pid)/chapters/\(chapter)/content") as? [String: Any] ?? [:]
            resultText = d["content"] as? String ?? ""
        case "write_chapter":
            let pid = args["project_id"] as? String ?? "__default__"
            let chapter = args["chapter"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            let d = try await httpPut("/api/projects/\(pid)/chapters/\(chapter)/content", body: ["content": content]) as? [String: Any] ?? [:]
            resultText = "wrote \(d["bytes"] ?? 0) bytes"
        case "list_scenes":
            let pid = args["project_id"] as? String ?? "__default__"
            let chapter = args["chapter"] as? String ?? ""
            let list = try await httpGet("/api/projects/\(pid)/chapters/\(chapter)/scenes") as? [[String: Any]] ?? []
            resultData = ["scenes": list]
            resultText = list.map { $0["name"] as? String ?? "?" }.joined(separator: "\n")
        case "read_scene":
            let pid = args["project_id"] as? String ?? "__default__"
            let chapter = args["chapter"] as? String ?? ""
            let scene = args["scene"] as? String ?? ""
            let d = try await httpGet("/api/projects/\(pid)/chapters/\(chapter)/scenes/\(scene)/content") as? [String: Any] ?? [:]
            resultText = d["content"] as? String ?? ""
        case "edit_fix":
            let text = args["text"] as? String ?? ""
            let instruction = args["instruction"] as? String ?? "fix typos and grammar"
            let r = try await httpPost("/api/edit-fix", body: ["text": text, "instruction": instruction]) as? [String: Any] ?? [:]
            resultText = r["text"] as? String ?? ""
            resultData = r
        case "search_web":
            let query = args["query"] as? String ?? ""
            let max = args["max_results"] as? Int ?? 5
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let d = try await httpGet("/api/search?q=\(encoded)&max=\(max)") as? [String: Any] ?? [:]
            let results = d["results"] as? [[String: Any]] ?? []
            resultData = ["results": results]
            resultText = results.map { "\($0["title"] ?? "?")\n  \($0["url"] ?? "")\n  \($0["snippet"] ?? "")" }.joined(separator: "\n\n")
        case "shell_exec":
            let cmd = args["cmd"] as? String ?? ""
            let r = try await httpPost("/api/tools/call", body: ["name": "shell_exec", "args": ["cmd": cmd]]) as? [String: Any] ?? [:]
            resultData = r
            if let out = r["stdout"] as? String { resultText += out }
            if let err = r["stderr"] as? String, !err.isEmpty { resultText += "\n[stderr]\n" + err }
        case "list_files":
            let path = args["path"] as? String ?? "."
            let r = try await httpPost("/api/tools/call", body: ["name": "list_files", "args": ["path": path]]) as? [String: Any] ?? [:]
            resultData = r
            if let files = r["files"] as? [String] { resultText = files.joined(separator: "\n") }
        case "read_file":
            let path = args["path"] as? String ?? ""
            let r = try await httpPost("/api/tools/call", body: ["name": "read_file", "args": ["path": path]]) as? [String: Any] ?? [:]
            resultText = r["content"] as? String ?? ""
        case "send_email":
            let to = args["to"] as? String ?? ""
            let subject = args["subject"] as? String ?? ""
            let text = args["text"] as? String ?? ""
            let r = try await httpPost("/api/agentmail/send", body: ["to": to, "subject": subject, "text": text]) as? [String: Any] ?? [:]
            resultData = r
            resultText = r["ok"] as? Bool == true ? "✓ sent" : "✗ \(r["error"] ?? "unknown")"
        case "list_inbox":
            let limit = args["limit"] as? Int ?? 20
            let d = try await httpGet("/api/agentmail/inbox?limit=\(limit)") as? [String: Any] ?? [:]
            let messages = d["messages"] as? [[String: Any]] ?? []
            resultData = ["messages": messages]
            resultText = messages.map { "\($0["from"] ?? "?") — \($0["subject"] ?? "?")" }.joined(separator: "\n")
        default:
            return ["content": [["type": "text", "text": "unknown tool: \(name)"]], "isError": true]
        }
        var content: [[String: Any]] = [["type": "text", "text": resultText]]
        if !resultData.isEmpty {
            if let data = try? JSONSerialization.data(withJSONObject: resultData),
               let str = String(data: data, encoding: .utf8) {
                content.append(["type": "text", "text": "\n\n[structured data]\n\(str)"])
            }
        }
        return ["content": content, "isError": false]
    } catch {
        return ["content": [["type": "text", "text": "error: \(error)"]], "isError": true]
    }
}

struct MCPError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ m: String) { message = m }
}
