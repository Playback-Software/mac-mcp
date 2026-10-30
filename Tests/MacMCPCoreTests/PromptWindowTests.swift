import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

/// Which windows of the processes that show prompts and ordinary windows alike (sharingd, AirDropUI, the screen-sharing
/// agents, loginwindow, Software Update) block input: decided by window level and accessibility role, not size alone,
/// and counted as a prompt when in doubt.
@Suite struct PromptWindowTests {
    typealias Traits = WindowServer.WindowTraits
    let display = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    let ordinary = Traits(role: "AXWindow", subrole: "AXStandardWindow", hasCloseButton: true)

    func window(_ w: CGFloat, _ h: CGFloat, owner: String = "sharingd", layer: Int = 0, at origin: CGPoint = CGPoint(x: 100, y: 80)) -> WindowInfo {
        WindowInfo(id: 1, pid: getpid(), owner: owner, title: "", layer: layer, bounds: CGRect(origin: origin, size: CGSize(width: w, height: h)), alpha: 1)
    }

    func prompt(_ w: WindowInfo, _ traits: Traits?) -> Bool {
        WindowServer.isPrompt(w, kind: .dialogs, displays: display) { traits }
    }

    /// An ordinary window of one of these processes used to block every agent just for being 800×600 or smaller.
    @Test func anOrdinaryWindowDoesntBlockWhateverItsSize() {
        for (w, h) in [(800.0, 600.0), (360.0, 200.0), (1280.0, 800.0)] {
            #expect(!prompt(window(w, h), ordinary), "\(w)×\(h)")
        }
    }

    /// A consent window larger than an alert used not to count.
    @Test func aConsentWindowLargerThanAnAlertCounts() {
        for owner in ["sharingd", "AirDropUI", "ScreensharingAgent", "loginwindow", "Software Update"] {
            for layer in [3, 8, 19, 101] {   // floating, modal panel, utility, pop-up menu
                #expect(WindowServer.systemPrompts(in: [window(1000, 760, owner: owner, layer: layer)]).count == 1, "\(owner) \(layer)")
            }
        }
        #expect(prompt(window(1000, 760), Traits(role: "AXWindow", subrole: "AXSystemDialog")))
    }

    @Test func accessibilitysDialogSignsCountOnAnyLayerAndSize() {
        let signs = [Traits(role: "AXWindow", subrole: "AXDialog"), Traits(role: "AXWindow", subrole: "AXSystemDialog"),
                     Traits(role: "AXWindow", subrole: "AXFloatingWindow"), Traits(role: "AXSheet"),
                     Traits(role: "AXWindow", subrole: "AXStandardWindow", modal: true, hasCloseButton: true),
                     Traits(role: "AXWindow", subrole: "AXStandardWindow", hasDefaultOrCancelButton: true, hasCloseButton: true)]
        for traits in signs {
            #expect(prompt(window(800, 600), traits), "\(traits)")
            #expect(prompt(window(1400, 900), traits), "\(traits)")
            // Even covering the display: a full-screen consent prompt.
            #expect(prompt(window(1512, 982, layer: 1000, at: .zero), traits), "\(traits)")
        }
    }

    /// Unknown means a prompt: no accessibility answer (a daemon, no permission), a window without a close button,
    /// or a standard window above the normal layer.
    @Test func inDoubtItCounts() {
        #expect(prompt(window(1400, 900), nil))
        #expect(prompt(window(800, 600), Traits(role: "AXWindow", subrole: "AXUnknown")))
        #expect(prompt(window(800, 600), Traits(role: "AXWindow", subrole: "AXStandardWindow")))
        #expect(prompt(window(800, 600, layer: 8), ordinary))
        #expect(prompt(window(800, 600, layer: -1), nil))
    }

    /// The lock screen, a screen-sharing curtain or overlay: whole-display windows that aren't dialogs don't block.
    @Test func wholeDisplayOverlaysDont() {
        for layer in [0, 25, 1000, 2_147_483_628] {
            #expect(!prompt(window(1512, 982, layer: layer, at: .zero), nil), "\(layer)")
            #expect(!prompt(window(1600, 1000, layer: layer, at: CGPoint(x: -10, y: -10)), ordinary), "\(layer)")
        }
        // Slivers and menu-bar items never count, whatever their level.
        #expect(!prompt(window(28, 22, layer: 25), nil))
        #expect(!prompt(window(1512, 33, layer: 25, at: .zero), nil))
    }

    @Test func accessibilityWindowsAreMatchedByFrame() {
        let w = window(800, 600)
        let dialog = Traits(role: "AXWindow", subrole: "AXDialog")
        let list: [(frame: CGRect, traits: Traits)] = [(CGRect(x: 0, y: 0, width: 800, height: 600), ordinary),
                                                       (CGRect(x: 100.5, y: 79.5, width: 800, height: 600.5), dialog)]
        #expect(WindowServer.traits(of: w, in: list) == dialog)
        #expect(WindowServer.traits(of: window(300, 200), in: list) == nil)
        #expect(WindowServer.accessibilityWindows(of: getpid()).isEmpty)   // never asks itself
    }

    /// Whatever their windows show, nothing of these processes may be acted on, and every other window of a process
    /// that only shows prompts counts.
    @Test func theProcessLevelSetsStillHold() {
        for id in WindowServer.mixedPromptBundleIDs {
            #expect(WindowServer.promptKind(bundleID: id, executablePath: nil, name: nil) == .dialogs, "\(id)")
            #expect(WindowServer.isPromptProcess(bundleID: id, executablePath: nil, name: nil), "\(id)")
        }
        #expect(WindowServer.isPrompt(window(1400, 900, owner: "SecurityAgent"), kind: .all, displays: display) { ordinary })
    }
}
