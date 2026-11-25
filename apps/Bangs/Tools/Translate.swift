import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI
import Translation

/// The languages the translation offers, and which way a piece of text goes. Translation runs on this Mac with Apple's
/// Translation framework; the language packs it needs are downloaded by macOS when you ask, never by Bangs.
enum TranslateLanguage {
    /// What Apple's translation supports (macOS 15–27), by the identifiers kept in the settings.
    static let all = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt-BR", "ru", "ar", "th", "vi", "id", "tr", "pl", "nl", "uk", "hi"]

    static func name(_ id: String) -> String {
        switch id {
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁体中文"
        case "pt-BR": "葡萄牙语"
        default: Locale(identifier: "zh-Hans").localizedString(forLanguageCode: id) ?? id
        }
    }

    /// One of `all` for any language identifier ("zh-Hans-CN", "zh-HK", "en-GB"), or nil for one not offered.
    static func canonical(_ id: String) -> String? {
        let language = Locale.Language(identifier: Locale.Language(identifier: id).maximalIdentifier)
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" { return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
        return all.first { Locale.Language(identifier: $0).languageCode?.identifier == code }
    }

    /// The language the text is mostly in, read on this Mac; nil when it cannot tell or does not offer it.
    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return canonical(language.rawValue)
    }

    /// Your language goes to your second one; everything else to yours.
    static func target(for source: String, mine: String, other: String) -> String {
        source == mine ? other : mine
    }

    /// Simplified Chinese, whatever the system's language: Bangs is written in it, so whoever uses Bangs reads it, and a Mac
    /// set to English is common among them.
    static let defaultMine = "zh-Hans"

    /// The second language for `mine`: English, or Simplified Chinese for English.
    static func defaultOther(for mine: String) -> String { mine == "en" ? "zh-Hans" : "en" }

    /// A voice's language tag, region included ("zh-CN", "en-US"), which the speech voices are named by.
    static func voice(_ id: String) -> String {
        let language = Locale.Language(identifier: Locale.Language(identifier: id).maximalIdentifier)
        return [language.languageCode?.identifier, language.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }
}

/// Text cut into what is translated one piece at a time: a paragraph each, with the lines that a PDF or a terminal wrapped
/// put back together, and blank lines kept where they were.
struct TranslatePieces: Equatable {
    struct Piece: Equatable {
        var text: String
        /// Blank lines and lines without a letter are kept as they are.
        var translates: Bool
    }

    var pieces: [Piece]

    /// Longer selections are cut here: translation is for reading, and a whole file would keep the card busy for minutes.
    static let limit = 5000

    init(_ text: String) {
        var pieces: [Piece] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            pieces.append(Piece(text: Self.join(paragraph), translates: true))
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || !line.contains(where: \.isLetter) {
                flush()
                pieces.append(Piece(text: raw, translates: false))
            } else if let last = paragraph.last, !Self.continues(last, with: line) {
                flush()
                paragraph = [line]
            } else {
                paragraph.append(line)
            }
        }
        flush()
        self.pieces = pieces
    }

    /// A line goes on from the one before when that one was cut by wrapping: long, without a sentence's end, and the new
    /// line is not a list item or a heading.
    static func continues(_ before: String, with line: String) -> Bool {
        // Chinese and Japanese characters take two columns, as a terminal counts them.
        let width = before.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
        guard width >= 40, let end = before.last, !".!?;:。！？；：…)）」』\"”".contains(end) else { return false }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.hasPrefix("#") || line.hasPrefix(">") { return false }
        if let dot = line.firstIndex(of: "."), dot != line.startIndex, line[..<dot].allSatisfy(\.isNumber) { return false }
        return true
    }

    /// Wrapped lines back into one: a space between words, nothing between Chinese or Japanese characters, and a word
    /// broken with a hyphen made whole.
    static func join(_ lines: [String]) -> String {
        lines.dropFirst().reduce(lines[0]) { text, line in
            if text.hasSuffix("-"), text.dropLast().last?.isLetter == true, line.first?.isLowercase == true { return text.dropLast() + line }
            if let end = text.last, let start = line.first, isWide(end) || isWide(start) { return text + line }
            return text + " " + line
        }
    }

    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}

/// The text selected in the app in front: asked for through Accessibility, which most apps answer; else copied with ⌘C,
/// with whatever was on the pasteboard put back right after.
enum SelectedText {
    struct Grab {
        var text: String
        var app: String?
        /// The field it was selected in, when the translation can be written back into it.
        var field: AXUIElement?
    }

    @MainActor
    static func read(copying: Bool, clipboard: ClipboardHistory) async -> Grab? {
        guard AXIsProcessTrusted() else { return nil }
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName
        // Asking another app can take a moment, or hang on one that is stuck: never on the main thread.
        let asked = await Task.detached { focused() }.value
        if let text = asked.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Grab(text: text, app: name, field: asked.editable ? asked.element : nil)
        }
        // A password field answers nothing, and ⌘C must not be pressed in one either.
        guard copying, !asked.secure, app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        guard let text = await copy(clipboard: clipboard), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Grab(text: text, app: name, field: nil)
    }

    private struct Focused: @unchecked Sendable {
        var element: AXUIElement?
        var text: String?
        var editable = false
        var secure = false
    }

    private static let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    private static func focused() -> Focused {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return Focused() }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        let role = string(kAXRoleAttribute) ?? ""
        return Focused(element: element, text: string(kAXSelectedTextAttribute),
                       editable: settable.boolValue && editableRoles.contains(role),
                       secure: string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole)
    }

    /// ⌘C in the app in front, once the shortcut's own keys are up; what it copied, and the pasteboard as it was.
    @MainActor
    private static func copy(clipboard: ClipboardHistory) async -> String? {
        await modifiersReleased()
        let pasteboard = NSPasteboard.general
        let saved = contents(of: pasteboard)
        let before = pasteboard.changeCount
        clipboard.borrowed = true
        defer { clipboard.borrowed = false }
        press(keyCode: 8)  // C
        var text: String?
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before {
                // The app may still be writing the other forms of what it copied.
                try? await Task.sleep(for: .milliseconds(30))
                text = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { restore(saved, to: pasteboard) }
        return text
    }

    /// Writes the translation over the selection: into the field through Accessibility, else by pasting it there, with the
    /// pasteboard put back afterwards.
    @MainActor
    static func replace(in field: AXUIElement?, with text: String, clipboard: ClipboardHistory) {
        if let field, AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return }
        guard AXIsProcessTrusted() else { return }
        let pasteboard = NSPasteboard.general
        let saved = contents(of: pasteboard)
        clipboard.borrowed = true
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(keyCode: 9)  // V
        // The paste is read by the app a moment later; only then can the pasteboard go back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            restore(saved, to: pasteboard)
            clipboard.borrowed = false
        }
    }

    private static func press(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The shortcut was pressed with ⌥ and ⌘: an app reading the keys still held would take ⌘C for ⌥⌘C.
    @MainActor
    private static func modifiersReleased() async {
        for _ in 0..<30 {
            let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskAlternate, .maskControl, .maskShift, .maskCommand])
            if held.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    typealias Contents = [[(NSPasteboard.PasteboardType, Data)]]

    static func contents(of pasteboard: NSPasteboard) -> Contents {
        (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    }

    static func restore(_ contents: Contents, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = contents.filter { !$0.isEmpty }.map { forms -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in forms { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

/// One translation shown in the island: the text, which way it goes, and the result as it comes in.
@MainActor
final class Translator: ObservableObject {
    enum Phase: Equatable {
        /// Checking that the languages are on this Mac.
        case checking
        case translating
        case done
        /// The pair is supported but its language pack is not downloaded.
        case needsDownload
        case unsupported
        case unknownLanguage
        case nothingSelected
        /// Translation needs macOS 15.
        case needsNewerSystem
        case failed(String)
    }

    @Published private(set) var source = ""
    @Published private(set) var cut = false
    @Published private(set) var app: String?
    @Published private(set) var from: String?
    @Published private(set) var to = "zh-Hans"
    @Published private(set) var phase: Phase = .nothingSelected
    @Published private(set) var results: [Int: String] = [:]
    /// Who translates this one: the one chosen in the settings, or another picked on the card.
    @Published private(set) var engine: TranslateEngine = .apple
    /// A model's or an agent's translation so far, which comes as one text rather than paragraph by paragraph.
    @Published private(set) var streamed = ""
    private var stream: Task<Void, Never>?
    /// Bumped for every translation to run, so the view hosting the translation starts again.
    @Published private(set) var job = 0
    private(set) var pieces = TranslatePieces("")
    private(set) var field: AXUIElement?
    private let preferences: Preferences
    private let speech = AVSpeechSynthesizer()

    init(preferences: Preferences) { self.preferences = preferences }

    var canReplace: Bool { field != nil }

    /// The translation so far: Apple's paragraph by paragraph (those not yet back are left out), a model's as it streams.
    var translation: String {
        guard engine == .apple else { return streamed.trimmingCharacters(in: .whitespacesAndNewlines) }
        return pieces.pieces.enumerated().compactMap { index, piece in piece.translates ? results[index] : piece.text }.joined(separator: "\n")
    }

    var hasText: Bool { engine == .apple ? !results.isEmpty : !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The engines the card can switch to: Apple's from macOS 15, the others once their settings are filled in.
    var engines: [TranslateEngine] {
        TranslateEngine.allCases.filter { engine in
            switch engine {
            case .apple: if #available(macOS 15, *) { true } else { false }
            case .model: !preferences.translateAPIURL.isEmpty && !preferences.translateAPIModel.isEmpty
            case .agent: !agentCommand.isEmpty
            }
        }
    }

    /// The model or agent by name, for the card.
    func label(_ engine: TranslateEngine) -> String {
        switch engine {
        case .apple: "本机翻译"
        case .model: preferences.translateAPIModel.isEmpty ? "大模型" : preferences.translateAPIModel
        case .agent: ACPAgent.preset(preferences.translateAgent)?.name ?? "Agent"
        }
    }

    var agentCommand: String {
        (preferences.translateAgent == "custom" ? preferences.translateAgentCommand : ACPAgent.preset(preferences.translateAgent)?.command ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    func nothingSelected() {
        source = ""
        field = nil
        phase = .nothingSelected
    }

    /// Starts on a new piece of text; `field` is where it was selected, when the translation can be written back.
    func start(_ text: String, app: String?, field: AXUIElement? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cut = trimmed.count > TranslatePieces.limit
        source = String(trimmed.prefix(TranslatePieces.limit))
        self.app = app
        self.field = field
        pieces = TranslatePieces(source)
        from = TranslateLanguage.detect(source)
        to = from.map { TranslateLanguage.target(for: $0, mine: preferences.translateMine, other: preferences.translateOther) } ?? preferences.translateMine
        engine = preferences.translateEngine
        translate()
    }

    /// The same text again, by another engine.
    func use(_ engine: TranslateEngine) {
        guard engine != self.engine || phase != .done else { return }
        self.engine = engine
        translate()
    }

    /// Into another language than the one chosen for it.
    func retarget(_ language: String) {
        guard language != to else { return }
        to = language
        translate()
    }

    private func translate() {
        results = [:]
        streamed = ""
        stream?.cancel()
        stream = nil
        speech.stopSpeaking(at: .immediate)
        let job = job + 1
        self.job = job
        guard engine == .apple else { return streamFromModel(job) }
        guard #available(macOS 15, *) else { phase = .needsNewerSystem; return }
        guard let from else { phase = .unknownLanguage; return }
        guard from != to else { phase = .unsupported; return }
        phase = .checking
        let (source, target) = (Locale.Language(identifier: from), Locale.Language(identifier: to))
        Task {
            let status = await LanguageAvailability().status(from: source, to: target)
            guard job == self.job else { return }
            switch status {
            case .installed: phase = .translating
            case .supported: phase = .needsDownload
            default: phase = .unsupported
            }
        }
    }

    /// A model or an agent translating: what it writes shows as it comes. A model needs no language detected.
    private func streamFromModel(_ job: Int) {
        let pieces: AsyncThrowingStream<String, Error>
        switch engine {
        case .model:
            guard engines.contains(.model) else { phase = .failed("还没有配置大模型：在设置 › 翻译里填好 API 地址和模型。"); return }
            pieces = ModelAPI.stream(text: source, to: to, format: preferences.translateAPIFormat, base: preferences.translateAPIURL,
                                     model: preferences.translateAPIModel, key: TranslateKey.read())
        default:
            guard engines.contains(.agent) else { phase = .failed("还没有选 Agent：在设置 › 翻译里选一个。"); return }
            pieces = ACPAgent.shared.translate(source, to: to, command: agentCommand)
        }
        phase = .translating
        stream = Task { [weak self] in
            do {
                for try await piece in pieces {
                    guard let self, job == self.job else { return }
                    self.streamed += piece
                }
                guard let self, job == self.job else { return }
                if self.streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.phase = .failed("没有收到译文。")
                } else {
                    self.phase = .done
                }
            } catch {
                guard let self, job == self.job, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The translation itself, run by the view while the island shows it (see TranslationRunner).
    @available(macOS 15, *)
    func run(_ session: TranslationSession) async {
        let job = job
        guard phase == .translating else { return }
        let requests = pieces.pieces.enumerated().filter(\.element.translates).map {
            TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset))
        }
        do {
            for try await response in session.translate(batch: requests) {
                guard job == self.job else { return }
                if let index = response.clientIdentifier.flatMap(Int.init) { results[index] = response.targetText }
            }
            if job == self.job { phase = .done }
        } catch {
            guard job == self.job, !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// The configuration the view runs the translation with, nil while there is none to run.
    @available(macOS 15, *)
    var configuration: TranslationSession.Configuration? {
        guard engine == .apple, phase == .translating, let from else { return nil }
        return TranslationSession.Configuration(source: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
    }

    func speak() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate); return }
        let utterance = AVSpeechUtterance(string: translation)
        utterance.voice = AVSpeechSynthesisVoice(language: TranslateLanguage.voice(to))
        speech.speak(utterance)
    }

    /// The card closed: no more speaking, and a model or agent still writing is told to stop.
    func stop() {
        speech.stopSpeaking(at: .immediate)
        if phase == .translating, engine != .apple {
            stream?.cancel()
            stream = nil
            phase = .failed("翻译到一半关掉了。")
        }
    }

    /// For the snapshots: a translation as it would look, without running one.
    func show(_ text: String, translated: String?, from: String, to: String, app: String?, phase: Phase, editable: Bool = false, engine: TranslateEngine = .apple) {
        self.engine = engine
        streamed = engine == .apple ? "" : translated ?? ""
        source = text
        self.app = app
        self.from = from
        self.to = to
        pieces = TranslatePieces(text)
        results = [:]
        if let translated {
            let parts = translated.components(separatedBy: "\n\n")
            for (offset, index) in pieces.pieces.indices.filter({ pieces.pieces[$0].translates }).enumerated() where offset < parts.count { results[index] = parts[offset] }
        }
        self.phase = phase
        field = editable ? AXUIElementCreateSystemWide() : nil
    }
}

/// Hosts the translation: Apple's runs inside a view, which gives it a session for the configured languages.
private struct TranslationRunner: ViewModifier {
    @ObservedObject var translator: Translator

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(Running(translator: translator))
        } else {
            content
        }
    }

    @available(macOS 15, *)
    private struct Running: ViewModifier {
        @ObservedObject var translator: Translator
        @State private var configuration: TranslationSession.Configuration?

        func body(content: Content) -> some View {
            content
                .translationTask(configuration) { session in await translator.run(session) }
                .onAppear(perform: configure)
                .onChange(of: translator.job) { _, _ in configure() }
                .onChange(of: translator.phase) { _, _ in configure() }
        }

        private func configure() {
            guard let next = translator.configuration else { return }
            // The same languages again: the configuration has to be told to run once more.
            if var current = configuration, current.source == next.source, current.target == next.target {
                guard translator.results.isEmpty else { return }
                current.invalidate()
                configuration = current
            } else {
                configuration = next
            }
        }
    }
}

/// The island with a translation: which way it went, the original (folded), the translation, and what to do with it.
struct TranslationView: View {
    @ObservedObject var translator: Translator
    @ObservedObject var model: NotchModel
    @State private var showsSource = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch translator.phase {
            case .nothingSelected: message("没有选中文字", AXIsProcessTrusted() ? "先选中一段文字再按快捷键；也可以在截图识字后点「翻译」。" : "读取选中的文字需要「辅助功能」权限，在设置 › 权限里打开。")
            case .needsNewerSystem: message("翻译需要 macOS 15 或更新版本", "Bangs 用的是系统自带的本机翻译。")
            default: translation
            }
        }
        .modifier(TranslationRunner(translator: translator))
        .onDisappear { translator.stop() }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 6)
        }
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(translator.source)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.dim)
                .lineLimit(showsSource ? 12 : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(NotchModel.Motion.tab) { showsSource.toggle() } }
                .padding(.top, 6)
            Rectangle().fill(Palette.wash(0.1)).frame(height: 1).padding(.vertical, 9)
            result
            if translator.phase == .done || translator.phase == .translating && translator.hasText {
                actions.padding(.top, 12)
            } else if case .failed = translator.phase {
                HStack(spacing: 6) {
                    Spacer()
                    if translator.engine != .apple {
                        PillButton(title: "去设置", style: .plain) { model.openSettings(.translate) }
                        if translator.engines.contains(.apple) {
                            PillButton(title: "改用本机翻译", style: .plain) { translator.use(.apple) }
                        }
                    }
                    PillButton(title: "完成", style: .plain) { model.go(.collapsed) }
                }
                .padding(.top, 12)
            } else if translator.phase == .needsDownload {
                HStack(spacing: 6) {
                    Spacer()
                    PillButton(title: "完成", style: .plain) { model.go(.collapsed) }
                    if let other = translator.engines.first(where: { $0 != .apple }) {
                        PillButton(title: "改用\(translator.label(other))", style: .plain) { translator.use(other) }
                    }
                    PillButton(title: "去下载语言", style: .primary) { model.openSettings(.translate) }
                }
                .padding(.top, 12)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(translator.from.map(TranslateLanguage.name) ?? (translator.engine == .apple ? "未知语言" : "自动识别")).foregroundStyle(Palette.muted)
            Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.dim)
            Button {
                let languages = TranslateLanguage.all.filter { $0 != translator.from }
                ChoiceMenu(title: "译成…", items: languages.map { (TranslateLanguage.name($0), $0 == translator.to) }) { translator.retarget(languages[$0]) }.popUp()
            } label: {
                HStack(spacing: 3) {
                    Text(TranslateLanguage.name(translator.to))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Palette.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("换一种语言")
            Spacer(minLength: 8)
            if let app = translator.app {
                Text("来自 \(app) ·").foregroundStyle(Palette.dim).lineLimit(1).fixedSize()
            }
            engineChip
        }
        .font(.system(size: 12, weight: .medium))
    }

    /// Who translated it; with more than one engine set up, a menu to have another one try.
    @ViewBuilder private var engineChip: some View {
        let engines = translator.engines
        if engines.count > 1 {
            Button {
                ChoiceMenu(title: "换一种方式翻译", items: engines.map { (translator.label($0), $0 == translator.engine) }) { translator.use(engines[$0]) }.popUp()
            } label: {
                HStack(spacing: 3) {
                    Text(translator.label(translator.engine)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Palette.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("换一种方式翻译")
        } else {
            Text(translator.label(translator.engine)).foregroundStyle(Palette.dim).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private var result: some View {
        switch translator.phase {
        case .checking: progress
        case .translating where !translator.hasText: progress
        case .needsDownload:
            note("还没有下载\(TranslateLanguage.name(translator.from ?? ""))和\(TranslateLanguage.name(translator.to))的语言包",
                 "语言包由 macOS 下载，之后翻译都在本机完成，不联网。")
        case .unsupported:
            note("macOS 的翻译不支持这两种语言之间互译", "点上面的语言换一种试试。")
        case .unknownLanguage:
            note("认不出这段文字是哪种语言", "文字太短或混着多种语言时会这样。")
        case .failed(let message):
            note("翻译没有成功", message)
        default:
            ScrollView {
                Text(translator.translation)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            if translator.cut {
                Text("只翻译了前 \(TranslatePieces.limit) 个字").font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.top, 6)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progressText).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
        }
    }

    private var progressText: String {
        switch translator.engine {
        case .apple: "正在本机翻译…"
        case .model: "正在请 \(translator.label(.model)) 翻译…"
        case .agent: "正在请 \(translator.label(.agent)) 翻译…第一次要先启动它，需要几秒"
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { translator.speak() } label: {
                Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("朗读译文")
            Spacer()
            SendToAgentButton { .text(translator.translation) }
            if translator.canReplace {
                PillButton(title: "替换原文", style: .plain) {
                    let text = translator.translation
                    model.go(.collapsed)
                    SelectedText.replace(in: translator.field, with: text, clipboard: model.toolbox.clipboard)
                }
                .help("把选中的原文换成译文")
            }
            PillButton(title: "完成", style: .plain) { model.go(.collapsed) }
            PillButton(title: copied ? "已复制" : "复制", style: .primary) {
                model.toolbox.clipboard.copy(translator.translation, app: "翻译")
                copied = true
                model.go(.collapsed)
            }
        }
    }
}

/// A short list to pick from, as a menu at the pointer (SwiftUI's own would not match the island): the languages to
/// translate into, or who translates.
@MainActor
final class ChoiceMenu: NSObject {
    private let title: String
    private let items: [(String, Bool)]
    private let pick: (Int) -> Void

    init(title: String, items: [(String, Bool)], pick: @escaping (Int) -> Void) {
        self.title = title
        self.items = items
        self.pick = pick
    }

    func popUp() {
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        for (index, (name, chosen)) in items.enumerated() {
            let item = menu.addItem(withTitle: name, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = chosen ? .on : .off
        }
        // The menu runs its own loop: this object lives until it closes.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func chosen(_ item: NSMenuItem) { pick(item.tag) }
}
