import Foundation
import XCTest
@testable import BangsCore

final class HookRepairTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func backups(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(folder).path).filter { $0.contains(".bangs-") }
    }

    /// The app moved: hooks installed from the old place are rewritten to the new one; CLIs never set up, and hooks
    /// already current, are left alone.
    func testMovedAppRepairsOnlyWhatWasInstalled() throws {
        for folder in [".claude", ".codex", ".gemini"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try HookInstaller(harness: .claude, hookBinary: "/old/Bangs.app/Contents/Helpers/bangs-hook", user: home).install()
        try HookInstaller(harness: .codex, hookBinary: "/new/Bangs.app/Contents/Helpers/bangs-hook", user: home).install()
        let codexBackups = try backups(".codex")
        let codexFile = try Data(contentsOf: home.appendingPathComponent(".codex/hooks.json"))

        let binary = "/new/Bangs.app/Contents/Helpers/bangs-hook"
        let repaired = HookInstaller.repair(hookBinary: binary, user: home) { harness, error in XCTFail("\(harness): \(error)") }
        // Cursor reads Claude Code's file, so repairing Claude Code repairs it too.
        XCTAssertEqual(repaired, [.claude])
        XCTAssertEqual(HookInstaller(harness: .claude, hookBinary: binary, user: home).state(), .installed)
        XCTAssertEqual(HookInstaller(harness: .gemini, hookBinary: binary, user: home).state(), .notInstalled, "never installed, never added")
        XCTAssertEqual(try backups(".codex"), codexBackups)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(".codex/hooks.json")), codexFile)

        // Nothing left to do: another launch writes nothing.
        let claudeBackups = try backups(".claude")
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertEqual(HookInstaller.repair(hookBinary: binary, user: home), [])
        XCTAssertEqual(try backups(".claude"), claudeBackups)
    }

    func testUnreadableSettingsAreNotRewritten() throws {
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try HookInstaller(harness: .claude, hookBinary: "/old/bangs-hook", user: home).install()
        let settings = claude.appendingPathComponent("settings.json")
        var broken = try String(contentsOf: settings, encoding: .utf8)
        broken += "\n// bangs-hook, hand-edited"
        try broken.write(to: settings, atomically: true, encoding: .utf8)
        // Unparseable reads as not installed: nothing to repair, and the file stays as it is.
        var failures: [Harness] = []
        XCTAssertEqual(HookInstaller.repair(hookBinary: "/new/bangs-hook", user: home) { harness, _ in failures.append(harness) }, [])
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), broken)
        XCTAssertEqual(failures, [])
    }
}
