import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        buildMenu()
        showWindow()

        let argvURLs = CommandLine.arguments.dropFirst().map(URL.init(fileURLWithPath:))
        let urls = pendingOpenURLs + argvURLs
        pendingOpenURLs.removeAll()
        if let first = urls.first {
            open(url: first)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if mainWindowController == nil {
            pendingOpenURLs.append(contentsOf: urls)
        } else if let first = urls.first {
            open(url: first)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedFileType.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        mainWindowController?.saveDocument()
    }

    private func open(url: URL) {
        showWindow()
        mainWindowController?.open(url: url)
    }

    private func showWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.showWindow(nil)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit LightData", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "o"))
        fileMenu.addItem(NSMenuItem(title: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Toggle Edit Mode", action: Selector(("toggleEditModeClicked:")), keyEquivalent: "e"))
        editMenu.addItem(NSMenuItem(title: "Add Row", action: Selector(("addRowClicked:")), keyEquivalent: "n"))
        editMenu.addItem(NSMenuItem(title: "Delete Selected Rows", action: Selector(("deleteRowsClicked:")), keyEquivalent: "\u{8}"))
        editMenu.addItem(NSMenuItem(title: "Rename Column", action: Selector(("renameColumnClicked:")), keyEquivalent: "r"))
        editMenu.addItem(NSMenuItem(title: "Delete Column", action: Selector(("deleteColumnClicked:")), keyEquivalent: ""))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
