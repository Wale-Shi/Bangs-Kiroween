import AppKit
import XCTest
@testable import Bangs

@MainActor
final class TranslateTests: XCTestCase {
    func testLanguagesAreReadAsTheOnesOffered() {
        XCTAssertEqual(TranslateLanguage.canonical("zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(TranslateLanguage.canonical("zh-TW"), "zh-Hant")
        XCTAssertEqual(TranslateLanguage.canonical("zh-HK"), "zh-Hant")
        XCTAssertEqual(TranslateLanguage.canonical("en-GB"), "en")
        XCTAssertEqual(TranslateLanguage.canonical("pt-PT"), "pt-BR")
        XCTAssertNil(TranslateLanguage.canonical("sw"))
        XCTAssertEqual(TranslateLanguage.voice("zh-Hans"), "zh-CN")
        XCTAssertEqual(TranslateLanguage.voice("en"), "en-US")
        XCTAssertEqual(TranslateLanguage.name("en"), "英语")
    }

    /// Yours goes to your second language, anything else to yours; mixed text goes by what most of it is.
    func testDirection() {
        XCTAssertEqual(TranslateLanguage.detect("The agent couldn't find a matching file in the current directory."), "en")
        XCTAssertEqual(TranslateLanguage.detect("会话列表里显示每个会话的 context 用了多少"), "zh-Hans")
        XCTAssertEqual(TranslateLanguage.detect("ユーザー設定を保存できませんでした。"), "ja")
        XCTAssertNil(TranslateLanguage.detect("42 / 7"))
        XCTAssertEqual(TranslateLanguage.target(for: "en", mine: "zh-Hans", other: "en"), "zh-Hans")
        XCTAssertEqual(TranslateLanguage.target(for: "zh-Hans", mine: "zh-Hans", other: "en"), "en")
        XCTAssertEqual(TranslateLanguage.target(for: "ja", mine: "zh-Hans", other: "en"), "zh-Hans")
        XCTAssertEqual(TranslateLanguage.defaultOther(for: "en"), "zh-Hans")
    }

    /// Lines a PDF or terminal wrapped go back into their paragraph; lists, headings, short lines and blank lines stay.
    func testWrappedLinesAreJoined() {
        let text = """
        # Install
        Bangs watches every coding agent running on this Mac and lets you approve their
        requests from the notch. Every- thing stays on this Mac, and the only network call is the update
        check, which you start.

        - Claude Code
        - Codex
        1. Download the zip
        ----
        这是一段被终端折行的中文说明，用来确认中文和中文之间接起来时不会多出一个
        空格，英文单词之间才需要空格。
        """
        let pieces = TranslatePieces(text).pieces
        XCTAssertEqual(pieces.map(\.text), [
            "# Install",
            "Bangs watches every coding agent running on this Mac and lets you approve their requests from the notch. Every- thing stays on this Mac, and the only network call is the update check, which you start.",
            "",
            "- Claude Code",
            "- Codex",
            "1. Download the zip",
            "----",
            "这是一段被终端折行的中文说明，用来确认中文和中文之间接起来时不会多出一个空格，英文单词之间才需要空格。",
        ])
        XCTAssertEqual(pieces.map(\.translates), [true, true, false, true, true, true, false, true])
        XCTAssertEqual(TranslatePieces.join(["the configuration is read from the environ-", "ment of the process"]), "the configuration is read from the environment of the process")
    }

    /// The translation comes back paragraph by paragraph, in place among the lines kept as they were.
    func testTranslationKeepsTheLayout() {
        let translator = Translator(preferences: Preferences())
        translator.show("First paragraph here.\n\nSecond one.", translated: "第一段。\n\n第二段。", from: "en", to: "zh-Hans", app: nil, phase: .done)
        XCTAssertEqual(translator.translation, "第一段。\n\n第二段。")
        translator.show("First paragraph here.\n\nSecond one.", translated: "第一段。", from: "en", to: "zh-Hans", app: nil, phase: .translating)
        XCTAssertEqual(translator.translation, "第一段。\n", "what has not come back yet is left out")
    }

    /// After the ⌘C that reads a selection, the pasteboard holds what it held before, every form of it, and the history
    /// records neither the copy nor the putting back.
    func testBorrowedPasteboardIsPutBackAndNotRecorded() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bangs-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(preferences: Preferences(), pasteboard: pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("mine", forType: .string)
        item.setData(Data("{\\rtf1 mine}".utf8), forType: .rtf)
        pasteboard.writeObjects([item])
        history.poll()
        let before = history.items.count

        let saved = SelectedText.contents(of: pasteboard)
        history.borrowed = true
        pasteboard.clearContents()
        pasteboard.setString("the selection", forType: .string)
        history.poll()
        SelectedText.restore(saved, to: pasteboard)
        history.borrowed = false
        history.poll()

        XCTAssertEqual(history.items.count, before)
        XCTAssertFalse(history.items.contains { $0.text == "the selection" })
        XCTAssertEqual(pasteboard.string(forType: .string), "mine")
        XCTAssertEqual(pasteboard.data(forType: .rtf), Data("{\\rtf1 mine}".utf8))

        // A copy of yours after that is recorded as usual.
        pasteboard.clearContents()
        pasteboard.setString("later", forType: .string)
        history.poll()
        XCTAssertEqual(history.items.first?.text, "later")
    }
}
