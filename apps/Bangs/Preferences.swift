import AppKit
import BangsCore
import SwiftUI

/// The user's choices, kept in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    /// `auto` uses the notch when this Mac has one and the menu bar otherwise.
    enum Placement: String, CaseIterable { case auto, menuBar }
    /// How much of the island stays out while nothing is open.
    enum NotchStyle: String, CaseIterable {
        /// Always beside the notch.
        case always
        /// Tucked into the notch while nothing runs; it peeks out under the pointer.
        case autoHide
        /// Notch-sized until a decision or an alert opens it; a click on the notch opens the list.
        case hidden
    }

    private let defaults = UserDefaults.standard

    @Published var notchStyle: NotchStyle { didSet { defaults.set(notchStyle.rawValue, forKey: "notchStyle") } }
    @Published var placement: Placement { didSet { defaults.set(placement.rawValue, forKey: "placement") } }
    /// Global shortcuts by action; an action missing here has none (the user turned it off, or it has no default).
    @Published var shortcuts: [ShortcutAction: Shortcut] {
        didSet { defaults.set(try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, shortcuts[$0]) })), forKey: "shortcuts") }
    }
    /// The settings window is recording a new shortcut, so the current ones must not fire.
    @Published var recordingShortcut = false

    /// Clipboard history: how many items and how many days to keep (0 days keeps them until the count limit).
    @Published var clipboardLimit: Int { didSet { defaults.set(clipboardLimit, forKey: "clipboardLimit") } }
    @Published var clipboardDays: Int { didSet { defaults.set(clipboardDays, forKey: "clipboardDays") } }
    /// Return pastes into the app in front (needs Accessibility); off, it only copies.
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    /// Files dragged out of the shelf leave it.
    @Published var shelfRemovesOnDragOut: Bool { didSet { defaults.set(shelfRemovesOnDragOut, forKey: "shelfRemovesOnDragOut") } }
    /// The load the closed island shows on the right.
    enum Usage: String, CaseIterable { case off, cpu, memory }
    @Published var usageInNotch: Usage { didSet { defaults.set(usageInNotch.rawValue, forKey: "usageInNotch") } }
    /// Minutes before a meeting that its countdown starts and the island reminds you.
    @Published var meetingLead: Int { didSet { defaults.set(meetingLead, forKey: "meetingLead") } }
    /// Ask GitHub once a day whether a newer Bangs is out. Off unless you turn it on: Bangs otherwise never goes online.
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    var lastUpdateCheck: Date { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    /// A version you chose to skip: the daily check does not offer it again.
    var skippedVersion: String { didSet { defaults.set(skippedVersion, forKey: "skippedVersion") } }
    /// The island's tabs in your order, and those you turned off. Sessions always come first and cannot be hidden.
    @Published var toolOrder: [Tool] { didSet { defaults.set(toolOrder.map(\.rawValue), forKey: "toolOrder") } }
    @Published var hiddenTools: Set<Tool> { didSet { defaults.set(hiddenTools.map(\.rawValue), forKey: "hiddenTools") } }

    /// After a screenshot: a preview in the island, or only the copy.
    @Published var shotPreview: Bool { didSet { defaults.set(shotPreview, forKey: "shotPreview") } }
    /// A region screenshot stays on screen with the annotation toolbar until you finish it, as in other tools; off, it is
    /// copied at once.
    @Published var shotAnnotate: Bool { didSet { defaults.set(shotAnnotate, forKey: "shotAnnotate") } }
    /// Where a screenshot is also saved, besides the pasteboard.
    enum ShotFolder: String, CaseIterable { case none, desktop, downloads }
    @Published var shotFolder: ShotFolder { didSet { defaults.set(shotFolder.rawValue, forKey: "shotFolder") } }
    /// Text recognition: the languages to read, whether wrapped lines join into paragraphs, whether the island shows
    /// what was read, and whether a lone link gets an Open button.
    @Published var ocrLanguage: TextRecognition.Language { didSet { defaults.set(ocrLanguage.rawValue, forKey: "ocrLanguage") } }
    @Published var ocrJoinsLines: Bool { didSet { defaults.set(ocrJoinsLines, forKey: "ocrJoinsLines") } }
    @Published var ocrShowsResult: Bool { didSet { defaults.set(ocrShowsResult, forKey: "ocrShowsResult") } }
    @Published var ocrOpensLinks: Bool { didSet { defaults.set(ocrOpensLinks, forKey: "ocrOpensLinks") } }
    /// A region that holds a table is copied as one, to paste into a spreadsheet cell by cell.
    @Published var ocrTables: Bool { didSet { defaults.set(ocrTables, forKey: "ocrTables") } }

    /// Clipboard transforms: on or off, which kinds, timestamps in UTC or local time, and whether a result joins the history.
    @Published var transforms: Bool { didSet { defaults.set(transforms, forKey: "transforms") } }
    @Published var transformKinds: Set<Transform.Kind> { didSet { defaults.set(transformKinds.map(\.rawValue), forKey: "transformKinds") } }
    @Published var transformsInUTC: Bool { didSet { defaults.set(transformsInUTC, forKey: "transformsInUTC") } }
    @Published var transformKeepsResult: Bool { didSet { defaults.set(transformKeepsResult, forKey: "transformKeepsResult") } }

    /// Focus timer: minutes of focus and of the two breaks, what starts by itself, and what happens meanwhile.
    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var shortBreakMinutes: Int { didSet { defaults.set(shortBreakMinutes, forKey: "shortBreakMinutes") } }
    @Published var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: "longBreakMinutes") } }
    @Published var focusStartsBreak: Bool { didSet { defaults.set(focusStartsBreak, forKey: "focusStartsBreak") } }
    @Published var breakStartsFocus: Bool { didSet { defaults.set(breakStartsFocus, forKey: "breakStartsFocus") } }
    @Published var focusInNotch: Bool { didSet { defaults.set(focusInNotch, forKey: "focusInNotch") } }
    @Published var focusAlerts: Bool { didSet { defaults.set(focusAlerts, forKey: "focusAlerts") } }
    /// A system sound's name, or empty for none.
    @Published var focusSound: String { didSet { defaults.set(focusSound, forKey: "focusSound") } }
    /// While focusing, a finished agent only lights its dot; approvals still open the island.
    @Published var focusQuiet: Bool { didSet { defaults.set(focusQuiet, forKey: "focusQuiet") } }
    @Published var focusKeepsAwake: Bool { didSet { defaults.set(focusKeepsAwake, forKey: "focusKeepsAwake") } }
    /// Hold a MacBook's battery at `chargeLimit` percent (see ChargeLimit). Off until you turn it on: it needs a helper
    /// that runs as root.
    @Published var chargeLimitOn: Bool { didSet { defaults.set(chargeLimitOn, forKey: "chargeLimitOn") } }
    @Published var chargeLimit: Int { didSet { defaults.set(chargeLimit, forKey: "chargeLimit") } }

    /// Meetings: a second nudge as one starts, and only meetings with a link to join.
    @Published var meetingStartReminder: Bool { didSet { defaults.set(meetingStartReminder, forKey: "meetingStartReminder") } }
    @Published var meetingsWithLinkOnly: Bool { didSet { defaults.set(meetingsWithLinkOnly, forKey: "meetingsWithLinkOnly") } }
    /// The session search looks through past sessions too (Claude Code's and Codex's own records), archived ones if asked.
    @Published var sessionHistory: Bool { didSet { defaults.set(sessionHistory, forKey: "sessionHistory") } }
    @Published var historyIncludesArchived: Bool { didSet { defaults.set(historyIncludesArchived, forKey: "historyIncludesArchived") } }
    /// The key held during a scrolling screenshot to keep the scroll to one direction.
    @Published var scrollLockKey: HoldKey { didSet { defaults.set(try? JSONEncoder().encode(scrollLockKey), forKey: "scrollLockKey") } }
    /// File search: whether names are indexed at all (off until you start it), over the whole disk or home and the
    /// applications, and the folder names never gone into.
    @Published var fileSearch: Bool { didSet { defaults.set(fileSearch, forKey: "fileSearch") } }
    @Published var fileSearchWholeDisk: Bool { didSet { defaults.set(fileSearchWholeDisk, forKey: "fileSearchWholeDisk") } }
    @Published var fileExclusions: [String] { didSet { defaults.set(fileExclusions, forKey: "fileExclusions") } }
    /// Dragging files near the notch opens the shelf.
    @Published var shelfCatchesDrags: Bool { didSet { defaults.set(shelfCatchesDrags, forKey: "shelfCatchesDrags") } }
    /// The session list shows how much of each CLI's plan limits is used, and each session how full its context is.
    @Published var showsUsage: Bool { didSet { defaults.set(showsUsage, forKey: "showsUsage") } }
    /// When a turn ends, what it changed in its git checkout shows on the session.
    @Published var turnChanges: Bool { didSet { defaults.set(turnChanges, forKey: "turnChanges") } }
    /// Approval cards offer to allow requests like this one for the rest of the session. Off unless you turn it on.
    @Published var sessionAllow: Bool { didSet { defaults.set(sessionAllow, forKey: "sessionAllow") } }

    /// Translation: your language, which everything else is translated into, and the one your own goes to; and whether a
    /// selection that Accessibility cannot read is copied with ⌘C (the pasteboard is put back right after).
    @Published var translateMine: String {
        didSet {
            defaults.set(translateMine, forKey: "translateMine")
            if translateOther == translateMine { translateOther = TranslateLanguage.defaultOther(for: translateMine) }
        }
    }
    @Published var translateOther: String { didSet { defaults.set(translateOther, forKey: "translateOther") } }
    @Published var translateCopies: Bool { didSet { defaults.set(translateCopies, forKey: "translateCopies") } }
    /// How text is translated: on this Mac, by a model at an address you give (its key in the Keychain), or by a coding
    /// agent on this Mac over the Agent Client Protocol. The last two send the text out of Bangs; only when you choose them.
    @Published var translateEngine: TranslateEngine { didSet { defaults.set(translateEngine.rawValue, forKey: "translateEngine") } }
    @Published var translateAPIFormat: ModelAPI.Format { didSet { defaults.set(translateAPIFormat.rawValue, forKey: "translateAPIFormat") } }
    @Published var translateAPIURL: String { didSet { defaults.set(translateAPIURL, forKey: "translateAPIURL") } }
    @Published var translateAPIModel: String { didSet { defaults.set(translateAPIModel, forKey: "translateAPIModel") } }
    /// An ACPAgent.Preset's id, or "custom" for `translateAgentCommand`.
    @Published var translateAgent: String { didSet { defaults.set(translateAgent, forKey: "translateAgent") } }
    @Published var translateAgentCommand: String { didSet { defaults.set(translateAgentCommand, forKey: "translateAgentCommand") } }

    /// The tool the island opened on last time.
    /// Not published: remembering it must not redraw the island.
    var lastTool: String { didSet { defaults.set(lastTool, forKey: "lastTool") } }

    init() {
        // Up to 0.4 a switch: hide when idle, on by default.
        notchStyle = NotchStyle(rawValue: defaults.string(forKey: "notchStyle") ?? "")
            ?? (defaults.object(forKey: "autoHide") as? Bool == false ? .always : .autoHide)
        placement = Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .auto
        var shortcuts = ShortcutAction.defaults
        if let data = defaults.data(forKey: "shortcuts"), let stored = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            for (key, value) in stored { if let action = ShortcutAction(rawValue: key) { shortcuts[action] = value } }
        } else if let data = defaults.data(forKey: "shortcut") {
            // 0.2.0 kept a single shortcut for opening the list.
            shortcuts[.toggle] = try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        self.shortcuts = shortcuts
        clipboardLimit = defaults.object(forKey: "clipboardLimit") as? Int ?? 500
        clipboardDays = defaults.object(forKey: "clipboardDays") as? Int ?? 30
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        shelfRemovesOnDragOut = defaults.object(forKey: "shelfRemovesOnDragOut") as? Bool ?? true
        // Up to 0.4 a switch for the CPU alone.
        usageInNotch = Usage(rawValue: defaults.string(forKey: "usageInNotch") ?? "") ?? (defaults.bool(forKey: "cpuInNotch") ? .cpu : .off)
        meetingLead = defaults.object(forKey: "meetingLead") as? Int ?? 5
        checkForUpdates = defaults.bool(forKey: "checkForUpdates")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        skippedVersion = defaults.string(forKey: "skippedVersion") ?? ""
        lastTool = defaults.string(forKey: "lastTool") ?? "sessions"
        let stored = (defaults.stringArray(forKey: "toolOrder") ?? []).compactMap(Tool.init(rawValue:)).filter { $0 != .sessions }
        // Tools added since the order was saved go where they stand in the list: after the tool before them.
        var order = stored
        for tool in Tool.allCases where tool != .sessions && !order.contains(tool) {
            let before = Tool.allCases.prefix { $0 != tool }.last { order.contains($0) }
            order.insert(tool, at: before.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        toolOrder = order
        hiddenTools = Set((defaults.stringArray(forKey: "hiddenTools") ?? []).compactMap(Tool.init(rawValue:)))
        shotPreview = defaults.object(forKey: "shotPreview") as? Bool ?? true
        shotAnnotate = defaults.object(forKey: "shotAnnotate") as? Bool ?? true
        shotFolder = ShotFolder(rawValue: defaults.string(forKey: "shotFolder") ?? "") ?? .none
        ocrLanguage = TextRecognition.Language(rawValue: defaults.string(forKey: "ocrLanguage") ?? "") ?? .auto
        ocrJoinsLines = defaults.object(forKey: "ocrJoinsLines") as? Bool ?? true
        ocrShowsResult = defaults.object(forKey: "ocrShowsResult") as? Bool ?? true
        ocrOpensLinks = defaults.object(forKey: "ocrOpensLinks") as? Bool ?? true
        ocrTables = defaults.object(forKey: "ocrTables") as? Bool ?? true
        transforms = defaults.object(forKey: "transforms") as? Bool ?? true
        transformKinds = defaults.stringArray(forKey: "transformKinds").map { Set($0.compactMap(Transform.Kind.init(rawValue:))) }
            ?? Set(Transform.Kind.allCases.filter { $0 != .naming })
        transformsInUTC = defaults.bool(forKey: "transformsInUTC")
        transformKeepsResult = defaults.object(forKey: "transformKeepsResult") as? Bool ?? true
        focusMinutes = defaults.object(forKey: "focusMinutes") as? Int ?? 25
        shortBreakMinutes = defaults.object(forKey: "shortBreakMinutes") as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: "longBreakMinutes") as? Int ?? 15
        focusStartsBreak = defaults.object(forKey: "focusStartsBreak") as? Bool ?? true
        breakStartsFocus = defaults.bool(forKey: "breakStartsFocus")
        focusInNotch = defaults.object(forKey: "focusInNotch") as? Bool ?? true
        focusAlerts = defaults.object(forKey: "focusAlerts") as? Bool ?? true
        focusSound = defaults.string(forKey: "focusSound") ?? "Glass"
        focusQuiet = defaults.object(forKey: "focusQuiet") as? Bool ?? true
        focusKeepsAwake = defaults.object(forKey: "focusKeepsAwake") as? Bool ?? true
        chargeLimitOn = defaults.bool(forKey: "chargeLimitOn")
        chargeLimit = (defaults.object(forKey: "chargeLimit") as? Int).map { min(max($0, ChargeLimit.range.lowerBound), ChargeLimit.range.upperBound) } ?? 80
        meetingStartReminder = defaults.object(forKey: "meetingStartReminder") as? Bool ?? true
        meetingsWithLinkOnly = defaults.bool(forKey: "meetingsWithLinkOnly")
        shelfCatchesDrags = defaults.object(forKey: "shelfCatchesDrags") as? Bool ?? true
        showsUsage = defaults.object(forKey: "showsUsage") as? Bool ?? true
        turnChanges = defaults.object(forKey: "turnChanges") as? Bool ?? true
        sessionAllow = defaults.bool(forKey: "sessionAllow")
        scrollLockKey = defaults.data(forKey: "scrollLockKey").flatMap { try? JSONDecoder().decode(HoldKey.self, from: $0) } ?? .space
        fileSearch = defaults.bool(forKey: "fileSearch")
        fileSearchWholeDisk = defaults.bool(forKey: "fileSearchWholeDisk")
        fileExclusions = defaults.stringArray(forKey: "fileExclusions") ?? FileIndex.defaultExclusions
        sessionHistory = defaults.object(forKey: "sessionHistory") as? Bool ?? true
        historyIncludesArchived = defaults.bool(forKey: "historyIncludesArchived")
        let mine = defaults.string(forKey: "translateMine").flatMap(TranslateLanguage.canonical) ?? TranslateLanguage.defaultMine
        translateMine = mine
        translateOther = defaults.string(forKey: "translateOther").flatMap(TranslateLanguage.canonical).flatMap { $0 == mine ? nil : $0 }
            ?? TranslateLanguage.defaultOther(for: mine)
        translateCopies = defaults.object(forKey: "translateCopies") as? Bool ?? true
        translateEngine = TranslateEngine(rawValue: defaults.string(forKey: "translateEngine") ?? "") ?? .apple
        translateAPIFormat = ModelAPI.Format(rawValue: defaults.string(forKey: "translateAPIFormat") ?? "") ?? .openAI
        translateAPIURL = defaults.string(forKey: "translateAPIURL") ?? ""
        translateAPIModel = defaults.string(forKey: "translateAPIModel") ?? ""
        translateAgent = defaults.string(forKey: "translateAgent") ?? "gemini"
        translateAgentCommand = defaults.string(forKey: "translateAgentCommand") ?? ""
    }

    /// The island's tabs, in order, without those turned off.
    var visibleTools: [Tool] { [.sessions] + toolOrder.filter { !hiddenTools.contains($0) } }

    func shows(_ tool: Tool) -> Bool { tool == .sessions || !hiddenTools.contains(tool) }

    func setShows(_ tool: Tool, _ shown: Bool) {
        guard tool != .sessions else { return }
        if shown { hiddenTools.remove(tool) } else { hiddenTools.insert(tool) }
    }
}

/// What a global shortcut does.
enum ShortcutAction: String, CaseIterable, Codable {
    case toggle, allowRequest, denyRequest, sessionSearch, fileSearch, clipboard, shotRegion, shotWindow, shotScroll, shotText, focus, translate

    /// Held only while a request waits for an answer; free for other apps the rest of the time.
    static let answers: Set<ShortcutAction> = [.allowRequest, .denyRequest]

    var title: String {
        switch self {
        case .toggle: "展开 / 收起"
        case .allowRequest: "允许审批请求"
        case .denyRequest: "拒绝审批请求"
        case .sessionSearch: "搜索会话"
        case .fileSearch: "搜索文件"
        case .clipboard: "打开剪贴板历史"
        case .shotRegion: "选区截图"
        case .shotWindow: "窗口截图"
        case .shotScroll: "滚动截图"
        case .shotText: "截图识字"
        case .focus: "开始 / 暂停专注"
        case .translate: "翻译选中的文字"
        }
    }

    /// The tool whose settings page lists this shortcut; nil for Bangs itself and for translation, which has a page but
    /// no tab.
    var tool: Tool? {
        switch self {
        case .toggle, .allowRequest, .denyRequest, .translate: nil
        case .sessionSearch: .sessions
        case .fileSearch: .files
        case .clipboard: .clipboard
        case .shotRegion, .shotWindow, .shotScroll, .shotText: .screenshot
        case .focus: .focus
        }
    }

    /// ⌥⌘B opens the island; ⌥⌘↩ and ⌥⌘⌫ allow and deny a request, beside it and hard to press by accident while typing;
    /// ⇧⌘V the clipboard, as in most clipboard managers; ⇧⌘F finds files; ⌥⇧⌘T reads text off the screen and ⌥⌘T
    /// translates the selection (not ⌥D, as in other translators: in a terminal that deletes the next word). The
    /// screenshots have none, to keep the system's.
    static let defaults: [ShortcutAction: Shortcut] = [
        .toggle: Shortcut(keyCode: 11, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, key: "B"),
        .allowRequest: Shortcut(keyCode: 36, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, key: "↩"),
        .denyRequest: Shortcut(keyCode: 51, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, key: "⌫"),
        .fileSearch: Shortcut(keyCode: 3, modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue, key: "F"),
        .clipboard: Shortcut(keyCode: 9, modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue, key: "V"),
        .shotText: Shortcut(keyCode: 17, modifiers: NSEvent.ModifierFlags([.option, .shift, .command]).rawValue, key: "T"),
        .translate: Shortcut(keyCode: 17, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, key: "T"),
    ]
}

/// A key with modifiers, as recorded in the settings window.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    /// The key as printed on the keyboard.
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    /// Reads a shortcut from a key press, or nil without ⌃, ⌥ or ⌘ (a bare key would swallow typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        keyCode = event.keyCode
        modifiers = flags.rawValue
        key = Self.name(keyCode: event.keyCode) ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
    }

    init(keyCode: UInt16, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    static func name(keyCode: UInt16) -> String? {
        let names: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[keyCode]
    }
}

/// A key held down for as long as something should last: a key of its own (Space, a letter), or a modifier pressed alone.
struct HoldKey: Codable, Equatable {
    /// The key, or nil for a modifier on its own.
    var keyCode: UInt16?
    /// `NSEvent.ModifierFlags` raw value of the modifier, when that is the key.
    var modifier: UInt?
    var name: String

    static let space = HoldKey(keyCode: 49, modifier: nil, name: "空格")

    /// What this key may get in the way of, for the settings to say; nil when nothing is known to.
    var conflict: String? {
        switch flags {
        case .shift?: "用鼠标滚轮时，按住 ⇧ 会把上下滚动变成左右滚动，和锁定方向正好相反。建议换一个键。"
        case .function?: "按 fn 可能会触发听写、表情或切换输入法（看「键盘」设置）。建议换一个键。"
        default: nil
        }
    }

    var flags: NSEvent.ModifierFlags? { modifier.map(NSEvent.ModifierFlags.init(rawValue:)) }

    /// Return and Esc finish and cancel the capture, so they cannot hold anything.
    static let reserved: Set<UInt16> = [36, 76, 53]

    /// A key pressed on its own, or nil for a reserved one or one with modifiers held.
    init?(keyDown event: NSEvent) {
        guard event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty, !Self.reserved.contains(event.keyCode) else { return nil }
        keyCode = event.keyCode
        modifier = nil
        name = event.keyCode == 49 ? "空格" : Shortcut.name(keyCode: event.keyCode) ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty else { return nil }
    }

    /// A modifier pressed alone.
    init?(flagsChanged event: NSEvent) {
        let pressed = event.modifierFlags.intersection([.control, .option, .command, .shift, .function])
        let names: [(NSEvent.ModifierFlags, String)] = [(.option, "⌥ Option"), (.control, "⌃ Control"), (.shift, "⇧ Shift"), (.command, "⌘ Command"), (.function, "fn")]
        guard let match = names.first(where: { pressed == $0.0 }) else { return nil }
        keyCode = nil
        modifier = match.0.rawValue
        name = match.1
    }

    init(keyCode: UInt16?, modifier: UInt?, name: String) {
        self.keyCode = keyCode
        self.modifier = modifier
        self.name = name
    }
}
