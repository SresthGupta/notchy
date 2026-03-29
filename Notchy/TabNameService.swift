import Foundation

class TabNameService {
    static let shared = TabNameService()

    private let claudePath: String?

    private init() {
        // Resolve claude binary path at init
        claudePath = Self.findClaude()
    }

    /// Generate a 2-4 word tab name from the user's prompt text.
    /// Calls completion on the main thread with the name, or nil on failure.
    func generateName(from prompt: String, completion: @escaping (String?) -> Void) {
        guard let claudePath else {
            completion(nil)
            return
        }

        let truncatedPrompt = String(prompt.prefix(500))

        DispatchQueue.global(qos: .utility).async {
            let result = Self.runClaude(
                path: claudePath,
                prompt: truncatedPrompt
            )

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func runClaude(path: String, prompt: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "--print",
            "--model", "haiku",
            "-p",
            "Return ONLY a 2-4 word lowercase tab name summarizing this task. No quotes, no punctuation, no explanation. Examples: fix auth bug, refactor api client, add dark mode, update tests",
            prompt
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // suppress stderr

        // Timeout: kill process after 15 seconds
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()

        defer { timer.cancel() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read stdout before waitUntilExit to avoid pipe buffer deadlock
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // Enforce max length
        if name.count > 20 {
            // Take first 20 chars, trim to last full word
            let truncated = String(name.prefix(20))
            if let lastSpace = truncated.lastIndex(of: " ") {
                return String(truncated[truncated.startIndex..<lastSpace])
            }
            return truncated
        }

        return name
    }

    private static func findClaude() -> String? {
        // Check common paths
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: try `which claude`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return nil
    }
}
