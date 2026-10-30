import AppKit
import Carbon
import MacMCPCore

@MainActor
final class AgentIndicator: NSObject {
    private let controls: PersonControl
    private let hidden: Bool
    private var item: NSStatusItem?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastDisplay: String?

    init(controls: PersonControl, arguments: [String]) {
        self.controls = controls
        hidden = arguments.contains("--hide-indicator")
        super.init()
        do {
            try register(PersonControl.hotkey(arguments: arguments))
        } catch {
            controls.pause(source: "hotkey registration failure: \(error)")
        }
        if !hidden {
            Task { [weak self] in
                while let self {
                    let lock = await ActionLock.shared.status
                    let lease = await LeaseStore.currentAsync()
                    let state = AgentPause.shared.status
                    let label = lock.holder ?? lease?.holder ?? state.active ?? state.recent
                    update(paused: state.paused, label: label)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private func register(_ key: KeySpec) throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x4D435050, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<AgentIndicator>.fromOpaque(context).takeUnretainedValue().stop()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { throw ActionError("Could not install pause hotkey handler (\(installed))") }
        var modifiers: UInt32 = 0
        if key.flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if key.flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if key.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if key.flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        let result = RegisterEventHotKey(UInt32(key.key), modifiers, EventHotKeyID(signature: 0x4D435050, id: 1),
                                         GetApplicationEventTarget(), 0, &hotkey)
        guard result == noErr else { throw ActionError("Pause hotkey unavailable or already registered (\(result))") }
    }

    private func update(paused: Bool, label: String?) {
        guard paused || label != nil else {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            lastDisplay = nil
            return
        }
        let name = label.map {
            let prefix = String(decoding: $0.utf8.prefix(256), as: UTF8.self)
            return String(prefix.filter { !$0.isNewline && !$0.isControl }.prefix(48))
        }
        let display = paused ? "MacMCP: Paused" : "Agent driving: \(name ?? "agent")"
        let menuState = display + "\n" + (name ?? "")
        guard menuState != lastDisplay else { return }
        lastDisplay = menuState
        let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        item.button?.title = display
        item.button?.toolTip = display
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let name { menu.addItem(withTitle: name, action: nil, keyEquivalent: "").isEnabled = false }
        let stop = menu.addItem(withTitle: "Stop and pause agents", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        if paused {
            menu.addItem(withTitle: "Paused — run `mac-mcp resume` in Terminal to resume", action: nil, keyEquivalent: "").isEnabled = false
        }
        let log = menu.addItem(withTitle: "Open log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        item.menu = menu
    }

    private func stop() { controls.pause(source: "global hotkey") }
    @objc private func stopFromMenu() { controls.pause(source: "status menu") }
    @objc private func openLog() {
        Task {
            _ = try? await NSWorkspace.shared.open(URL(fileURLWithPath: Paths.agentLog), configuration: .init())
        }
    }
}

private extension Character {
    var isControl: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}
