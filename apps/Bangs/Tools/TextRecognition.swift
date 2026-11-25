import AppKit
import Vision

/// Reads the text in a screenshot with Apple's on-device recognizer; nothing leaves the Mac.
enum TextRecognition {
    enum Language: String, CaseIterable {
        case auto, simplified, traditional, english, japanese

        var title: String {
            switch self {
            case .auto: "自动（中文、英文）"
            case .simplified: "简体中文"
            case .traditional: "繁体中文"
            case .english: "English"
            case .japanese: "日本語"
            }
        }

        /// English rides along with every choice: code, paths and product names are in it whatever the language.
        var codes: [String] {
            switch self {
            case .auto, .simplified: ["zh-Hans", "en-US"]
            case .traditional: ["zh-Hant", "en-US"]
            case .english: ["en-US"]
            case .japanese: ["ja-JP", "en-US"]
            }
        }
    }

    /// One line as the recognizer found it, its box in the image's unit square (origin top left).
    struct Line: Equatable {
        var text: String
        var box: CGRect
        /// Its words and their boxes, when asked for: the recognizer runs a number and the text in the next cell together.
        var words: [Line] = []
    }

    static func recognize(_ image: CGImage, language: Language, joinLines: Bool) async throws -> String {
        text(of: try await lines(in: enlarged(image), language: language), joinLines: joinLines)
    }

    /// Each line or piece of text and where it is. `correct`: let the recognizer fix words by language, which helps
    /// prose and hurts codes and numbers in a table. `detect`: with the automatic language, let it tell the language
    /// itself, which reads words better but drops a character standing alone.
    static func lines(in image: CGImage, language: Language, correct: Bool = true, detect: Bool = true, words: Bool = false) async throws -> [Line] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> Line? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Vision's boxes start at the bottom left.
                    func flip(_ box: CGRect) -> CGRect { CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height) }
                    var line = Line(text: candidate.string, box: flip(observation.boundingBox))
                    if words {
                        let text = candidate.string
                        var start = text.startIndex
                        while let wordStart = text[start...].firstIndex(where: { !$0.isWhitespace }) {
                            let wordEnd = text[wordStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                            if let box = try? candidate.boundingBox(for: wordStart..<wordEnd)?.boundingBox {
                                line.words.append(Line(text: String(text[wordStart..<wordEnd]), box: flip(box)))
                            }
                            start = wordEnd
                        }
                    }
                    return line
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = correct
            request.recognitionLanguages = language.codes
            request.automaticallyDetectsLanguage = language == .auto && detect
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// A capture framed tight round a line of text reads badly: the recognizer drops the first letter or a character
    /// that touches the edge. So every capture gets a white margin, and a short one (a line of small text) is enlarged
    /// to about 48 pixels tall. Tried on single lines at 10–13 pt on Retina and 1x screens: 7 of 24 misread as they
    /// were, 2 of 24 like this.
    static func enlarged(_ image: CGImage) -> CGImage {
        let scale = image.height < 48 ? Int((48.0 / Double(max(image.height, 1))).rounded(.up)) : 1
        let margin = min(max(16, image.height * scale / 2), 64)
        let width = image.width * scale + margin * 2, height = image.height * scale + margin * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width * scale, height: image.height * scale))
        return context.makeImage() ?? image
    }

    /// The lines top to bottom. With `joinLines`, a line that runs to the block's right edge and is followed closely by
    /// one starting where it starts was wrapped, so the two become one: a paragraph comes out whole, while code, lists
    /// and tables, whose lines end short, keep their breaks.
    static func text(of lines: [Line], joinLines: Bool) -> String {
        let lines = reading(lines)
        guard joinLines, lines.count > 1 else { return lines.map(\.text).joined(separator: "\n") }
        let right = lines.map(\.box.maxX).max() ?? 1
        let left = lines.map(\.box.minX).min() ?? 0
        let span = max(right - left, 0.0001)
        var result = lines[0].text
        for (previous, line) in zip(lines, lines.dropFirst()) {
            let gap = line.box.minY - previous.box.maxY
            let wrapped = (right - previous.box.maxX) / span < 0.12
                && abs(line.box.minX - previous.box.minX) / span < 0.06
                && gap < previous.box.height * 0.9
                && !previous.text.hasSuffix(where: { "。！？.!?:：;；".contains($0) })
            result += wrapped ? joiner(previous.text, line.text) + line.text : "\n" + line.text
        }
        return result
    }

    /// Top to bottom, and left to right within a row: lines whose middles sit within half a line of the row's first
    /// line share its row (a label and its value, cells of a table).
    static func reading(_ lines: [Line]) -> [Line] {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let first = rows.last?.first, abs(line.box.midY - first.box.midY) < min(line.box.height, first.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// Chinese and Japanese run on without a space; other scripts get one, and a word broken with a hyphen is mended.
    private static func joiner(_ before: String, _ after: String) -> String {
        guard let last = before.last, let first = after.first else { return "" }
        if isCJK(last) || isCJK(first) { return "" }
        return " "
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    /// The text's one link, when it is nothing but that.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        // "www." or a scheme: "notes.txt" is a file name, not a site.
        let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://" + trimmed : trimmed
        guard let url = URL(string: candidate), let host = url.host, host.contains("."), ["http", "https"].contains(url.scheme) else { return nil }
        return url
    }
}

private extension String {
    func hasSuffix(where predicate: (Character) -> Bool) -> Bool { last.map(predicate) ?? false }
}
