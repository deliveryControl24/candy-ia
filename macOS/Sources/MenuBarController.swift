import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let agent: AgentState
    private let onOpen: (AgentState.Screen) -> Void
    private var cpuItem: NSMenuItem!
    private var memItem: NSMenuItem!
    private var timer: Timer?

    init(agent: AgentState, onOpen: @escaping (AgentState.Screen) -> Void) {
        self.agent = agent
        self.onOpen = onOpen
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            if let icon = NSImage(named: "CandyIA") {
                icon.isTemplate = false
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.imagePosition = .imageOnly
            } else if let sym = NSImage(systemSymbolName: "sparkles",
                                        accessibilityDescription: "CANDY IA") {
                sym.isTemplate = true
                sym.size = NSSize(width: 16, height: 16)
                button.image = sym
                button.imagePosition = .imageOnly
            } else {
                button.title = "C"
            }
            button.toolTip = "CANDY IA"
        }
        buildMenu()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMetrics() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateMetrics()
    }

    deinit {
        timer?.invalidate()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "CANDY IA", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        menu.addItem(makeItem("Abrir chat", #selector(openChat), "1"))
        menu.addItem(makeItem("Modo voz", #selector(openVoice), "2"))
        menu.addItem(makeItem("Dashboard", #selector(openDashboard), "3"))
        menu.addItem(.separator())

        cpuItem = NSMenuItem(title: "CPU —", action: nil, keyEquivalent: "")
        cpuItem.isEnabled = false
        menu.addItem(cpuItem)
        memItem = NSMenuItem(title: "Memoria —", action: nil, keyEquivalent: "")
        memItem.isEnabled = false
        menu.addItem(memItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("⚡ Liberar memoria", #selector(freeMemory), ""))
        menu.addItem(makeItem("🧹 Limpiar temporales", #selector(cleanTemps), ""))
        menu.addItem(makeItem("🗑 Vaciar Papelera", #selector(emptyTrash), ""))
        menu.addItem(.separator())

        menu.addItem(makeItem("Nueva conversación", #selector(newChat), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Salir de CANDY IA", #selector(quit), "q"))

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateMetrics() {
        let stats = SystemStats.shared
        cpuItem.title = String(format: "CPU  %.0f%%", stats.cpuPercent)
        cpuItem.isEnabled = false
        let used = stats.memUsedGB
        let total = stats.memTotalGB
        if total > 0 {
            memItem.title = String(format: "Memoria  %.0f%% · %.1f / %.0f GB",
                                   stats.memPercent, used, total)
        } else {
            memItem.title = String(format: "Memoria  %.0f%%", stats.memPercent)
        }
        memItem.isEnabled = false
    }

    // ------------------------------------------------------------- abrir

    @objc private func openChat() {
        onOpen(.chat)
    }

    @objc private func openVoice() {
        agent.showVoice = true
        onOpen(.chat)
    }

    @objc private func openDashboard() {
        onOpen(.dashboard)
    }

    @objc private func newChat() {
        agent.newChat()
        onOpen(.chat)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // ------------------------------------------------------------- optimizar

    @objc private func freeMemory() {
        runOptimizer { SystemOptimizer.freeMemory() }
    }

    @objc private func cleanTemps() {
        runOptimizer { SystemOptimizer.cleanTemps() }
    }

    @objc private func emptyTrash() {
        runOptimizer { SystemOptimizer.emptyTrash() }
    }

    private func runOptimizer(_ work: @escaping @MainActor () -> String) {
        Task { @MainActor in
            let message = work()
            _ = await toolNotify([
                "title": .string("CANDY IA"),
                "message": .string(message),
            ])
        }
    }
}
