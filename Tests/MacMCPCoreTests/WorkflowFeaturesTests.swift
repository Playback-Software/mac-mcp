import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import MacMCPCore

@Suite struct WorkflowFeaturesTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/TextEdit.app"), "TextEdit must be installed"))
    func installedTerminologyIsReadableWithoutRunningAnApp() throws {
        let text = try ScriptingDictionary.read(bundle: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        #expect(text.contains("document") && text.count <= 12_100)
    }
    @Test func dictionarySummariesAreBoundedAndDoNotResolveEntities() throws {
        let xml = """
            <dictionary><suite name="Test"><command name="save" description="Save a document">
            <parameter name="in" type="file"/></command><class name="document"><property name="name" type="text"/>
            </class><enumeration name="format"/></suite></dictionary>
            """
        let text = try ScriptingDictionary.summarize(Data(xml.utf8), maxEntries: 2)
        #expect(text.contains("command save") && text.contains("in: file") && text.contains("class document"))
        #expect(!text.contains("enumeration format") && text.contains("1 more entries"))
        #expect(throws: (any Error).self) {
            try ScriptingDictionary.summarize(Data("<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><dictionary>&secret;</dictionary>".utf8))
        }
        #expect(throws: (any Error).self) { try ScriptingDictionary.summarize(Data(repeating: 0, count: 2_000_001)) }
        #expect(throws: (any Error).self) { try ScriptingDictionary.summarize(Data("<not-a-dictionary/>".utf8)) }
        #expect(throws: (any Error).self) {
            try ScriptingDictionary.summarize(try #require("<!DOCTYPE x [<!ENTITY a 'b'>]><dictionary/>".data(using: .utf16)))
        }
    }

    @Test func menuHintsRequireOneEnabledUnambiguousLeaf() {
        let save = MenuHints.Item(path: ["File", "Save…"])
        #expect(MenuHints.matching("Save", items: [save]) == ["File", "Save…"])
        #expect(MenuHints.matching("SAVE...", items: [save]) == ["File", "Save…"])
        #expect(MenuHints.matching("Save", items: [save, .init(path: ["Other", "Save"])] ) == nil)
        #expect(MenuHints.matching("Save", items: [.init(path: ["File", "Save"], enabled: false)]) == nil)
        #expect(MenuHints.matching("", items: [save]) == nil)
        #expect(MenuHints.matching("Save", items: [.init(path: ["File > Other", "Save"])]) == nil)
    }

    private func row(_ ref: String, role: String = "button", frame: CGRect) -> Row {
        Row(kind: .interactive, role: role, label: "Control", value: nil, states: [], frame: frame,
            depth: 0, ref: ref, fingerprint: ref)
    }

    @Test func screenshotMarksPreserveCropScalingAndExcludeSecretsAndUnknownIdentity() throws {
        let mapping = ScreenshotMapping(source: CGRect(x: -100, y: 200, width: 100, height: 50),
                                        pixelSize: CGSize(width: 200, height: 150))
        var uncertain = row("e4", frame: CGRect(x: -90, y: 210, width: 10, height: 10)); uncertain.identityUncertain = true
        let marks = ScreenshotMarks.select(rows: [
            row("e1", frame: CGRect(x: -90, y: 210, width: 10, height: 10)),
            row("e2", role: "password", frame: CGRect(x: -90, y: 210, width: 10, height: 10)),
            row("e3", frame: CGRect(x: 500, y: 500, width: 10, height: 10)), uncertain,
        ], mapping: mapping)
        #expect(marks.count == 1)
        #expect(marks.first?.ref == "e1")
        #expect(marks.first?.pixels == CGRect(x: 20, y: 30, width: 20, height: 30))
        let context = try #require(CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try #require(context.makeImage())
        let annotated = try ScreenshotMarks.draw(marks, on: source)
        #expect(annotated.width == source.width && annotated.height == source.height)
        #expect(annotated.dataProvider?.data != source.dataProvider?.data)
    }

    @Test func notificationsResetQuietTimeEvenWhenTheSignatureStaysTheSame() async {
        let generation = Mutex<UInt64>(0)
        let result = await Settle.wait(quiet: 100, timeout: 0.6, events: { generation.withLock { $0 } }) {
            generation.withLock { $0 += 1 }
            return 42
        }
        #expect(!result.settled)
    }

    @Test func delayedObservationUsesTheNotificationTimeInsteadOfThePollTime() async {
        let generation = Mutex<UInt64>(0)
        let delivered = Mutex<ContinuousClock.Instant?>(nil)
        var samples = 0
        let result = await Settle.wait(quiet: 250, timeout: 2,
            events: { generation.withLock { $0 } }, lastEvent: { delivered.withLock { $0 } }) {
                samples += 1
                if samples == 1 { delivered.withLock { $0 = .now } }
                if samples == 2 { generation.withLock { $0 = 1 } }
                return 7
            }
        #expect(result.settled)
        #expect(samples <= 3, "An already-delivered notification must not restart the quiet period at a later poll")
    }

    @Test func observerModeStillSamplesAndFallsBackWhenUnsupported() async {
        var eventSamples = 0, fallbackSamples = 0
        let observed = await Settle.wait(quiet: 250, timeout: 2, events: { 0 }) { eventSamples += 1; return 7 }
        let fallback = await Settle.wait(quiet: 250, timeout: 2, events: { nil }) { fallbackSamples += 1; return 7 }
        #expect(observed.settled && fallback.settled)
        #expect(eventSamples >= 2 && eventSamples < fallbackSamples)
    }
}
