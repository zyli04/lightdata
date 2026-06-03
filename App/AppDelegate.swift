import AppKit
import LightDataCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [MainWindowController] = []
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.activate(ignoringOtherApps: true)
        buildMenu()

        let argvURLs = CommandLine.arguments.dropFirst().map(URL.init(fileURLWithPath:))
        let urls = pendingOpenURLs + argvURLs
        pendingOpenURLs.removeAll()
        if urls.isEmpty {
            showWindow()
        } else {
            urls.forEach(open(url:))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching {
            pendingOpenURLs.append(contentsOf: urls)
        } else {
            urls.forEach(open(url:))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedFileType.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            panel.urls.forEach(open(url:))
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        activeWindowController()?.saveDocument()
    }

    @objc func newTab(_ sender: Any?) {
        let baseWindow = activeWindowController()?.window ?? windowControllers.first?.window
        let controller = makeWindowController(tabbedTo: baseWindow)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    @objc func selectTab1(_ sender: Any?) { selectTab(at: 0) }
    @objc func selectTab2(_ sender: Any?) { selectTab(at: 1) }
    @objc func selectTab3(_ sender: Any?) { selectTab(at: 2) }
    @objc func selectTab4(_ sender: Any?) { selectTab(at: 3) }
    @objc func selectTab5(_ sender: Any?) { selectTab(at: 4) }
    @objc func selectTab6(_ sender: Any?) { selectTab(at: 5) }
    @objc func selectTab7(_ sender: Any?) { selectTab(at: 6) }
    @objc func selectTab8(_ sender: Any?) { selectTab(at: 7) }
    @objc func selectTab9(_ sender: Any?) { selectTab(at: 8) }

    func openFileInTab(url: URL) {
        open(url: url)
    }

    private func open(url: URL) {
        let controller: MainWindowController
        if let emptyController = reusableEmptyWindowController() {
            controller = emptyController
        } else {
            let baseWindow = activeWindowController()?.window ?? windowControllers.first?.window
            controller = makeWindowController(tabbedTo: baseWindow)
        }

        controller.showWindow(nil)
        controller.open(url: url)
        controller.window?.makeKeyAndOrderFront(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func showWindow() {
        let controller = activeWindowController() ?? windowControllers.first ?? makeWindowController(tabbedTo: nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindowController(tabbedTo baseWindow: NSWindow?) -> MainWindowController {
        let controller = MainWindowController()
        controller.onClose = { [weak self] closedController in
            self?.windowControllers.removeAll { $0 === closedController }
        }
        windowControllers.append(controller)

        if let baseWindow,
           let newWindow = controller.window,
           baseWindow !== newWindow {
            baseWindow.addTabbedWindow(newWindow, ordered: .above)
            if baseWindow.tabGroup?.isTabBarVisible == false {
                baseWindow.toggleTabBar(nil)
            }
        }

        return controller
    }

    private func activeWindowController() -> MainWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? MainWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? MainWindowController {
            return controller
        }
        return windowControllers.last
    }

    private func selectTab(at index: Int) {
        guard let window = activeWindowController()?.window ?? windowControllers.last?.window,
              let tabGroup = window.tabGroup,
              tabGroup.windows.indices.contains(index) else {
            return
        }
        let selectedWindow = tabGroup.windows[index]
        tabGroup.selectedWindow = selectedWindow
        selectedWindow.makeKeyAndOrderFront(nil)
    }

    private func reusableEmptyWindowController() -> MainWindowController? {
        if let controller = activeWindowController(),
           !controller.hasLoadedDocument {
            return controller
        }

        guard windowControllers.count == 1,
              let controller = windowControllers.first,
              !controller.hasLoadedDocument else {
            return nil
        }
        return controller
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About LightData", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: nil, keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide LightData", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit LightData", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)
        let openItem = NSMenuItem(title: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.addItem(NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: ""))
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(title: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        fileMenu.addItem(NSMenuItem(title: "Save As...", action: nil, keyEquivalent: "S"))
        fileMenu.addItem(NSMenuItem(title: "Export...", action: nil, keyEquivalent: "e"))
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
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Edit Cell", action: Selector(("editSelectedCellClicked:")), keyEquivalent: "\r"))
        editMenu.addItem(NSMenuItem(title: "Toggle Edit Mode", action: Selector(("toggleEditModeClicked:")), keyEquivalent: "e"))
        editMenu.addItem(NSMenuItem(title: "Add Row", action: Selector(("addRowClicked:")), keyEquivalent: "n"))
        editMenu.addItem(NSMenuItem(title: "Delete Selected Rows", action: Selector(("deleteRowsClicked:")), keyEquivalent: "\u{8}"))
        editMenu.addItem(NSMenuItem(title: "Rename Column", action: Selector(("renameColumnClicked:")), keyEquivalent: "r"))
        editMenu.addItem(NSMenuItem(title: "Delete Column", action: Selector(("deleteColumnClicked:")), keyEquivalent: ""))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Show/Hide Filter", action: Selector(("toggleFilterPanelClicked:")), keyEquivalent: "f"))
        let typesItem = NSMenuItem(title: "Types On/Off", action: Selector(("toggleTypesClicked:")), keyEquivalent: "t")
        typesItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(typesItem)
        viewMenu.addItem(NSMenuItem(title: "Show File Info", action: Selector(("showFileInfoClicked:")), keyEquivalent: "i"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let dataItem = NSMenuItem()
        let dataMenu = NSMenu(title: "Data")
        dataMenu.addItem(NSMenuItem(title: "Clear Sort", action: Selector(("clearSortClicked:")), keyEquivalent: "0"))
        dataMenu.addItem(NSMenuItem(title: "Clear Filter", action: Selector(("clearFilterClicked:")), keyEquivalent: "k"))
        dataMenu.addItem(NSMenuItem(title: "Reload File", action: Selector(("reloadFileClicked:")), keyEquivalent: "r"))
        dataItem.submenu = dataMenu
        mainMenu.addItem(dataItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: ""))
        let previousTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t")
        previousTabItem.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(previousTabItem)
        let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
        nextTabItem.keyEquivalentModifierMask = [.control]
        windowMenu.addItem(nextTabItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 1", action: #selector(selectTab1(_:)), key: "1"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 2", action: #selector(selectTab2(_:)), key: "2"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 3", action: #selector(selectTab3(_:)), key: "3"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 4", action: #selector(selectTab4(_:)), key: "4"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 5", action: #selector(selectTab5(_:)), key: "5"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 6", action: #selector(selectTab6(_:)), key: "6"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 7", action: #selector(selectTab7(_:)), key: "7"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 8", action: #selector(selectTab8(_:)), key: "8"))
        windowMenu.addItem(selectTabMenuItem(title: "Select Tab 9", action: #selector(selectTab9(_:)), key: "9"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "GitHub Repository", action: #selector(openGitHubRepository(_:)), keyEquivalent: ""))
        helpMenu.addItem(NSMenuItem(title: "Report Issue", action: #selector(reportIssue(_:)), keyEquivalent: ""))
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openGitHubRepository(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/zyli04/lightdata")!)
    }

    @objc private func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/zyli04/lightdata/issues")!)
    }

    private func selectTabMenuItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
