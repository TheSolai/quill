#!/usr/bin/env swift
import Foundation

// quill-ai-helper — Swift CLI bridge for AI calls
// Reads JSON {prompt, model, stream} from stdin, calls Ollama, writes responses.

struct Request: Decodable {
    let prompt: String
    let model: String
    let stream: Bool
}

let stdin = FileHandle.standardInput
let inputData = stdin.readDataToEndOfFile()
guard let request = try? JSONDecoder().decode(Request.self, from: inputData) else {
    FileHandle.standardError.write(Data("Invalid request\n".utf8))
    exit(1)
}

let url = URL(string: "http://127.0.0.1:5323/api/chat")!
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")

let payload: [String: Any] = [
    "model": request.model,
    "messages": [["role": "user", "content": request.prompt]],
    "stream": request.stream
]
req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

let semaphore = DispatchSemaphore(value: 0)
let task = URLSession.shared.dataTask(with: req) { data, response, error in
    defer { semaphore.signal() }
    guard let data = data, error == nil else {
        let err: [String: Any] = ["error": error?.localizedDescription ?? "Unknown error"]
        let json = try? JSONSerialization.data(withJSONObject: err)
        FileHandle.standardOutput.write(json ?? Data("{\"error\":\"unknown\"}".utf8))
        return
    }

    if request.stream {
        if let text = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    } else {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            let out: [String: Any] = ["text": text]
            let outData = try? JSONSerialization.data(withJSONObject: out)
            FileHandle.standardOutput.write(outData ?? Data("{\"text\":\"\"}".utf8))
        }
    }
}
task.resume()
semaphore.wait()
