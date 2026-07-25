import Foundation

class ProcessManager {
    static let shared = ProcessManager()

    private var backendProcess: Process?

    func startBackend() {
        // Check if backend already running on 5323
        if isBackendRunning() {
            print("[Quill] Backend already running on 5323")
            return
        }

        let script = """
        #!/bin/bash
        cd ~/Projects/Quill/backend 2>/dev/null || cd ~/Quill/backend
        exec python3 server.py
        """

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            backendProcess = task
            print("[Quill] Backend process started, PID: \(task.processIdentifier)")

            // Wait briefly for backend to bind to port
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.25)
                if isBackendRunning() {
                    print("[Quill] Backend ready")
                    return
                }
            }
            print("[Quill] Warning: backend may not be ready yet")
        } catch {
            print("[Quill] Failed to start backend: \(error)")
        }
    }

    func stopBackend() {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "lsof -ti:5323 | xargs kill -9 2>/dev/null || true"]
        try? task.run()
        task.waitUntilExit()
    }

    private func isBackendRunning() -> Bool {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "lsof -ti:5323 > /dev/null 2>&1"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
