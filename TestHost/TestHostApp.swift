// MacMCP Test Host: a small app with known controls for integration tests.
//
// Open macmcp-testhost://sheet, ://alert, ://dismiss, ://rename or ://reset to change state without any clicks.
// User-visible state changes are appended to ~/Library/Application Support/MacMCPTestHost/events.jsonl so tests can
// verify what an action really did.
import SwiftUI
import WebKit

@main
struct TestHostApp: App {
    @State private var model = TestModel()

    var body: some Scene {
        Window("MacMCP Test Host", id: "main") {
            ContentView(model: model)
                .onOpenURL { url in model.open(url) }
                .frame(minWidth: 520, minHeight: 640)
        }
        .defaultSize(width: 560, height: 700)
        .commands {
            CommandMenu("Test") {
                Button("Say Hello") { model.record("menu", "Say Hello") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}

@Observable
final class TestModel {
    var name = ""
    var password = "hunter2-secret"   // a snapshot must never reveal this
    var bacon = false
    var mushroom = false
    var size = "Small"
    var status = "Nothing submitted yet."
    /// macmcp-testhost://rename retitles the Submit button, so a ref taken before reads differently after.
    var submitTitle = "Submit"
    var showSheet = false
    var showAlert = false
    var showWeb = false
    var savePanel: NSSavePanel?
    /// macmcp-testhost://interrupt arms a surprise: just after the first topping is toggled, a "session
    /// expiring" alert appears mid-task. "Sign Out" clears the form; "Stay Signed In" keeps it (eval task L11).
    var interruptArmed = false
    var showInterrupt = false
    var moveCount = 0
    var scrollToTop = 0   // bumped by reset; the list scrolls back to Item 1

    static let eventsURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacMCPTestHost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.jsonl")
    }()

    func record(_ kind: String, _ detail: String) {
        let line = (try? JSONSerialization.data(withJSONObject: ["t": Date().timeIntervalSince1970, "kind": kind, "detail": detail])) ?? Data()
        if let handle = try? FileHandle(forWritingTo: Self.eventsURL) {
            handle.seekToEndOfFile()
            handle.write(line + Data([0x0A]))
            try? handle.close()
        } else {
            try? (line + Data([0x0A])).write(to: Self.eventsURL)
        }
        if kind == "menu" { status = "Menu: \(detail)" }
    }

    @MainActor func open(_ url: URL) {
        if openRouteFixture(url) { return }
        switch url.host {
        case "web": showWeb = true
        case "save-panel":
            guard let window = NSApplication.shared.windows.first(where: { $0.title == "MacMCP Test Host" }) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Untitled"
            savePanel = panel
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.record("save-panel", response == .OK ? "save" : "cancel")
                self?.savePanel = nil
            }
        case "sheet": showSheet = true
        case "alert": showAlert = true
        case "dismiss": showSheet = false; showAlert = false; showInterrupt = false; showWeb = false; savePanel?.cancel(nil); savePanel = nil; closeRouteWindows()
        case "interrupt": interruptArmed = true
        case "rename": submitTitle = "Send Order"
        case "reset":
            name = ""; bacon = false; mushroom = false; size = "Small"; status = "Nothing submitted yet."; moveCount = 0
            password = "hunter2-secret"; scrollToTop += 1; interruptArmed = false; showInterrupt = false; submitTitle = "Submit"
        default: break
        }
        record("url", url.absoluteString)
    }

    /// Shows the armed interrupt just after the first topping is toggled: mid-task, and never while a pop-up menu
    /// is open (an alert raised during menu tracking can't be dismissed cleanly).
    @MainActor func interruptIfArmed() {
        guard interruptArmed else { return }
        interruptArmed = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.showInterrupt = true
        }
    }

    func submit() {
        let toppings = [bacon ? "bacon" : nil, mushroom ? "mushroom" : nil].compactMap { $0 }
        status = "Submitted: \(name.isEmpty ? "(no name)" : name), \(size), toppings: \(toppings.isEmpty ? "none" : toppings.joined(separator: " "))"
        record("submit", status)
    }
}

struct ContentView: View {
    @Bindable var model: TestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Order Form").font(.title2).accessibilityAddTraits(.isHeader)
            TextField("Name", text: $model.name)
                .accessibilityIdentifier("nameField")
                .onChange(of: model.name) { _, v in model.record("name", v) }
            SecureField("Password", text: $model.password)
                .accessibilityIdentifier("passwordField")
            GroupBox("Toppings") {
                HStack {
                    Toggle("Bacon", isOn: $model.bacon).onChange(of: model.bacon) { _, v in model.record("bacon", "\(v)"); model.interruptIfArmed() }
                    Toggle("Mushroom", isOn: $model.mushroom).onChange(of: model.mushroom) { _, v in model.record("mushroom", "\(v)"); model.interruptIfArmed() }
                }
            }
            Picker("Size", selection: $model.size) {
                ForEach(["Small", "Medium", "Large"], id: \.self) { Text($0) }
            }
            .onChange(of: model.size) { _, v in model.record("size", v) }
            HStack {
                Button(model.submitTitle) { model.submit() }.keyboardShortcut(.defaultAction)
                Button("Show Sheet") { model.showSheet = true }
                Button("Show Alert") { model.showAlert = true }
                Spacer()
                // Jumps sideways on every click, to simulate targets that move (like Dock icons shifting).
                Button("Move Me") {
                    model.moveCount += 1
                    model.record("move", "\(model.moveCount)")
                }
                .padding(.trailing, CGFloat((model.moveCount % 3) * 60))
            }
            Text(model.status).accessibilityIdentifier("status")
            // Drawn, not built from controls, and hidden from accessibility: only pixels (OCR) can find these
            // targets, like a canvas app, a game or a remote desktop.
            Canvas { context, size in
                for (i, label) in ["Canvas Launch", "Canvas Abort"].enumerated() {
                    let rect = CGRect(x: CGFloat(i) * size.width / 2 + 6, y: 4, width: size.width / 2 - 12, height: size.height - 8)
                    context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(i == 0 ? .green.opacity(0.35) : .red.opacity(0.35)))
                    context.draw(Text(label).font(.system(size: 15, weight: .semibold)), at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
            .frame(width: 320, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let which = location.x < 160 ? "launch" : "abort"
                model.status = "Canvas: \(which)"
                model.record("canvas", which)
            }
            .accessibilityHidden(true)
            ScrollViewReader { proxy in
                List(1...60, id: \.self) { i in
                    Text("Item \(i)")
                }
                .onChange(of: model.scrollToTop) { _, _ in proxy.scrollTo(1, anchor: .top) }
            }
            .frame(minHeight: 220)
        }
        .padding(20)
        .sheet(isPresented: $model.showSheet) {
            VStack(spacing: 16) {
                Text("Save changes before closing?").font(.headline)
                HStack {
                    Button("Cancel") { model.record("sheet", "cancel"); model.showSheet = false }
                    Button("Save") { model.record("sheet", "save"); model.showSheet = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $model.showWeb) {
            VStack {
                OverflowWebView().frame(width: 500, height: 400)
                Button("Close Web Fixture") { model.showWeb = false }
            }.padding()
        }
        .alert("Your session is about to expire", isPresented: $model.showInterrupt) {
            Button("Sign Out", role: .destructive) {
                model.record("interrupt", "sign out")
                model.name = ""; model.bacon = false; model.mushroom = false; model.size = "Small"
            }
            Button("Stay Signed In") { model.record("interrupt", "stay") }
        } message: {
            Text("For your security, you'll be signed out unless you choose to stay signed in.")
        }
        .alert("Delete everything?", isPresented: $model.showAlert) {
            Button("Cancel", role: .cancel) { model.record("alert", "cancel") }
            Button("Delete", role: .destructive) { model.record("alert", "delete") }
        }
    }
}

/// Local WebKit fixture: nested structural containers with visible overflow must not clip the text field.
struct OverflowWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        let wrappers = String(repeating: "<div role='group' style='height:0;overflow:visible'>", count: 24)
        let end = String(repeating: "</div>", count: 24)
        view.loadHTMLString("<!doctype html><html><body style='padding:30px'>" + wrappers
            + "<label>Web name<input aria-label='Web name' type='text'></label>" + end + "</body></html>", baseURL: nil)
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
