import AppKit
import Combine
import Foundation

// MARK: - Mensajes

struct ToolCall: Codable {
    var name: String
    var arguments: [String: JSONValue]

    var requestJSON: [String: Any] {
        ["type": "function",
         "function": ["name": name, "arguments": arguments.mapValues { $0.toAny() } as [String: Any]]]
    }
}

struct ChatMessage: Codable {
    var role: String
    var content: String
    var toolCalls: [ToolCall]?
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    func jsonObject() -> [String: Any] {
        var d: [String: Any] = ["role": role, "content": content]
        if let tc = toolCalls, !tc.isEmpty {
            d["tool_calls"] = tc.map { $0.requestJSON }
        }
        if let tn = toolName {
            d["tool_name"] = tn
        }
        return d
    }
}

enum ToolEvent {
    case start(String, [String: JSONValue])
    case done(String, String)
    case cancelled(String)
}

enum AgentError: LocalizedError {
    case cancelled
    case http(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelado"
        case .http(let s): return s
        case .message(let s): return s
        }
    }
}

// MARK: - Cliente Ollama

private struct RawFunction: Decodable {
    var name: String?
    var arguments: JSONValue?
}

private struct RawToolCall: Decodable {
    var index: Int?
    var function: RawFunction?
}

private struct RawMessage: Decodable {
    var role: String?
    var content: String?
    var toolCalls: [RawToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

private struct ChatChunk: Decodable {
    var message: RawMessage?
    var done: Bool?
    var error: String?
}

private struct PullChunk: Decodable {
    var status: String?
    var completed: Int64?
    var total: Int64?
    var error: String?
}

extension JSONValue {
    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            self = .array(a.map { JSONValue(any: $0) })
        case let d as [String: Any]:
            self = .object(d.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: any))
        }
    }
}

@MainActor
struct OllamaClient {
    var baseURLString: String

    init(baseURLString: String? = nil) {
        self.baseURLString = baseURLString
            ?? ProcessInfo.processInfo.environment["AGENTE_OLLAMA_URL"]
            ?? "http://127.0.0.1:11434"
    }

    var base: URL {
        URL(string: baseURLString) ?? URL(string: "http://127.0.0.1:11434")!
    }

    func alive() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/version"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func listModels() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("api/tags"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentError.http("No se pudo consultar /api/tags")
        }
        struct Tags: Decodable {
            struct M: Decodable { var name: String? }
            var models: [M]?
        }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return (tags.models ?? []).compactMap { $0.name }
    }

    func hasModel(_ model: String) async -> Bool {
        guard let names = try? await listModels() else { return false }
        if names.contains(model) { return true }
        // sin tag explícito: vale cualquier tag instalado con esa base
        guard !model.contains(":") else { return false }
        let baseName = model.split(separator: ":").first.map(String.init) ?? model
        return names.contains { $0.split(separator: ":").first.map(String.init) == baseName }
    }

    func pull(model: String, onStatus: (String) -> Void) async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3600
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentError.http("No se pudo iniciar la descarga de \(model)")
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8), !line.isEmpty,
                  let chunk = try? JSONDecoder().decode(PullChunk.self, from: data) else { continue }
            if let error = chunk.error {
                throw AgentError.message("Error descargando \(model): \(error)")
            }
            if let status = chunk.status {
                if status == "done" {
                    onStatus("Modelo \(model) listo")
                } else if status.contains("downloading"), let total = chunk.total, total > 0,
                          let completed = chunk.completed {
                    let pct = Int(Double(completed) * 100 / Double(total))
                    onStatus("Descargando \(model)… \(pct)%")
                } else if status.contains("pulling") || status.contains("loading") {
                    onStatus("Descargando \(model)…")
                }
            }
        }
    }

    func chatStream(messages: [ChatMessage], model: String,
                    includeTools: Bool = true,
                    onText: (String) -> Void,
                    isCancelled: () -> Bool) async throws -> [ToolCall] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { $0.jsonObject() },
            "stream": true,
            "options": ["temperature": 0.6, "num_ctx": 4096, "num_predict": 1024] as [String: Any],
        ]
        if includeTools {
            body["tools"] = toolSchemas()
        }
        let baseName = model.split(separator: ":").first.map(String.init) ?? model
        if baseName == "qwen3" || baseName == "qwen3-next" {
            body["think"] = false
        }

        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AgentError.http("Respuesta inválida del servidor Ollama")
        }

        var accumulated: [Int: ToolCall] = [:]

        func handleBody(_ line: String) throws -> Bool {
            guard let data = line.data(using: .utf8), !line.isEmpty else { return false }
            guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else { return false }
            if let error = chunk.error {
                throw AgentError.message(error)
            }
            if let content = chunk.message?.content, !content.isEmpty {
                onText(content)
            }
            for raw in chunk.message?.toolCalls ?? [] {
                guard let fn = raw.function, let name = fn.name, !name.isEmpty else { continue }
                let idx = raw.index ?? accumulated.count
                var call = accumulated[idx] ?? ToolCall(name: name, arguments: [:])
                call.name = name
                if let args = fn.arguments {
                    if case .string(let s) = args {
                        var prev = ""
                        if case .string(let old)? = call.arguments["_merged"] {
                            prev = old
                        }
                        call.arguments["_merged"] = .string(prev + s)
                    } else {
                        call.arguments = argsMap(args)
                    }
                }
                accumulated[idx] = call
            }
            return chunk.done == true
        }

        if http.statusCode != 200 {
            var errText = ""
            for try await line in bytes.lines {
                errText += line
            }
            throw AgentError.http("Ollama devolvió \(http.statusCode): \(errText.prefix(300))")
        }

        let debugEnv = ProcessInfo.processInfo.environment["AGENTE_DEBUG"] == "1"
        for try await line in bytes.lines {
            if debugEnv {
                FileHandle.standardError.write(Data("chatStream línea: \(line.prefix(200))\n".utf8))
            }
            if isCancelled() { throw AgentError.cancelled }
            if try handleBody(line) { break }
        }

        var results: [ToolCall] = []
        for idx in accumulated.keys.sorted() {
            var call = accumulated[idx]!
            if case .string(let s) = call.arguments["_merged"] {
                call.arguments = [:]
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let dict = obj as? [String: Any] {
                    call.arguments = dict.mapValues { JSONValue(any: $0) }
                }
            } else {
                call.arguments.removeValue(forKey: "_merged")
            }
            if !call.name.isEmpty {
                results.append(call)
            }
        }
        return results
    }

    private func argsMap(_ v: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = v { return o }
        return [:]
    }
}

// MARK: - Bucle del agente

@MainActor
enum AgentCore {
    static let maxTurns = 8

    static func runLoop(messages input: [ChatMessage],
                        client: OllamaClient,
                        model: String,
                        onText: (String) -> Void,
                        onTool: (ToolEvent) -> Void,
                        confirm: (String, [String: JSONValue]) async -> Bool,
                        isCancelled: () -> Bool) async throws -> [ChatMessage] {
        var messages = input

        for _ in 0..<maxTurns {
            if isCancelled() { return messages }

            var text = ""
            let toolCalls = try await client.chatStream(
                messages: messages,
                model: model,
                onText: { delta in
                    text += delta
                    onText(delta)
                },
                isCancelled: isCancelled
            )

            var assistant = ChatMessage(role: "assistant", content: text)
            if !toolCalls.isEmpty {
                assistant.toolCalls = toolCalls
            }
            messages.append(assistant)
            if toolCalls.isEmpty {
                return messages
            }

            for call in toolCalls {
                let name = call.name
                let args = call.arguments
                var approved = true
                if confirmTools.contains(name) {
                    approved = await confirm(name, args)
                }
                let payload: String
                if approved {
                    onTool(.start(name, args))
                    payload = await executeTool(name: name, args: args)
                    onTool(.done(name, payload))
                } else {
                    payload = jsonObjectToString([
                        "ok": false,
                        "error": "El usuario canceló esta acción. No la vuelvas a intentar; pide instrucciones alternativas.",
                    ])
                    onTool(.cancelled(name))
                }
                messages.append(ChatMessage(role: "tool", content: payload, toolName: name))
            }
        }

        onText("\n[He alcanzado el límite de acciones de este turno]\n")
        return messages
    }
}

// MARK: - Servidor / modelo

func ollamaBinaryPath() -> String? {
    let env = ProcessInfo.processInfo.environment["AGENTE_OLLAMA_BIN"]
    let candidates = [env, "/usr/local/bin/ollama", "/usr/local/lib/ollama/ollama",
                      "/opt/homebrew/bin/ollama", nil].compactMap { $0 }
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
        return c
    }
    return nil
}

@discardableResult
func spawnOllamaServer() -> Process? {
    guard let binary = ollamaBinaryPath() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["serve"]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
    process.environment = env
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        return process
    } catch {
        return nil
    }
}

@MainActor
func ensureOllamaReady(client: OllamaClient,
                       onStatus: (String) -> Void) async throws -> Process? {
    var spawned: Process? = nil
    if !(await client.alive()) {
        onStatus("Iniciando Ollama…")
        spawned = spawnOllamaServer()
        var ok = false
        for _ in 0..<120 {
            if await client.alive() { ok = true; break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !ok {
            throw AgentError.message("Ollama no arrancó en 60 segundos. ¿Está instalado en /usr/local/bin/ollama?")
        }
    }
    return spawned
}

@MainActor
func ensureModel(model: String, client: OllamaClient, onStatus: (String) -> Void) async throws {
    if await client.hasModel(model) { return }
    onStatus("Descargando \(model) (puede tardar)…")
    try await client.pull(model: model) { status in
        onStatus(status)
    }
}

// MARK: - Estado de la interfaz

struct DisplayMsg: Identifiable {
    enum Kind { case user, assistant, tool, system, error }
    let id: UUID
    var kind: Kind
    var text: String
    var toolName = ""
    var toolStatus = ""
    var toolDetail = ""
    var expanded = false

    init(kind: Kind, text: String) {
        self.id = UUID()
        self.kind = kind
        self.text = text
    }
}

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let name: String
    let argsJSON: String
    let answer: (Bool) -> Void
}

struct ModelPrompt: Identifiable {
    let id = UUID()
    let model: String
}

@MainActor
final class AgentState: ObservableObject {
    /// Catálogo ofrecido en el selector (se descargan bajo demanda).
    static let catalogue = ["llama3.2:3b", "qwen2.5:1.5b", "qwen3:1.7b", "phi4-mini", "gemma3:4b"]
    static let defaultModel = "llama3.2:3b"

    let client = OllamaClient()

    @Published var model = AgentState.defaultModel
    /// Modelos realmente instalados en Ollama (leídos de /api/tags).
    @Published var installedModels: [String] = []

    /// Selector: primero lo instalado, después el catálogo que falte.
    var modelChoices: [String] {
        var out = installedModels
        for name in AgentState.catalogue {
            let base = name.split(separator: ":").first.map(String.init) ?? name
            let yaInstalado = installedModels.contains(name)
                || (!name.contains(":") && installedModels.contains {
                    $0.split(separator: ":").first.map(String.init) == base
                })
            if !yaInstalado { out.append(name) }
        }
        return out
    }

    func isInstalled(_ name: String) -> Bool {
        if installedModels.contains(name) { return true }
        guard !name.contains(":") else { return false }
        return installedModels.contains { $0.split(separator: ":").first.map(String.init) == name }
    }

    func refreshModels() async {
        let names = (try? await client.listModels()) ?? []
        installedModels = names
        if !names.isEmpty, !model.contains(":"),
           let full = names.first(where: { $0.split(separator: ":").first.map(String.init) == model }) {
            model = full
            UserDefaults.standard.set(full, forKey: "model")
        }
        objectWillChange.send()
    }
    @Published var display: [DisplayMsg] = []
    @Published var history: [ChatMessage]
    @Published var draft = ""
    @Published var busy = false
    @Published var ready = false
    @Published var statusText = "Iniciando Ollama…"
    @Published var statusOK = false
    @Published var statusError = false
    @Published var confirmation: ConfirmationRequest?
    @Published var allowAll = false
    @Published var modelPrompt: ModelPrompt?
    @Published var revision = 0
    @Published var showVoice = false
    @Published var screen: Screen = .chat

    enum Screen { case chat, dashboard }

    private var cancelRequested = false
    private var serverProcess: Process?

    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CandyIA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var historyURL: URL {
        supportDir.appendingPathComponent("conversation.json")
    }

    private static var legacyHistoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgenteIAMac", isDirectory: true)
        return dir.appendingPathComponent("conversation.json")
    }

    init() {
        if !FileManager.default.fileExists(atPath: AgentState.historyURL.path),
           FileManager.default.fileExists(atPath: AgentState.legacyHistoryURL.path) {
            try? FileManager.default.copyItem(at: AgentState.legacyHistoryURL,
                                              to: AgentState.historyURL)
        }
        if let data = try? Data(contentsOf: AgentState.historyURL),
           let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data),
           msgs.first?.role == "system" {
            history = msgs
            for m in msgs {
                if m.role == "user", !m.content.isEmpty {
                    display.append(DisplayMsg(kind: .user, text: m.content))
                } else if m.role == "assistant", !m.content.isEmpty {
                    display.append(DisplayMsg(kind: .assistant, text: m.content))
                }
            }
        } else {
            history = [ChatMessage(role: "system", content: systemPrompt)]
        }
        if let saved = UserDefaults.standard.string(forKey: "model"),
           AgentState.catalogue.contains(saved) {
            model = saved
        }
    }

    // ---------------------------------------------------------- estado

    func setStatus(_ text: String, ok: Bool = false, error: Bool = false) {
        statusText = text
        statusOK = ok
        statusError = error
    }

    private func append(_ kind: DisplayMsg.Kind, _ text: String) {
        display.append(DisplayMsg(kind: kind, text: text))
        revision += 1
    }

    private func streamDelta(_ delta: String) {
        if let last = display.last, last.kind == .assistant {
            display[display.count - 1].text += delta
        } else {
            display.append(DisplayMsg(kind: .assistant, text: delta))
        }
        revision += 1
    }

    private func handleTool(_ event: ToolEvent) {
        switch event {
        case .start(let name, let args):
            let compact = jsonObjectToString(args.mapValues { $0.toAny() })
            var msg = DisplayMsg(kind: .tool, text: name)
            msg.toolName = name
            msg.toolStatus = "Running"
            msg.toolDetail = String(compact.prefix(600))
            display.append(msg)
            revision += 1
        case .done(let name, let payload):
            var ok = true
            var detail = ""
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (obj["ok"] as? Bool) ?? true
                detail = (obj["resultado"] as? String) ?? (obj["error"] as? String) ?? ""
            } else {
                detail = payload
            }
            if let idx = display.lastIndex(where: { $0.kind == .tool && $0.toolName == name
                && $0.toolStatus == "Running" }) {
                display[idx].toolStatus = ok ? "Done" : "Failed"
                display[idx].toolDetail = String(detail.prefix(4000))
            } else {
                var msg = DisplayMsg(kind: .tool, text: name)
                msg.toolName = name
                msg.toolStatus = ok ? "Done" : "Failed"
                msg.toolDetail = String(detail.prefix(4000))
                display.append(msg)
            }
            revision += 1
        case .cancelled(let name):
            if let idx = display.lastIndex(where: { $0.kind == .tool && $0.toolName == name
                && $0.toolStatus == "Running" }) {
                display[idx].toolStatus = "Cancelled"
                display[idx].toolDetail = "Cancelada por el usuario"
            }
            revision += 1
        }
    }

    // ---------------------------------------------------------- arranque

    func boot() {
        Task {
            ready = false
            setStatus("Iniciando Ollama…")
            SystemStats.shared.start()
            ServicesMonitor.shared.startMonitoring()
            do {
                let spawned = try await ensureOllamaReady(client: client) { text in
                    self.setStatus(text)
                }
                if spawned != nil {
                    serverProcess = spawned
                }
                try await ensureModel(model: model, client: client) { text in
                    self.setStatus(text)
                }
                await refreshModels()
                ready = true
                setStatus("Listo — \(model)", ok: true)
            } catch {
                setStatus(error.localizedDescription.prefix(90).description, error: true)
                append(.error, "ERROR: \(error.localizedDescription)")
            }
        }
    }

    func requestModelChange(_ newModel: String) {
        guard newModel != model else { return }
        modelPrompt = ModelPrompt(model: newModel)
    }

    func confirmModelChange() {
        guard let prompt = modelPrompt else { return }
        modelPrompt = nil
        model = prompt.model
        UserDefaults.standard.set(model, forKey: "model")
        boot()
    }

    func cancelModelChange() {
        modelPrompt = nil
        objectWillChange.send()
    }

    // ---------------------------------------------------------- chat

    func requestConfirm(name: String, args: [String: JSONValue]) async -> Bool {
        if allowAll { return true }
        return await withCheckedContinuation { cont in
            confirmation = ConfirmationRequest(name: name, argsJSON: JSONValue.object(args).pretty) { approved in
                self.confirmation = nil
                cont.resume(returning: approved)
            }
        }
    }

    func answerConfirm(_ approved: Bool) {
        let answer = confirmation?.answer
        confirmation = nil
        answer?(approved)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !busy, !text.isEmpty else { return }
        draft = ""
        sendText(text)
    }

    func voiceSubmit(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !busy, !clean.isEmpty else { return }
        sendText(clean)
    }

    private func sendText(_ text: String) {
        cancelRequested = false
        append(.user, text)
        history.append(ChatMessage(role: "user", content: text))
        busy = true
        runTurn()
    }

    func regenerate() {
        guard ready, !busy else { return }
        guard let lastUser = history.lastIndex(where: { $0.role == "user" }) else { return }
        history = Array(history[...lastUser])
        saveHistory()
        if let dIdx = display.lastIndex(where: { $0.kind == .user }) {
            display = Array(display[..<dIdx])
            revision += 1
        }
        cancelRequested = false
        busy = true
        runTurn()
    }

    func readAloud() {
        guard let text = display.last(where: { $0.kind == .assistant })?.text, !text.isEmpty else {
            return
        }
        VoiceManager.shared.speak(text)
    }

    private func speakLastReply() {
        guard showVoice else { return }
        let text = display.last(where: { $0.kind == .assistant })?.text ?? ""
        if text.isEmpty {
            VoiceManager.shared.startListening()
        } else {
            VoiceManager.shared.speak(text)
        }
    }

    private func runTurn() {
        Task {
            var failed = false
            do {
                let newHistory = try await AgentCore.runLoop(
                    messages: history,
                    client: client,
                    model: model,
                    onText: { delta in self.streamDelta(delta) },
                    onTool: { event in self.handleTool(event) },
                    confirm: { name, args in await self.requestConfirm(name: name, args: args) },
                    isCancelled: { self.cancelRequested }
                )
                history = newHistory
                saveHistory()
                if cancelRequested {
                    append(.system, "— detenido por el usuario —")
                }
            } catch AgentError.cancelled {
                append(.system, "— detenido por el usuario —")
            } catch {
                failed = true
                append(.error, "ERROR: \(error.localizedDescription)")
            }
            busy = false
            revision += 1
            if !failed, !cancelRequested, showVoice, confirmation == nil {
                speakLastReply()
            }
        }
    }

    func stop() {
        cancelRequested = true
        if confirmation != nil {
            answerConfirm(false)
        }
        setStatus(ready ? "Listo — \(model)" : statusText, ok: ready)
    }

    func newChat() {
        guard !busy else { return }
        history = [ChatMessage(role: "system", content: systemPrompt)]
        display = []
        revision += 1
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: AgentState.historyURL, options: .atomic)
        }
    }

    func shutdown() {
        VoiceManager.shared.stopSpeaking()
        VoiceManager.shared.stopListening()
        SystemStats.shared.stop()
        serverProcess?.terminate()
        serverProcess = nil
    }
}
