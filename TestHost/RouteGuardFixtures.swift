import AppKit
import UniformTypeIdentifiers

extension TestModel {
    /// Security fixtures are controlled only by the integration harness, outside MacMCP's tool routes.
    @MainActor func openRouteFixture(_ url: URL) -> Bool {
        switch url.host {
        case "route-menu":
            guard let bar = NSApp.mainMenu else { return true }
            if let old = bar.items.first(where: { $0.title == "Route Fixtures" }) { bar.removeItem(old) }
            let menu = NSMenu(title: "Route Fixtures")
            let paste = NSMenuItem(title: "Pegar", action: #selector(RouteFixtureTarget.routePaste), keyEquivalent: "v")
            paste.target = RouteFixtureTarget.shared
            paste.keyEquivalentModifierMask = [.command]
            menu.addItem(paste)
            let parent = NSMenuItem(title: "Route Fixtures", action: nil, keyEquivalent: "")
            parent.submenu = menu
            bar.addItem(parent)
        case "route-unsafe-save", "route-app-chooser":
            guard let window = NSApp.windows.first(where: { $0.title == "MacMCP Test Host" }) else { return true }
            let panel: NSSavePanel
            if url.host == "route-app-chooser" {
                let chooser = NSOpenPanel()
                chooser.allowedContentTypes = [.applicationBundle]
                chooser.directoryURL = URL(fileURLWithPath: "/Applications/Utilities")
                chooser.prompt = "Add"
                panel = chooser
            } else {
                panel = NSSavePanel()
                panel.nameFieldStringValue = "payload.command"
            }
            savePanel = panel
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.record("route-panel", response == .OK ? "commit" : "cancel")
                self?.savePanel = nil
            }
        case "route-floating":
            // Like the Fonts panel: a utility panel (AXFloatingWindow) with a plain field.
            closeRouteWindows()
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 90),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Route Floating Panel"
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.contentView = routeField("routeFloatingField", model: self)
            panel.center()
            RouteFixtureWindows.windows = [panel]
            panel.makeKeyAndOrderFront(nil)
        case "route-sheet":
            // An ordinary sheet (a rename or login sheet): a field, no file browser.
            closeRouteWindows()
            guard let window = NSApp.windows.first(where: { $0.title == "MacMCP Test Host" }) else { return true }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.contentView = routeField("routeSheetField", model: self)
            RouteFixtureWindows.windows = [sheet]
            window.beginSheet(sheet) { _ in }
        case "route-close": closeRouteWindows()
        default: return false
        }
        return true
    }

    /// Closes the floating panel and the plain sheet, and takes the Route Fixtures menu away: its ⌘V item would
    /// otherwise answer every later paste.
    @MainActor func closeRouteWindows() {
        if let bar = NSApp.mainMenu, let old = bar.items.first(where: { $0.title == "Route Fixtures" }) { bar.removeItem(old) }
        for window in RouteFixtureWindows.windows {
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        }
        RouteFixtureWindows.windows = []
    }

    /// A view with one text field that logs its text to the events file as it changes.
    @MainActor private func routeField(_ id: String, model: TestModel) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 90))
        let field = NSTextField(frame: NSRect(x: 20, y: 30, width: 220, height: 24))
        field.setAccessibilityIdentifier(id)
        field.setAccessibilityLabel(id)
        let log = RouteFieldLog(model: model, id: id)
        field.delegate = log
        RouteFixtureWindows.logs.append(log)
        view.addSubview(field)
        return view
    }
}

@MainActor private enum RouteFixtureWindows {
    static var windows: [NSWindow] = []
    static var logs: [RouteFieldLog] = []
}

private final class RouteFieldLog: NSObject, NSTextFieldDelegate {
    let model: TestModel
    let id: String
    init(model: TestModel, id: String) { self.model = model; self.id = id }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        model.record(id, field.stringValue)
    }
}

private final class RouteFixtureTarget: NSObject {
    @MainActor static let shared = RouteFixtureTarget()
    @objc func routePaste() { NSPasteboard.general.string(forType: .string).map { NSLog("route paste: %d characters", $0.count) } }
}
