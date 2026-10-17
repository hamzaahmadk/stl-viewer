import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [ViewerWindowController] = []
    private var cascadePoint = NSPoint.zero
    private let stlType = UTType("public.standard-tesselated-geometry-format") ?? UTType(filenameExtension: "stl")

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder double-click, "Open With", drag onto the Dock icon, `open file.stl`.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openViewer(for:))
    }

    /// Launched (or Dock icon clicked) with nothing to show.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showOpenPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening files

    private func openViewer(for url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        if let existing = controllers.first(where: { $0.url == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = ViewerWindowController(url: url) { [weak self] urls in
            urls.forEach { self?.openViewer(for: $0) }
        }
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        if let window = controller.window {
            if controllers.isEmpty {
                window.center()
                cascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
            } else {
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDocument(_ sender: Any?) { showOpenPanel() }

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [stlType].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose STL files to view"
        if panel.runModal() == .OK {
            panel.urls.forEach(openViewer(for:))
        } else if controllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openViewer(for: url) }
    }

    // MARK: Default app

    @objc private func setAsDefault(_ sender: Any?) {
        guard let stlType else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: stlType) { error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error {
                    alert.alertStyle = .warning
                    alert.messageText = "STL Viewer wasn't set as the default"
                    alert.informativeText = error.localizedDescription
                } else {
                    alert.messageText = "STL Viewer is now the default for .stl files"
                    alert.informativeText = "Double-clicking an STL file in Finder will open it here."
                }
                alert.runModal()
            }
        }
    }

    // MARK: Menus

    private func buildMenus() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            return item
        }

        let app = submenu("STL Viewer")
        add(app, "About STL Viewer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Set as Default for STL Files…", #selector(setAsDefault(_:)), target: self)
        app.addItem(.separator())
        add(app, "Hide STL Viewer", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", mods: [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit STL Viewer", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open…", #selector(openDocument(_:)), "o", target: self)
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = self
        recentItem.submenu = recent
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        // The viewer commands have no target: they travel the responder chain to the key window's ViewerView.
        let view = submenu("View")
        add(view, "Zoom to Fit", #selector(ViewerView.zoomToFit(_:)), "f", mods: [])
        add(view, "Reset View", #selector(ViewerView.resetView(_:)), "0", mods: [])
        add(view, "Zoom In", #selector(ViewerView.zoomIn(_:)), "+")
        add(view, "Zoom Out", #selector(ViewerView.zoomOut(_:)), "-")
        view.addItem(.separator())
        add(view, "Front", #selector(ViewerView.viewFront(_:)), "1", mods: [])
        add(view, "Back", #selector(ViewerView.viewBack(_:)), "2", mods: [])
        add(view, "Left", #selector(ViewerView.viewLeft(_:)), "3", mods: [])
        add(view, "Right", #selector(ViewerView.viewRight(_:)), "4", mods: [])
        add(view, "Top", #selector(ViewerView.viewTop(_:)), "5", mods: [])
        add(view, "Bottom", #selector(ViewerView.viewBottom(_:)), "6", mods: [])
        view.addItem(.separator())
        add(view, "Wireframe", #selector(ViewerView.toggleWireframe(_:)), "w", mods: [])
        add(view, "Grid", #selector(ViewerView.toggleGrid(_:)), "g", mods: [])
        add(view, "Orthographic", #selector(ViewerView.toggleProjection(_:)), "p", mods: [])
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", mods: [.command, .control])

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        guard !urls.isEmpty else {
            menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for url in urls {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
            .target = NSDocumentController.shared
    }
}
