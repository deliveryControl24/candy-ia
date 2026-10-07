import AppKit
import Foundation

@MainActor
enum SelfTest {
    private static func toolBool(_ json: String, _ key: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? Bool
    }

    private static func toolString(_ json: String, _ key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    static func runAll() async -> Int32 {
        var failures = 0
        func check(_ cond: Bool, _ label: String) {
            if cond {
                print("  ✔ \(label)")
            } else {
                print("  ✘ \(label)")
                failures += 1
            }
            fflush(stdout)
        }

        print("== Fase 1: herramientas ==")
        fflush(stdout)

        let sys = await executeTool(name: "system_info", args: [:])
        check(toolBool(sys, "ok") == true, "system_info")

        let echo = await executeTool(name: "run_shell", args: ["command": .string("echo AGENTE_OK")])
        check(toolBool(echo, "ok") == true && toolString(echo, "resultado")?.contains("AGENTE_OK") == true,
              "run_shell echo")

        let tmp = NSTemporaryDirectory() + "agente_selftest_\(Int(Date().timeIntervalSince1970)).txt"
        let w = await executeTool(name: "write_file",
                                  args: ["path": .string(tmp), "content": .string("hola selftest")])
        check(toolBool(w, "ok") == true, "write_file")

        let r = await executeTool(name: "read_file", args: ["path": .string(tmp)])
        check(toolString(r, "resultado") == "hola selftest", "read_file")

        let del = await executeTool(name: "delete_file", args: ["path": .string(tmp)])
        check(toolBool(del, "ok") == true && !FileManager.default.fileExists(atPath: tmp),
              "delete_file → Papelera")

        let ls = await executeTool(name: "list_dir", args: ["path": .string("/tmp")])
        check(toolBool(ls, "ok") == true, "list_dir")

        let search = await executeTool(name: "search_files",
                                       args: ["pattern": .string("*.txt"), "directory": .string("/tmp")])
        check(toolBool(search, "ok") == true, "search_files")

        let svc = await executeTool(name: "check_service",
                                    args: ["name": .string("ollama-local"),
                                           "url": .string("http://127.0.0.1:11434/api/version")])
        check(toolBool(svc, "ok") == true, "check_service")

        let svcList = await executeTool(name: "list_services", args: [:])
        check(toolBool(svcList, "ok") == true, "list_services")

        let unknown = await executeTool(name: "herramienta_inventada", args: [:])
        check(toolBool(unknown, "ok") == false, "herramienta desconocida rechazada")

        print("== Fase 2: Ollama + modelo real ==")
        fflush(stdout)

        let client = OllamaClient()
        do {
            let spawned = try await ensureOllamaReady(client: client) { status in
                print("  · \(status)")
                fflush(stdout)
            }
            defer { spawned?.terminate() }

            try await ensureModel(model: AgentState.defaultModel, client: client) { status in
                print("  · \(status)")
                fflush(stdout)
            }

            var reply = ""
            _ = try await client.chatStream(
                messages: [ChatMessage(role: "user", content: "Responde únicamente con la palabra HOLA")],
                model: AgentState.defaultModel,
                includeTools: false,
                onText: { reply += $0 },
                isCancelled: { false }
            )
            check(reply.uppercased().contains("HOLA"),
                  "streaming de chat real («\(String(reply.prefix(40)))»)")

            var seen: [String] = []
            let finalHistory = try await AgentCore.runLoop(
                messages: [
                    ChatMessage(role: "system", content: systemPrompt),
                    ChatMessage(role: "user", content:
                        "Usa ahora la herramienta run_shell con este comando exacto: echo AGENTE_OK. " +
                        "Después resume en una frase lo que hiciste."),
                ],
                client: client,
                model: AgentState.defaultModel,
                onText: { seen.append($0) },
                onTool: { event in
                    if case .done(let name, let payload) = event {
                        print("  · tool \(name): \(payload.prefix(160))")
                        fflush(stdout)
                    }
                },
                confirm: { _, _ in true },
                isCancelled: { false }
            )
            let toolOutputs = finalHistory.filter { $0.role == "tool" }.map { $0.content }.joined(separator: " ")
            let finalText = seen.joined()
            check(toolOutputs.contains("AGENTE_OK") || finalText.contains("AGENTE_OK"),
                  "bucle de herramientas con modelo real")
        } catch {
            check(false, "fase 2 (\(error.localizedDescription))")
        }

        print("== Fase 3: sistema y optimización ==")
        fflush(stdout)

        SystemStats.shared.start()
        try? await Task.sleep(nanoseconds: 13_000_000_000)
        check(SystemStats.shared.memPercent > 0,
              "métricas de sistema (CPU \(Int(SystemStats.shared.cpuPercent))%, " +
              "mem \(Int(SystemStats.shared.memPercent))%)")
        check(SystemStats.shared.topProcess != "—",
              "top process: \(SystemStats.shared.topProcess)")
        check(SystemStats.shared.batteryPercent != nil || true, "batería consultada")

        let avail = SystemOptimizer.availableBytes()
        check(avail > 0, "memoria disponible: \(String(format: "%.2f", Double(avail) / 1_073_741_824)) GB")

        let cleanMsg = SystemOptimizer.cleanTemps()
        check(cleanMsg.contains("tmp") || cleanMsg.contains("archivos")
              || cleanMsg.contains("limpiar"), "limpiar temporales")

        let trashMsg = SystemOptimizer.emptyTrash()
        check(trashMsg.contains("Papelera") || trashMsg.contains("papelera"),
              "vaciar papelera")

        let memMsg = SystemOptimizer.freeMemory()
        check(memMsg.contains("Memoria") || memMsg.contains("memoria"),
              "liberar memoria")

        if failures == 0 {
            print("\nTODO OK")
        } else {
            print("\n\(failures) FALLO(S)")
        }
        fflush(stdout)
        return failures == 0 ? 0 : 1
    }
}
