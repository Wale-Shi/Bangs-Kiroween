import XCTest
@testable import Bangs

final class TableRecognitionTests: XCTestCase {
    /// A piece of text at a row and column of a regular grid, in the unit square.
    private func piece(_ text: String, row: Double, column: Double, width: Double = 0.12) -> TextRecognition.Line {
        TextRecognition.Line(text: text, box: CGRect(x: 0.05 + column * 0.2, y: 0.1 + row * 0.15, width: width, height: 0.06))
    }

    func testRebuildsRowsColumnsAndMergedCells() throws {
        let pieces = [
            // A header spanning rows 0–1 sits between them; one spanning columns 1–2 sits across both.
            piece("部门", row: 0.5, column: 0), piece("上半年", row: 0, column: 1.5),
            piece("预算", row: 1, column: 1), piece("实际", row: 1, column: 2), piece("备注", row: 1, column: 3),
            piece("研发", row: 2, column: 0), piece("120", row: 2, column: 1), piece("118", row: 2, column: 2),
            piece("市场", row: 3, column: 0), piece("80", row: 3, column: 1), piece("95", row: 3, column: 3),
        ]
        let table = try XCTUnwrap(TableRecognition.rebuild(pieces))
        XCTAssertEqual(table.grid, [
            ["部门", "上半年", "", ""],
            ["", "预算", "实际", "备注"],
            ["研发", "120", "118", ""],
            ["市场", "80", "", "95"],
        ])
    }

    func testProseIsNotATable() {
        let lines = (0..<5).map { TextRecognition.Line(text: "一行文字 \($0)", box: CGRect(x: 0.05, y: 0.1 + Double($0) * 0.15, width: 0.9, height: 0.06)) }
        XCTAssertNil(TableRecognition.rebuild(lines))
    }

    func testMendsLookalikesOnlyInNumbers() {
        XCTAssertEqual(TableRecognition.number("З"), "3")
        XCTAssertEqual(TableRecognition.number("1O5"), "105")
        XCTAssertEqual(TableRecognition.number("$12.5O"), "$12.50")
        XCTAssertEqual(TableRecognition.number("Nov 3"), "Nov 3")
        XCTAssertEqual(TableRecognition.number("OK"), "OK")
        XCTAssertEqual(TableRecognition.number("O"), "O")
    }

    func testCopiesAsTabsAndAsAnHTMLTableWithMergedCells() {
        let table = RecognizedTable(cells: [
            .init(text: "部门", row: 0, column: 0, rows: 2), .init(text: "上半年", row: 0, column: 1, columns: 2),
            .init(text: "预算", row: 1, column: 1), .init(text: "a\t\"b\"", row: 1, column: 2),
            .init(text: "007", row: 2, column: 0), .init(text: "<1>", row: 2, column: 1),
        ], rowCount: 3, columnCount: 3)
        XCTAssertEqual(table.tsv, "部门\t上半年\t\n\t预算\t\"a \"\"b\"\"\"\n007\t<1>\t")
        XCTAssertTrue(table.html.contains("<td rowspan=\"2\">部门</td><td colspan=\"2\">上半年</td></tr><tr><td>预算</td>"))
        XCTAssertTrue(table.html.contains("<td style=\"mso-number-format:'\\@'\">007</td><td>&lt;1&gt;</td>"))
    }

    /// A right-aligned number and the text in the next cell, read as one: split at the line between the cells, or
    /// at a gap far wider than a space when there is no line.
    func testSplitsTextReadAcrossACellBorder() {
        func word(_ text: String, _ x: Double, _ width: Double) -> TextRecognition.Line {
            TextRecognition.Line(text: text, box: CGRect(x: x, y: 0.5, width: width, height: 0.04))
        }
        var piece = TextRecognition.Line(text: "543234 xx", box: CGRect(x: 0.30, y: 0.5, width: 0.22, height: 0.04))
        piece.words = [word("543234", 0.30, 0.15), word("xx", 0.47, 0.05)]
        XCTAssertEqual(TableRecognition.split(piece, at: [0.46]).map(\.text), ["543234", "xx"])
        XCTAssertEqual(TableRecognition.split(piece, at: []).map(\.text), ["543234 xx"])
        // Words of one cell stay together, however many lines there are elsewhere.
        var name = TextRecognition.Line(text: "Magic Mouse", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.04))
        name.words = [word("Magic", 0.1, 0.09), word("Mouse", 0.2, 0.1)]
        XCTAssertEqual(TableRecognition.split(name, at: [0.05, 0.35]).map(\.text), ["Magic Mouse"])
        // No line, but a gap of several letters.
        piece.words = [word("543234", 0.30, 0.15), word("xx", 0.53, 0.05)]
        XCTAssertEqual(TableRecognition.split(piece, at: []).map(\.text), ["543234", "xx"])
    }

    func testFindsThePaleGridlinesOfASpreadsheet() throws {
        let width = 400, height = 200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        for x in [20, 140, 260, 380] { context.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
        // Text-like marks that are not lines.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 20, to: 180, by: 30) { context.fill(CGRect(x: 60, y: y, width: 2, height: 12)) }
        let image = try XCTUnwrap(context.makeImage())
        let pieces = [TextRecognition.Line(text: "x", box: CGRect(x: 0.1, y: 0.05, width: 0.1, height: 0.05)),
                      TextRecognition.Line(text: "y", box: CGRect(x: 0.1, y: 0.9, width: 0.1, height: 0.05))]
        let lines = TableRecognition.gridlines(in: image, pieces: pieces)
        XCTAssertEqual(lines.map { Int(($0 * CGFloat(width)).rounded()) }, [20, 140, 260, 380])
    }
}
