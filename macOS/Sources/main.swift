import AppKit
import SwiftUI

func buildMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem(title: "CANDY IA", action: nil, keyEquivalent: "")
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(withTitle: "Acerca de CANDY IA",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Salir de CANDY IA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Editar")
    editItem.submenu = editMenu
    editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Ventana")
    windowItem.submenu = windowMenu
    windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    windowMenu.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var agent: AgentState?
    var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let agent = AgentState()
        self.agent = agent

        let hosting = NSHostingController(rootView: ContentView(agent: agent))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CANDY IA"
        window.setContentSize(NSSize(width: 980, height: 700))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        menuBar = MenuBarController(agent: agent) { [weak self] screen in
            agent.screen = screen
            guard let self, let win = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // prueba interna: cerrar la ventana no debe matar la app
        if ProcessInfo.processInfo.environment["CANDY_TEST_CLOSE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                NSLog("[test] cerrando ventana")
                self?.window?.performClose(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        agent?.shutdown()
    }
}

if CommandLine.arguments.contains("--selftest") {
    Task { @MainActor in
        let code = await SelfTest.runAll()
        exit(code)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
