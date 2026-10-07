import AppKit
import Darwin
import Foundation

let systemPrompt = """
Eres CANDY IA, un asistente de IA que controla este Mac para automatizar tareas del usuario. \
Respondes siempre en el idioma del usuario (español por defecto), de forma breve y directa. \
Usa las herramientas disponibles para obtener información o ejecutar acciones. \
Antes de ejecutar una acción que modifique el sistema (comandos, scripts, escribir o borrar archivos), \
explica en una frase corta qué vas a hacer. Si una herramienta falla, dilo y propón una alternativa. \
No inventes resultados de herramientas: usa su salida real. Máximo 2-3 acciones por turno salvo que te pidan más. \
Cuando te pidan vigilar o monitorear algo (un servicio web, una API), usa check_service para registrarlo.
"""

let confirmTools: Set<String> = ["run_shell", "run_applescript", "write_file", "delete_file"]

let maxOutputChars = 6000
let commandTimeout: TimeInterval = 60

// MARK: - JSONValue

enum JSONValue: Codable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSON no soportado")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.toAny() }
        case .array(let a): return a.map { $0.toAny() }
        case .null: return NSNull()
        }
    }

    var pretty: String {
        let obj = toAny()
        if JSONSerialization.isValidJSONObject(obj),
           let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return String(describing: obj)
    }

    var description: String { pretty }
}

func jsonObjectToString(_ obj: Any) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        return s
    }
    return String(describing: obj)
}

// MARK: - Resultados

func clip(_ text: String, limit: Int = maxOutputChars) -> String {
    if text.count <= limit { return text }
    let idx = text.index(text.startIndex, offsetBy: limit)
    return String(text[..<idx]) + "\n… [salida truncada, \(text.count) caracteres en total]"
}

func okResult(_ text: String) -> String {
    jsonObjectToString(["ok": true, "resultado": clip(text)])
}

func failResult(_ text: String) -> String {
    jsonObjectToString(["ok": false, "error": clip(text)])
}

// MARK: - Ejecución de procesos

struct ProcessResult {
    let status: Int32
    let output: String
    let timedOut: Bool
}

private func runProcess(_ executable: String, _ arguments: [String],
                        input: String? = nil, timeout: TimeInterval = commandTimeout) async -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = outPipe

    var inPipe: Pipe?
    if input != nil {
        let p = Pipe()
        process.standardInput = p
        inPipe = p
    }

    do {
        try process.run()
    } catch {
        return ProcessResult(status: 127, output: "No se pudo ejecutar \(executable): \(error)", timedOut: false)
    }

    if let data = input?.data(using: .utf8) {
        inPipe?.fileHandleForWriting.write(data)
        inPipe?.fileHandleForWriting.closeFile()
    }

    let handle = outPipe.fileHandleForReading
    let reader = Task.detached { handle.readDataToEndOfFile() }

    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning && Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if process.isRunning {
        timedOut = true
        process.terminate()
        try? await Task.sleep(nanoseconds: 400_000_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()
    let data = await reader.value
    var output = String(data: data, encoding: .utf8) ?? ""
    if timedOut {
        output += "\n[el comando superó el tiempo límite de \(Int(timeout))s]"
    }
    return ProcessResult(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines), timedOut: timedOut)
}

func runShell(_ command: String, timeout: TimeInterval = commandTimeout) async -> ProcessResult {
    await runProcess("/bin/zsh", ["-lc", command], timeout: timeout)
}

func runAppleScript(_ script: String, timeout: TimeInterval = commandTimeout) async -> ProcessResult {
    await runProcess("/usr/bin/osascript", ["-"], input: script, timeout: timeout)
}

// MARK: - Esquemas de herramientas

func toolSchemas() -> [[String: Any]] {
    func fn(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required]]]
    }
    let strProp: (String) -> [String: Any] = { ["type": "string", "description": $0] }

    return [
        fn("system_info",
           "Obtiene información del sistema: CPU, memoria, disco, batería y versión de macOS.",
           [:], []),
        fn("list_dir",
           "Lista el contenido de una carpeta del Mac.",
           ["path": strProp("Ruta de la carpeta. Por defecto el Escritorio.")], []),
        fn("read_file",
           "Lee el contenido de un archivo de texto.",
           ["path": strProp("Ruta absoluta o relativa del archivo.")], ["path"]),
        fn("search_files",
           "Busca archivos por nombre (patrón con *) en una carpeta y sus subcarpetas.",
           ["pattern": strProp("Patrón del nombre, ej: *.pdf o informe*"),
            "directory": strProp("Carpeta donde buscar. Por defecto el Escritorio.")], ["pattern"]),
        fn("open_app",
           "Abre una aplicación o un archivo con su aplicación predeterminada.",
           ["target": strProp("Nombre de la app (ej: Safari) o ruta de un archivo/app.")], ["target"]),
        fn("open_url",
           "Abre una URL en el navegador predeterminado.",
           ["url": strProp("URL completa, ej: https://ejemplo.com")], ["url"]),
        fn("notify",
           "Muestra una notificación de macOS en pantalla.",
           ["title": strProp("Título de la notificación."),
            "message": strProp("Texto de la notificación.")], ["title", "message"]),
        fn("set_volume",
           "Ajusta el volumen de salida del Mac (0 a 100).",
           ["level": ["type": "integer", "description": "Volumen de 0 a 100"]], ["level"]),
        fn("run_shell",
           "Ejecuta un comando de terminal en el Mac. Requiere confirmación del usuario.",
           ["command": strProp("Comando de shell a ejecutar.")], ["command"]),
        fn("run_applescript",
           "Ejecuta un script de AppleScript. Requiere confirmación del usuario.",
           ["script": strProp("Código AppleScript a ejecutar.")], ["script"]),
        fn("write_file",
           "Crea o sobrescribe un archivo de texto. Requiere confirmación del usuario.",
           ["path": strProp("Ruta del archivo."),
            "content": strProp("Contenido del archivo.")], ["path", "content"]),
        fn("delete_file",
           "Mueve un archivo o carpeta a la Papelera (no lo borra definitivamente). Requiere confirmación del usuario.",
           ["path": strProp("Ruta del archivo o carpeta a eliminar.")], ["path"]),
        fn("check_service",
           "Registra (o vuelve a comprobar) un servicio web y lo monitorea. Devuelve su estado actual, latencia y uptime de los últimos 7 días. El servicio queda en el dashboard.",
           ["name": strProp("Nombre corto del servicio, ej: api pagos cr"),
            "url": strProp("URL a comprobar, ej: https://api.ejemplo.com/health")], ["name", "url"]),
        fn("list_services",
           "Lista los servicios web monitoreados con su estado y uptime de los últimos 7 días.",
           [:], []),
        fn("remove_service",
           "Deja de monitorear un servicio.",
           ["name": strProp("Nombre del servicio a dejar de monitorear.")], ["name"]),
    ]
}

// MARK: - Implementación de herramientas

func expandPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

func absPath(_ path: String) -> String {
    URL(fileURLWithPath: expandPath(path)).standardizedFileURL.path
}

func humanSize(_ bytes: Int64) -> String {
    var n = Double(bytes)
    let units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while n >= 1024 && i < units.count - 1 {
        n /= 1024
        i += 1
    }
    return i == 0 ? String(format: "%.0f %@", n, units[i]) : String(format: "%.1f %@", n, units[i])
}

func toolSystemInfo() async -> String {
    var lines: [String] = []
    lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) (x86_64)")
    var cpu = [CChar](repeating: 0, count: 256)
    var size = 256
    if sysctlbyname("machdep.cpu.brand_string", &cpu, &size, nil, 0) == 0 {
        lines.append("CPU: " + String(cString: cpu))
    }
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) {
        if let total = attrs[.systemSize] as? Int64, let free = attrs[.systemFreeSize] as? Int64 {
            lines.append("Disco: \(humanSize(free)) libres de \(humanSize(total))")
        }
    }
    let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    lines.append(String(format: "RAM: %.1f GB", ram))
    var load = [0.0, 0.0, 0.0]
    if getloadavg(&load, 3) == 3 {
        lines.append(String(format: "Carga CPU (1/5/15 min): %.1f / %.1f / %.1f", load[0], load[1], load[2]))
    }
    let batt = await runProcess("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
    if let first = batt.output.split(separator: "\n").first, first.contains("%") {
        lines.append("Batería: " + first.trimmingCharacters(in: .whitespaces))
    }
    return okResult(lines.joined(separator: "\n"))
}

func toolListDir(_ args: [String: JSONValue]) -> String {
    let path = absPath(args["path"]?.stringValue ?? "~/Desktop")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return failResult("No existe la carpeta: \(path)")
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    var entries: [(String, Bool)] = []
    for name in names {
        var isD: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isD)
        entries.append((name, isD.boolValue))
    }
    entries.sort { a, b in
        if a.1 != b.1 { return a.1 }
        return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
    }
    var lines: [String] = []
    for (name, isD) in entries.prefix(200) {
        let full = path + "/" + name
        if isD {
            lines.append("[DIR]  \(name)")
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                  let size = attrs[.size] as? Int64 {
            lines.append("       \(name)  (\(humanSize(size)))")
        } else {
            lines.append("       \(name)")
        }
    }
    if entries.count > 200 {
        lines.append("… y \(entries.count - 200) elementos más")
    }
    if lines.isEmpty {
        return okResult("La carpeta \(path) está vacía.")
    }
    return okResult("Contenido de \(path) (\(entries.count) elementos):\n" + lines.joined(separator: "\n"))
}

func toolReadFile(_ args: [String: JSONValue]) -> String {
    guard let rawPath = args["path"]?.stringValue else { return failResult("Falta la ruta.") }
    let path = absPath(rawPath)
    guard FileManager.default.fileExists(atPath: path) else { return failResult("No existe el archivo: \(path)") }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int64, size > 1_000_000 {
        return failResult("El archivo supera 1 MB; pide un archivo más pequeño o una carpeta.")
    }
    guard let data = FileManager.default.contents(atPath: path) else { return failResult("No se pudo leer: \(path)") }
    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    return okResult(text)
}

func toolSearchFiles(_ args: [String: JSONValue]) -> String {
    let pattern = args["pattern"]?.stringValue ?? "*"
    let root = absPath(args["directory"]?.stringValue ?? "~/Desktop")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
        return failResult("No existe la carpeta: \(root)")
    }
    let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern)
        .replacingOccurrences(of: "\\*", with: ".*")
        .replacingOccurrences(of: "\\?", with: "."),
                                         options: [.caseInsensitive])
    func matches(_ name: String) -> Bool {
        guard let regex = regex else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }
    var hits: [String] = []
    let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                                                    options: [.skipsHiddenFiles])
    while let item = enumerator?.nextObject() as? URL {
        if hits.count >= 100 { break }
        if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
        if matches(item.lastPathComponent) {
            hits.append(item.path)
        }
    }
    if hits.isEmpty {
        return okResult("No se encontraron archivos con el patrón '\(pattern)' en \(root).")
    }
    return okResult("\(hits.count) resultado(s) para '\(pattern)':\n" + hits.joined(separator: "\n"))
}

func toolOpenApp(_ args: [String: JSONValue]) async -> String {
    guard let target = args["target"]?.stringValue, !target.trimmingCharacters(in: .whitespaces).isEmpty else {
        return failResult("Falta el nombre de la aplicación.")
    }
    let expanded = expandPath(target)
    var result: ProcessResult
    if FileManager.default.fileExists(atPath: expanded) {
        result = await runProcess("/usr/bin/open", [absPath(expanded)], timeout: 30)
    } else {
        result = await runProcess("/usr/bin/open", ["-a", target], timeout: 30)
    }
    if result.status != 0 {
        return failResult("No se pudo abrir '\(target)'. \(result.output)")
    }
    return okResult("Abierto: \(target)")
}

func toolOpenURL(_ args: [String: JSONValue]) -> String {
    guard var url = args["url"]?.stringValue else { return failResult("Falta la URL.") }
    url = url.trimmingCharacters(in: .whitespaces)
    if !url.hasPrefix("http://"), !url.hasPrefix("https://") {
        url = "https://" + url
    }
    guard let u = URL(string: url) else { return failResult("URL inválida: \(url)") }
    if NSWorkspace.shared.open(u) {
        return okResult("URL abierta en el navegador: \(url)")
    }
    return failResult("No se pudo abrir: \(url)")
}

func toolNotify(_ args: [String: JSONValue]) async -> String {
    let title = (args["title"]?.stringValue ?? "Agente").replacingOccurrences(of: "\"", with: "'")
    let message = (args["message"]?.stringValue ?? "").replacingOccurrences(of: "\"", with: "'")
    let r = await runProcess("/usr/bin/osascript", ["-e",
        "display notification \"\(message)\" with title \"\(title)\""], timeout: 15)
    return r.status == 0 ? okResult("Notificación enviada.") : failResult(r.output)
}

func toolSetVolume(_ args: [String: JSONValue]) async -> String {
    guard let level = args["level"]?.intValue else {
        return failResult("El volumen debe ser un número entre 0 y 100.")
    }
    let clamped = max(0, min(100, level))
    let r = await runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(clamped)"], timeout: 15)
    return r.status == 0 ? okResult("Volumen ajustado a \(clamped)%.") : failResult(r.output)
}

func toolRunShell(_ args: [String: JSONValue]) async -> String {
    guard let command = args["command"]?.stringValue, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
        return failResult("Comando vacío.")
    }
    let r = await runShell(command)
    let header = "Comando: \(command)\nCódigo de salida: \(r.status)\n"
    return r.status == 0 ? okResult(header + r.output) : failResult(header + r.output)
}

func toolRunAppleScript(_ args: [String: JSONValue]) async -> String {
    guard let script = args["script"]?.stringValue, !script.trimmingCharacters(in: .whitespaces).isEmpty else {
        return failResult("Script vacío.")
    }
    let r = await runAppleScript(script)
    return r.status == 0 ? okResult(r.output.isEmpty ? "(sin salida)" : r.output) : failResult(r.output)
}

func toolWriteFile(_ args: [String: JSONValue]) -> String {
    guard let rawPath = args["path"]?.stringValue else { return failResult("Falta la ruta.") }
    let content = args["content"]?.stringValue ?? ""
    let path = absPath(rawPath)
    let dir = (path as NSString).deletingLastPathComponent
    do {
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return okResult("Archivo escrito: \(path) (\(content.count) caracteres)")
    } catch {
        return failResult("\(error)")
    }
}

func toolDeleteFile(_ args: [String: JSONValue]) async -> String {
    guard let rawPath = args["path"]?.stringValue else { return failResult("Falta la ruta.") }
    let path = absPath(rawPath)
    guard FileManager.default.fileExists(atPath: path) else { return failResult("No existe: \(path)") }
    let r = await runAppleScript("tell application \"Finder\" to delete (POSIX file \"\(path)\" as alias)")
    if r.status == 0 {
        return okResult("Movido a la Papelera: \(path)")
    }
    let trash = NSHomeDirectory() + "/.Trash/"
    let dest = trash + "\(Int(Date().timeIntervalSince1970))_" + ((path as NSString).lastPathComponent)
    do {
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return okResult("Movido a la Papelera: \(path)")
    } catch {
        return failResult("No se pudo mover a la Papelera: \(error)")
    }
}

func executeTool(name: String, args: [String: JSONValue]) async -> String {
    switch name {
    case "system_info": return await toolSystemInfo()
    case "list_dir": return toolListDir(args)
    case "read_file": return toolReadFile(args)
    case "search_files": return toolSearchFiles(args)
    case "open_app": return await toolOpenApp(args)
    case "open_url": return toolOpenURL(args)
    case "notify": return await toolNotify(args)
    case "set_volume": return await toolSetVolume(args)
    case "run_shell": return await toolRunShell(args)
    case "run_applescript": return await toolRunAppleScript(args)
    case "write_file": return toolWriteFile(args)
    case "delete_file": return await toolDeleteFile(args)
    case "check_service": return await toolCheckService(args)
    case "list_services": return await toolListServices()
    case "remove_service": return await toolRemoveService(args)
    default: return failResult("Herramienta desconocida: \(name)")
    }
}

// MARK: - Servicios monitoreados

@MainActor
func toolCheckService(_ args: [String: JSONValue]) async -> String {
    guard let name = args["name"]?.stringValue, !name.isEmpty else {
        return failResult("Falta el nombre del servicio.")
    }
    guard let url = args["url"]?.stringValue, !url.isEmpty else {
        return failResult("Falta la URL del servicio.")
    }
    let svc = await ServicesMonitor.shared.register(name: name, url: url)
    let check = ServicesMonitor.shared.lastCheck(svc)
    let up = ServicesMonitor.shared.uptime(svc)
    let status = check?.ok == true ? "arriba (up)" : "caído (down)"
    let latency = check.map { "\($0.ms) ms" } ?? "s/d"
    return okResult("""
    Servicio **\(svc.name)**: \(status).
    URL: \(svc.url)
    Latencia actual: \(latency)
    Disponibilidad (7 días): \(String(format: "%.2f", up))%
    """)
}

@MainActor
func toolListServices() -> String {
    let list = ServicesMonitor.shared.services
    guard !list.isEmpty else { return okResult("No hay servicios monitoreados todavía.") }
    let lines = list.map { svc -> String in
        let check = ServicesMonitor.shared.lastCheck(svc)
        let state = check?.ok == true ? "up" : "down"
        let up = ServicesMonitor.shared.uptime(svc)
        let lat = check.map { "\($0.ms) ms" } ?? "s/d"
        return "- \(svc.name) [\(state)] latencia \(lat) uptime7d \(String(format: "%.2f", up))% — \(svc.url)"
    }
    return okResult(lines.joined(separator: "\n"))
}

@MainActor
func toolRemoveService(_ args: [String: JSONValue]) -> String {
    guard let name = args["name"]?.stringValue else { return failResult("Falta el nombre.") }
    if ServicesMonitor.shared.remove(name: name) {
        return okResult("Servicio \(name) eliminado del monitoreo.")
    }
    return failResult("No encontré el servicio: \(name)")
}
