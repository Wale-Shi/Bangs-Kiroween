import AppKit
import Vision

/// A table read off the screen: its cells by row and column, a cell spanning several kept at its top left.
struct RecognizedTable: Equatable {
    struct Cell: Equatable {
        var text: String
        var row: Int, column: Int
        var rows = 1, columns = 1
    }

    var cells: [Cell]
    var rowCount: Int
    var columnCount: Int

    /// Row by row, "" where a cell is empty or covered by one that spans it.
    var grid: [[String]] {
        var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for cell in cells where grid.indices.contains(cell.row) && grid[cell.row].indices.contains(cell.column) { grid[cell.row][cell.column] = cell.text }
        return grid
    }

    /// Tab between cells, a line per row: what spreadsheets split into cells when pasted.
    var tsv: String {
        grid.map { $0.map(Self.tsvField).joined(separator: "\t") }.joined(separator: "\n")
    }

    private static func tsvField(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        // A quote would start a quoted field.
        return flat.contains("\"") ? "\"" + flat.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : flat
    }

    /// An HTML table, which Excel, Numbers, Word and Feishu read first: it keeps merged cells, and numbers with a
    /// leading zero stay text in Excel.
    var html: String {
        var covered = Set<[Int]>()
        for cell in cells where cell.rows > 1 || cell.columns > 1 {
            for row in cell.row..<cell.row + cell.rows { for column in cell.column..<cell.column + cell.columns where [row, column] != [cell.row, cell.column] { covered.insert([row, column]) } }
        }
        let anchors = Dictionary(cells.map { ([$0.row, $0.column], $0) }, uniquingKeysWith: { first, _ in first })
        var html = "<meta charset=\"utf-8\"><table border=\"1\" style=\"border-collapse:collapse\">"
        for row in 0..<rowCount {
            html += "<tr>"
            for column in 0..<columnCount where !covered.contains([row, column]) {
                let cell = anchors[[row, column]]
                var attributes = ""
                if let cell, cell.rows > 1 { attributes += " rowspan=\"\(cell.rows)\"" }
                if let cell, cell.columns > 1 { attributes += " colspan=\"\(cell.columns)\"" }
                let text = cell?.text ?? ""
                if text.count > 1, text.first == "0", text.allSatisfy(\.isNumber) { attributes += " style=\"mso-number-format:'\\@'\"" }
                html += "<td\(attributes)>\(Self.escape(text))</td>"
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Reads a table in a screenshot. On macOS 26 and later Vision finds tables itself, merged cells included; before it
/// (and to fill a cell it misses, such as a lone character), the table is rebuilt from where each piece of text lies:
/// rows by height, columns from the rows with the most pieces.
enum TableRecognition {
    /// The table, or nil when the text is not one (a paragraph, a page with a small table in it).
    static func recognize(_ image: CGImage, language: TextRecognition.Language) async -> RecognizedTable? {
        let image = TextRecognition.enlarged(image)
        let pieces = (try? await TextRecognition.lines(in: image, language: language, correct: false, words: true)) ?? []
        let lines = gridlines(in: image, pieces: pieces)
        var rebuilt = [rebuild(pieces, gridlines: lines)]
        // Telling the language itself, the recognizer reads words better but drops a character standing alone (a
        // column letter, a 0): a second reading without it fills those cells.
        if language == .auto {
            let second = (try? await TextRecognition.lines(in: image, language: language, correct: false, detect: false, words: true)) ?? []
            rebuilt.append(rebuild(second, gridlines: lines))
        }
        var document: RecognizedTable?
        if #available(macOS 26, *) { document = await documentTable(image, language: language, pieces: pieces) }
        let found = rebuilt.compactMap { $0 }
        // A table with its lines drawn is split along them, which is surer than any guess; Vision's reading adds the
        // cells it merges. Without lines, Vision's table comes first.
        var table: RecognizedTable
        if lines.count >= 3, let first = found.first, document.map({ $0.rowCount == first.rowCount && $0.columnCount == first.columnCount }) ?? true {
            table = first
            if let document { merge(&table, spans: document) }
        } else if let document {
            table = document
        } else if let first = found.first {
            table = first
        } else {
            return nil
        }
        for other in found + (document.map { [$0] } ?? []) { fill(&table, from: other) }
        return tidy(table)
    }

    /// Cells that `other` merges across rows or columns, merged in `table` too, which has the same shape.
    static func merge(_ table: inout RecognizedTable, spans other: RecognizedTable) {
        for span in other.cells where span.rows > 1 || span.columns > 1 {
            let inside = { (cell: RecognizedTable.Cell) in
                (span.row..<span.row + span.rows).contains(cell.row) && (span.column..<span.column + span.columns).contains(cell.column)
            }
            let text = table.cells.filter(inside).sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            table.cells.removeAll(where: inside)
            table.cells.append(RecognizedTable.Cell(text: text.isEmpty ? span.text : text, row: span.row, column: span.column, rows: span.rows, columns: span.columns))
        }
    }

    /// Where a table's vertical lines are, as x in the unit square: columns of pixels that differ from both sides
    /// over most of the table's height. Spreadsheets, web pages and documents draw them; a borderless table has none.
    static func gridlines(in image: CGImage, pieces: [TextRecognition.Line]) -> [CGFloat] {
        guard let top = pieces.map(\.box.minY).min(), let bottom = pieces.map(\.box.maxY).max() else { return [] }
        let width = image.width, height = image.height
        guard width > 8, height > 8, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        // The rows the text spans (bitmap rows run from the top here, as the unit square does).
        let first = max(0, Int(top * CGFloat(height))), last = min(height - 1, Int(bottom * CGFloat(height)))
        guard last - first > 8 else { return [] }
        var columns: [Int] = []
        for x in 3..<(width - 3) {
            var hits = 0
            for y in first...last {
                let row = y * width
                let value = Int(pixels[row + x]), left = Int(pixels[row + x - 3]), right = Int(pixels[row + x + 3])
                // A line is darker (or lighter) than both sides by a little: gridlines are often a pale grey.
                if (value - left) * (value - right) > 64 && abs(value - left) >= 8 && abs(value - right) >= 8 { hits += 1 }
            }
            if hits * 10 >= (last - first + 1) * 7 { columns.append(x) }
        }
        // Neighbouring columns of pixels are one line.
        var lines: [[Int]] = []
        for x in columns { if let last = lines.last?.last, x - last <= 2 { lines[lines.count - 1].append(x) } else { lines.append([x]) } }
        return lines.map { CGFloat($0.reduce(0, +)) / CGFloat($0.count) / CGFloat(width) }
    }

    /// Cells empty in `table` take the text `other` has there, when both see the same shape. Vision's tables drop a
    /// lone character now and then.
    static func fill(_ table: inout RecognizedTable, from other: RecognizedTable) {
        guard other.rowCount == table.rowCount, other.columnCount == table.columnCount else { return }
        let grid = other.grid
        for index in table.cells.indices where table.cells[index].text.isEmpty {
            table.cells[index].text = grid[table.cells[index].row][table.cells[index].column]
        }
        let present = Set(table.cells.map { [$0.row, $0.column] })
        for cell in other.cells where !cell.text.isEmpty && !present.contains([cell.row, cell.column]) && !covered(table, cell.row, cell.column) {
            table.cells.append(cell)
        }
    }

    /// The first table read after Bangs is installed or updated waits half a minute while macOS prepares its readers
    /// for these languages. Reading a small table, the way a real one is read, does that beforehand: once for each
    /// version of Bangs and of macOS, and in a process of its own, since the readers stay in the memory of whoever
    /// used them (some 20 MB, for as long as Bangs runs, whether or not you ever read a table).
    static func prepareOnce(language: TextRecognition.Language, defaults: UserDefaults = .standard) {
        guard #available(macOS 26, *), let executable = Bundle.main.executableURL else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let key = "\(version) · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(language.rawValue)"
        guard defaults.string(forKey: "ocrPrepared") != key else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--prepare-ocr", language.rawValue]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let start = Date()
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            Log.write(String(format: "ocr: table reader prepared in %.1fs (exit %d)", Date().timeIntervalSince(start), process.terminationStatus))
            if process.terminationStatus == 0 { defaults.set(key, forKey: "ocrPrepared") }
        }
    }

    /// What `Bangs --prepare-ocr` does: reads a small table and returns.
    static func prepare(language: TextRecognition.Language) async {
        let size = NSSize(width: 240, height: 60)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (row, line) in ["名称\t数量", "Apple\t12"].enumerated() {
                for (column, cell) in line.split(separator: "\t").enumerated() {
                    (String(cell) as NSString).draw(at: NSPoint(x: 12 + column * 110, y: 34 - row * 24), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
                }
            }
            return true
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        _ = await recognize(cgImage, language: language)
    }

    @available(macOS 26, *)
    private static func documentTable(_ image: CGImage, language: TextRecognition.Language, pieces: [TextRecognition.Line]) async -> RecognizedTable? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = language.codes.map { Locale.Language(identifier: $0) }
        request.textRecognitionOptions.automaticallyDetectLanguage = language == .auto
        guard let document = try? await request.perform(on: image).first?.document,
              let table = document.tables.max(by: { $0.rows.joined().count < $1.rows.joined().count }) else { return nil }
        let cells = table.rows.joined().map { cell in
            RecognizedTable.Cell(text: cell.content.text.transcript.replacingOccurrences(of: "\n", with: " "),
                                 row: cell.rowRange.lowerBound, column: cell.columnRange.lowerBound,
                                 rows: cell.rowRange.count, columns: cell.columnRange.count)
        }
        let result = RecognizedTable(cells: cells, rowCount: (cells.map { $0.row + $0.rows }.max() ?? 0),
                                     columnCount: (cells.map { $0.column + $0.columns }.max() ?? 0))
        guard result.rowCount >= 2, result.columnCount >= 2 else { return nil }
        // Most of the text must be in the table: a page with a small table in it is read as text.
        let inTable = cells.reduce(0) { $0 + $1.text.count }
        let all = pieces.reduce(0) { $0 + $1.text.count }
        return all == 0 || Double(inTable) >= Double(all) * 0.7 ? result : nil
    }

    private static func covered(_ table: RecognizedTable, _ row: Int, _ column: Int) -> Bool {
        table.cells.contains { ($0.rows > 1 || $0.columns > 1) && ($0.row..<$0.row + $0.rows).contains(row) && ($0.column..<$0.column + $0.columns).contains(column) }
    }

    /// A table from where each piece of text lies (boxes in the unit square, origin top left), or nil when the pieces
    /// do not line up as one: fewer than two columns, or fewer than three rows most of which have two pieces or more.
    static func rebuild(_ pieces: [TextRecognition.Line], gridlines: [CGFloat] = []) -> RecognizedTable? {
        let pieces = pieces.flatMap { split($0, at: gridlines) }
        // Rows: pieces that overlap by half their height, top to bottom.
        var rows: [[TextRecognition.Line]] = []
        for piece in pieces.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let first = rows.last?.first,
               min(first.box.maxY, piece.box.maxY) - max(first.box.minY, piece.box.minY) > 0.5 * min(first.box.height, piece.box.height) {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        // A cell spanning two rows sits between them and would make a row of its own: it joins the row above when it
        // is nearer than a row's pitch and that row has nothing where it is.
        let centers = rows.map { $0.map(\.box.midY).reduce(0, +) / CGFloat($0.count) }
        let pitches = zip(centers.dropFirst(), centers).map { $0 - $1 }.sorted()
        let pitch = pitches.isEmpty ? 0 : pitches[pitches.count / 2]
        var folded: [[TextRecognition.Line]] = [], foldedCenters: [CGFloat] = []
        for (index, row) in rows.enumerated() {
            if let last = foldedCenters.last, centers[index] - last < pitch * 0.75,
               row.allSatisfy({ piece in !folded[folded.count - 1].contains { $0.box.minX < piece.box.maxX && piece.box.minX < $0.box.maxX } }) {
                folded[folded.count - 1] += row
            } else {
                folded.append(row)
                foldedCenters.append(centers[index])
            }
        }
        rows = folded
        let most = rows.map(\.count).max() ?? 0
        guard most >= 2, rows.count >= 3, rows.filter({ $0.count >= 2 }).count * 10 >= rows.count * 6 else { return nil }
        // Drawn lines: the columns are the gaps between them that hold text.
        if gridlines.count >= 3 {
            let bounds = [0] + gridlines + [1]
            let used = Set(rows.joined().map { piece in bounds.indices.dropLast().first { piece.box.midX < bounds[$0 + 1] } ?? bounds.count - 2 })
            let columns = used.sorted()
            guard columns.count >= 2 else { return nil }
            var cells: [RecognizedTable.Cell] = []
            for (rowIndex, row) in rows.enumerated() {
                var texts: [Int: String] = [:]
                for piece in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                    let gap = bounds.indices.dropLast().first { piece.box.midX < bounds[$0 + 1] } ?? bounds.count - 2
                    let index = columns.firstIndex(of: gap) ?? 0
                    texts[index] = texts[index].map { $0 + " " + piece.text } ?? piece.text
                }
                cells += texts.map { RecognizedTable.Cell(text: $0.value, row: rowIndex, column: $0.key) }
            }
            return RecognizedTable(cells: cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }, rowCount: rows.count, columnCount: columns.count)
        }
        // Columns: the spans of the rows with the most pieces (a header spanning two columns would join them), then of
        // any piece that falls in none of them (a column empty in those rows).
        var spans: [ClosedRange<CGFloat>] = []
        func add(_ span: ClosedRange<CGFloat>) {
            var span = span
            spans.removeAll { existing in
                guard existing.overlaps(span) else { return false }
                span = min(existing.lowerBound, span.lowerBound)...max(existing.upperBound, span.upperBound)
                return true
            }
            spans.append(span)
        }
        for piece in rows.filter({ $0.count == most }).joined() { add(piece.box.minX...piece.box.maxX) }
        for piece in rows.joined() where !spans.contains(where: { $0.overlaps(piece.box.minX...piece.box.maxX) }) { add(piece.box.minX...piece.box.maxX) }
        spans.sort { $0.lowerBound < $1.lowerBound }
        guard spans.count >= 2 else { return nil }
        func column(_ box: CGRect) -> Int {
            // The first column it overlaps (a merged cell's text goes to its first column), else the nearest.
            if let index = spans.firstIndex(where: { $0.overlaps(box.minX...box.maxX) }) { return index }
            return spans.indices.min { abs((spans[$0].lowerBound + spans[$0].upperBound) / 2 - box.midX) < abs((spans[$1].lowerBound + spans[$1].upperBound) / 2 - box.midX) } ?? 0
        }
        var cells: [RecognizedTable.Cell] = []
        for (rowIndex, row) in rows.enumerated() {
            var texts: [Int: String] = [:]
            for piece in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let index = column(piece.box)
                texts[index] = texts[index].map { $0 + " " + piece.text } ?? piece.text
            }
            cells += texts.map { RecognizedTable.Cell(text: $0.value, row: rowIndex, column: $0.key) }
        }
        return RecognizedTable(cells: cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }, rowCount: rows.count, columnCount: spans.count)
    }

    /// A piece the recognizer read as one though it runs over a drawn line, or has a gap far wider than a space in it
    /// (a right-aligned number and the text in the next cell): split there, by its words.
    static func split(_ piece: TextRecognition.Line, at gridlines: [CGFloat]) -> [TextRecognition.Line] {
        guard piece.words.count >= 2 else { return [piece] }
        var groups: [[TextRecognition.Line]] = [[piece.words[0]]]
        for (previous, word) in zip(piece.words, piece.words.dropFirst()) {
            let crosses = gridlines.contains { $0 > previous.box.midX && $0 < word.box.midX }
            let wide = word.box.minX - previous.box.maxX > piece.box.height * 1.2
            if crosses || wide { groups.append([word]) } else { groups[groups.count - 1].append(word) }
        }
        guard groups.count > 1 else { return [piece] }
        return groups.map { words in
            TextRecognition.Line(text: words.map(\.text).joined(separator: " "),
                                 box: words.dropFirst().reduce(words[0].box) { $0.union($1.box) }.intersection(piece.box.insetBy(dx: 0, dy: -1)))
        }
    }

    /// Mends what the recognizer gets wrong in numbers: a Cyrillic "З" for 3, a letter O for 0, in a cell that is
    /// otherwise a number.
    static func tidy(_ table: RecognizedTable) -> RecognizedTable {
        var table = table
        for index in table.cells.indices { table.cells[index].text = number(table.cells[index].text) }
        return table
    }

    private static let lookalikes: [Character: Character] = ["З": "3", "з": "3", "О": "0", "о": "0", "O": "0", "o": "0", "l": "1", "I": "1", "Ⅰ": "1", "Б": "6", "б": "6"]

    static func number(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains(where: { lookalikes[$0] != nil }) else { return text }
        let mapped = String(trimmed.map { lookalikes[$0] ?? $0 })
        // A number as tables show it: a sign or currency, digits with separators, a percent.
        let isNumber = mapped.range(of: #"^[-+]?[$¥€£]?[0-9][0-9,.]*%?$"#, options: .regularExpression) != nil
        // Only when the cell had a real digit, or a letter no word is made of alone (the Cyrillic З).
        let likely = trimmed.contains(where: \.isNumber) || trimmed.contains(where: { "ЗзБб".contains($0) })
        return isNumber && likely ? mapped : text
    }
}
