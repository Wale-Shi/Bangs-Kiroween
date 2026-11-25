import AppKit
import Foundation
import Security

/// Who translates. Apple's translation stays on this Mac; the other two hand the text to a model you chose: at an
/// address you gave, or through a coding agent you already use. Bangs sends nothing anywhere unless you pick one of them.
enum TranslateEngine: String, CaseIterable {
    case apple, model, agent

    var title: String {
        switch self {
        case .apple: "macOS 本机翻译"
        case .model: "大模型 API"
        case .agent: "本机 Agent（ACP）"
        }
    }
}

/// What the model or agent is asked: the translation alone, with the layout and anything technical kept as it is.
enum TranslatePrompt {
    /// The language's name in English, which every model reads.
    static func language(_ id: String) -> String {
        switch id {
        case "zh-Hans": "Simplified Chinese"
        case "zh-Hant": "Traditional Chinese"
        default: Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
        }
    }

    static func instructions(to target: String) -> String {
        """
        You are a translation engine. Translate the user's text into \(language(target)). Reply with the translation only: \
        no preamble, no notes, no quotation marks around it. Keep line breaks, Markdown, code, commands, file paths, URLs and \
        names exactly as they are. If the text is already in \(language(target)), translate it into English instead.
        """
    }

    /// For an agent, which has no separate instructions: the same, with the text marked off so it is not read as a task.
    static func agent(_ text: String, to target: String) -> String {
        instructions(to: target) + " Do not use any tools.\n\n<text>\n\(text)\n</text>"
    }
}

/// The API key, kept in the login Keychain rather than in Bangs' preferences.
enum TranslateKey {
    private static let service = "io.github.wale-shi.bangs.translate"
    private static let account = "api-key"

    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "Bangs 翻译 API Key"
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum TranslateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

/// A model's chat API, streamed: OpenAI's chat completions (which most providers and local servers speak) or Anthropic's
/// Messages API.
enum ModelAPI {
    enum Format: String, CaseIterable {
        case openAI, anthropic
        var title: String { self == .openAI ? "OpenAI 兼容" : "Anthropic" }
    }

    struct Preset: Hashable {
        let name: String
        let format: Format
        let url: String
        let model: String
    }

    /// Filled in by the settings' preset menu; every field stays yours to change.
    static let presets = [
        Preset(name: "OpenAI", format: .openAI, url: "https://api.openai.com/v1", model: ""),
        Preset(name: "Anthropic", format: .anthropic, url: "https://api.anthropic.com", model: "claude-opus-5-5"),
        Preset(name: "DeepSeek", format: .openAI, url: "https://api.deepseek.com", model: "deepseek-chat"),
        Preset(name: "通义千问（百炼）", format: .openAI, url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        Preset(name: "Kimi（Moonshot）", format: .openAI, url: "https://api.moonshot.cn/v1", model: ""),
        Preset(name: "智谱 GLM", format: .openAI, url: "https://open.bigmodel.cn/api/paas/v4", model: ""),
        Preset(name: "OpenRouter", format: .openAI, url: "https://openrouter.ai/api/v1", model: ""),
        Preset(name: "Ollama（本机）", format: .openAI, url: "http://localhost:11434/v1", model: ""),
        Preset(name: "LM Studio（本机）", format: .openAI, url: "http://localhost:1234/v1", model: ""),
    ]

    /// No cookies, cache or stored credentials; tests swap in a stub.
    nonisolated(unsafe) static var sessionConfiguration: () -> URLSessionConfiguration = { .ephemeral }

    /// The endpoint for a base address: "/chat/completions" or "/v1/messages" added unless it is already there.
    static func endpoint(_ base: String, format: Format) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        switch format {
        case .openAI: if !text.hasSuffix("/chat/completions") { text += "/chat/completions" }
        case .anthropic:
            if !text.hasSuffix("/messages") { text += text.hasSuffix("/v1") ? "/messages" : "/v1/messages" }
        }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Claude models that take an effort setting: translation runs at `low`, the quickest.
    static func takesEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5", "claude-opus-4-6", "claude-opus-4-7",
         "claude-opus-4-8", "claude-sonnet-4-6"].contains { model.hasPrefix($0) }
    }

    /// Models whose safety classifiers may decline, and which Anthropic's API can then re-run on another model.
    static func fallsBack(_ model: String) -> Bool {
        ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    static func request(text: String, to target: String, format: Format, base: String, model: String, key: String) throws -> URLRequest {
        guard let url = endpoint(base, format: format) else { throw TranslateError.message("API 地址不对：要以 http:// 或 https:// 开头。") }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw TranslateError.message("还没有填模型名称。") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any]
        switch format {
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": model, "stream": true,
                    "messages": [["role": "system", "content": TranslatePrompt.instructions(to: target)], ["role": "user", "content": text]]]
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 16000, "stream": true, "system": TranslatePrompt.instructions(to: target),
                    "messages": [["role": "user", "content": text]]]
            if takesEffort(model) { body["output_config"] = ["effort": "low"] }
            // Only Anthropic's own API knows the fallback; a proxy in front of it may refuse the field.
            if url.host == "api.anthropic.com", fallsBack(model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The translation as it arrives, a piece at a time.
    static func stream(text: String, to target: String, format: Format, base: String, model: String, key: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try request(text: text, to: target, format: format, base: base, model: model, key: key)
                    let session = URLSession(configuration: sessionConfiguration())
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 4000 { break } }
                        throw TranslateError.message(failure(status: status, body: body))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let piece = try piece(of: object, format: format), !piece.isEmpty { continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The text in one streamed event, or an error the event carries.
    static func piece(of event: [String: Any], format: Format) throws -> String? {
        if let error = event["error"] as? [String: Any] { throw TranslateError.message(error["message"] as? String ?? "模型返回了错误。") }
        switch format {
        case .openAI:
            let choice = (event["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        case .anthropic:
            switch event["type"] as? String {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { throw TranslateError.message("模型拒绝翻译这段文字。") }
                return nil
            default: return nil
            }
        }
    }

    /// What went wrong, in the provider's own words when it gave any.
    static func failure(status: Int, body: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["message"] as? String) ?? (object?["error"] as? String)
        let reason = switch status {
        case 401, 403: "API Key 不对或没有权限"
        case 404: "地址或模型名不对"
        case 429: "请求太多或额度用完了"
        default: "HTTP \(status)"
        }
        return message.map { "\(reason)：\($0)" } ?? reason
    }
}

/// The PATH your terminal has: Bangs is started by launchd with a short one, and CLIs installed with Homebrew, npm or
/// a version manager live outside it. Read once from your login shell.
enum ShellPath {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    static var value: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let found = read() ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
        var seen: [String] = []
        for dir in found.split(separator: ":").map(String.init) + extra where !dir.isEmpty && !seen.contains(dir) { seen.append(dir) }
        cached = seen.joined(separator: ":")
        return cached!
    }

    /// An interactive login shell, as a terminal runs one, so both its profile and rc files are read; quiet, and given
    /// five seconds.
    private static func read() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\\n__BANGS_PATH__%s\\n' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__BANGS_PATH__") }) else { return nil }
        return String(line.dropFirst("__BANGS_PATH__".count))
    }

    /// Where a program is found on that PATH, if it is.
    static func locate(_ program: String) -> String? {
        if program.contains("/") { return FileManager.default.isExecutableFile(atPath: program) ? program : nil }
        return value.split(separator: ":").map { "\($0)/\(program)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A coding agent on this Mac, spoken to over the Agent Client Protocol (JSON-RPC over its standard input and output):
/// a new session for each translation, its reply streamed back. The agent runs with your own login and settings; Bangs
/// gives it no files and no terminal, and turns down any tool it asks to use. It is kept running a few minutes between
/// translations, since starting one takes seconds.
@MainActor
final class ACPAgent {
    struct Preset: Hashable {
        let id: String
        let name: String
        let command: String
        /// How to get it when it is not installed.
        let install: String
    }

    static let presets = [
        Preset(id: "gemini", name: "Gemini CLI", command: "gemini --acp", install: "brew install gemini-cli"),
        Preset(id: "claude", name: "Claude Code", command: "claude-agent-acp", install: "npm install -g @agentclientprotocol/claude-agent-acp"),
        Preset(id: "codex", name: "Codex", command: "codex-acp", install: "npm install -g @agentclientprotocol/codex-acp"),
        Preset(id: "qwen", name: "Qwen Code", command: "qwen --acp", install: "npm install -g @qwen-code/qwen-code"),
        Preset(id: "opencode", name: "OpenCode", command: "opencode acp", install: "brew install opencode"),
    ]

    static func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }

    static let shared = ACPAgent()

    private var process: Process?
    private var input: FileHandle?
    private var command = ""
    private var nextID = 1
    private var buffer = Data()
    private var errors = ""
    private var replies: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var chunks: [String: (String) -> Void] = [:]
    private var idle: DispatchWorkItem?
    /// How long an agent stays up with nothing to translate.
    static let keepAlive: TimeInterval = 300

    /// The translation as the agent writes it.
    func translate(_ text: String, to target: String, command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var session: String?
                do {
                    try await start(command)
                    idle?.cancel()
                    let folder = Storage.directory("Translate")
                    let created = try await call("session/new", ["cwd": folder.path, "mcpServers": [Any]()])
                    guard let id = created["sessionId"] as? String else { throw TranslateError.message("Agent 没有开出会话。") }
                    session = id
                    chunks[id] = { continuation.yield($0) }
                    let done = try await call("session/prompt", ["sessionId": id, "prompt": [["type": "text", "text": TranslatePrompt.agent(text, to: target)]]], timeout: 120)
                    if done["stopReason"] as? String == "refusal" { throw TranslateError.message("Agent 拒绝翻译这段文字。") }
                    chunks[id] = nil
                    continuation.finish()
                } catch {
                    if let session { chunks[session] = nil }
                    continuation.finish(throwing: error)
                }
                scheduleStop()
            }
            continuation.onTermination = { [weak self] reason in
                task.cancel()
                guard case .cancelled = reason else { return }
                Task { @MainActor in self?.cancelAll() }
            }
        }
    }

    /// Starts the agent and introduces Bangs, unless it is already running the same command.
    private func start(_ command: String) async throws {
        if let process, process.isRunning, self.command == command { return }
        stop()
        // Reading the login shell's PATH can take a moment, the first time.
        let program = command.split(separator: " ").first.map(String.init) ?? ""
        let found = await Task.detached { ShellPath.locate(program) }.value
        guard found != nil else {
            throw TranslateError.message("找不到 \(command.split(separator: " ").first ?? "")：先安装它，或在设置 › 翻译里换一个 Agent。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \(command)"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ShellPath.value
        // The agent's own hooks would report this session to Bangs: it is Bangs' own, not one to show.
        environment["BANGS_IGNORE"] = "1"
        process.environment = environment
        process.currentDirectoryURL = Storage.directory("Translate")
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.errors = String(((self?.errors ?? "") + text).suffix(2000)) }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.ended(process) } }
        try process.run()
        self.process = process
        self.command = command
        input = stdin.fileHandleForWriting
        errors = ""
        _ = try await call("initialize", ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], timeout: 60)
    }

    func stop() {
        idle?.cancel()
        for handle in [process?.standardOutput, process?.standardError] { (handle as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        buffer = Data()
        fail(TranslateError.message("Agent 已停止。"))
    }

    private func scheduleStop() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepAlive, execute: work)
    }

    private func cancelAll() {
        for session in chunks.keys { send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": session]]) }
        chunks = [:]
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        input = nil
        let detail = errors.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
        fail(TranslateError.message("Agent 退出了" + (detail.map { "：\($0)" } ?? "。")))
    }

    private func fail(_ error: Error) {
        let waiting = replies
        replies = [:]
        for (_, reply) in waiting { reply.resume(throwing: error) }
    }

    /// A request to the agent and its answer; after `timeout` seconds without one, an error instead.
    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    self?.replies.removeValue(forKey: id)?.resume(throwing: TranslateError.message("Agent 超过 \(Int(timeout)) 秒没有回应。"))
                }
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any]
            if method == "session/update", let session = params?["sessionId"] as? String,
               let update = params?["update"] as? [String: Any], update["sessionUpdate"] as? String == "agent_message_chunk",
               let content = update["content"] as? [String: Any], content["type"] as? String == "text", let text = content["text"] as? String {
                chunks[session]?(text)
            } else if let id = message["id"] {
                // The agent asks something of Bangs: a tool's permission is turned down; files and terminals Bangs does not offer.
                if method == "session/request_permission" {
                    send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                } else {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Bangs only asks for translations."]])
                }
            }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue, let reply = replies.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            reply.resume(throwing: TranslateError.message(error["message"] as? String ?? "Agent 返回了错误。"))
        } else {
            reply.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }
}
