import AppKit
import EventKit
import SwiftUI

/// Today's meetings from the system calendars (iCloud, Google, Exchange… whatever is set up in Calendar.app),
/// with a nudge a few minutes before each one starts (five unless you choose otherwise) and another as it starts.
@MainActor
final class Agenda: ObservableObject {
    struct Meeting: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let place: String
        let join: URL?
        let service: String?
        let color: NSColor
    }

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access
    @Published private(set) var meetings: [Meeting] = []
    var onReminder: (Meeting) -> Void = { _ in }
    /// How long before a meeting the first nudge comes and its countdown starts.
    var lead: TimeInterval = 300 { didSet { objectWillChange.send(); schedule() } }
    /// A second nudge as a meeting starts.
    var remindsAtStart = true { didSet { schedule() } }
    /// Only meetings with a link to join count down and remind.
    var linkedOnly = false { didSet { objectWillChange.send(); schedule() } }
    /// The meetings whose countdown and closed-island line were showing at the last tick, to redraw as one starts or ends.
    private var counting: String?
    private var near: String?

    private let store = EKEventStore()
    private var reminded: Set<String> = []
    private var timer: Timer?
    private var lastRefresh = Date.distantPast

    init() {
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func requestAccess() {
        Task { @MainActor in
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
            if !granted { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
            refresh()
        }
    }

    /// The next meeting starting within ten minutes (or under way for its first five), for the closed island.
    var upcoming: Meeting? { upcoming(at: Date()) }

    private func upcoming(at now: Date) -> Meeting? {
        remindable.first { $0.start.timeIntervalSince(now) <= 600 && now.timeIntervalSince($0.start) < 300 }
    }

    /// The meetings that count down and remind.
    private var remindable: [Meeting] { linkedOnly ? meetings.filter { $0.join != nil } : meetings }

    /// The next meeting while its countdown runs: from `lead` before it until it starts.
    func countdown(at now: Date = Date()) -> Meeting? {
        remindable.first { let left = $0.start.timeIntervalSince(now); return left > 0 && left <= lead }
    }

    private func tick() {
        if Date().timeIntervalSince(lastRefresh) >= Self.refreshInterval { refresh() }
        let now = Date()
        for (key, meeting) in dueReminders(at: now) {
            reminded.insert(key)
            onReminder(meeting)
        }
        // As the countdown or the closed island's meeting appears or ends, and every 15 s for the minutes left while a
        // meeting is near; with none, never.
        let current = countdown(at: now)?.id, close = upcoming(at: now)?.id
        if current != counting || close != near || close != nil {
            counting = current
            near = close
            objectWillChange.send()
        }
        schedule()
    }

    static let refreshInterval: TimeInterval = 300

    /// Once ahead of each meeting, once as it starts.
    private func dueReminders(at now: Date) -> [(key: String, meeting: Meeting)] {
        remindable.flatMap { meeting in
            let left = meeting.start.timeIntervalSince(now)
            return [("\(meeting.id)-ahead", left <= lead && left > 0), ("\(meeting.id)-start", remindsAtStart && left <= 0 && left > -60)]
                .filter { $0.1 && !reminded.contains($0.0) }.map { (key: $0.0, meeting: meeting) }
        }
    }

    /// The next moment `tick` has something to do: a nudge, a countdown or the closed island's meeting starting or
    /// ending, the 15 s redraw while one is near, or the five-minute refresh (which also notices access granted in
    /// System Settings). Nothing ticks in between, so a day without meetings wakes Bangs only for the refresh.
    func nextWake(after now: Date) -> Date {
        // A nudge already due (a meeting just added, or the lead just changed) goes out now.
        if !dueReminders(at: now).isEmpty { return now.addingTimeInterval(0.05) }
        var next = lastRefresh.addingTimeInterval(Self.refreshInterval)
        func consider(_ date: Date) { if date > now, date < next { next = date } }
        for meeting in remindable {
            consider(meeting.start.addingTimeInterval(-lead))
            consider(meeting.start)
            consider(meeting.start.addingTimeInterval(-600))
            consider(meeting.start.addingTimeInterval(300))
        }
        if upcoming(at: now) != nil { consider(now.addingTimeInterval(15)) }
        return max(next, now.addingTimeInterval(0.05))
    }

    private func schedule() {
        timer?.invalidate()
        let now = Date(), at = nextWake(after: now)
        // A hair late rather than early, so the moment has passed when the tick looks.
        let timer = Timer(fire: at.addingTimeInterval(0.01), interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        // Some slack lets macOS wake Bangs together with other work instead of on the dot; more when it is only the refresh.
        timer.tolerance = at.timeIntervalSince(now) > 60 ? 5 : 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Access granted (or taken away) in System Settings while Bangs runs counts from the next refresh.
    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    func refresh() {
        lastRefresh = Date()
        let current = Self.currentAccess()
        if current != access { access = current }
        defer { schedule() }
        guard access == .granted else { meetings = []; return }
        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: endOfDay, calendars: nil)
        meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let join = Self.joinLink(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
                return Meeting(id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
                               title: event.title ?? "（无标题）", start: event.startDate, end: event.endDate,
                               place: event.location ?? "", join: join, service: join.flatMap(Self.service),
                               color: event.calendar.color ?? .systemBlue)
            }
    }

    /// A meeting you said no to neither counts down nor reminds.
    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|vc\.feishu\.cn/j|vc\.larksuite\.com/j|meeting\.tencent\.com/(dm|p|s)/|voovmeeting\.com/|webex\.com/|meeting\.dingtalk\.com/)[^\s<>"']*"#,
        options: [.caseInsensitive])

    static func joinLink(in texts: [String]) -> URL? {
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            if let match = pattern.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
                return URL(string: String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ">).,;")))
            }
        }
        return nil
    }

    static func service(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let names = [("zoom.us", "Zoom"), ("meet.google", "Google Meet"), ("teams.", "Teams"), ("feishu", "飞书会议"), ("larksuite", "Lark"),
                     ("meeting.tencent", "腾讯会议"), ("voovmeeting", "VooV"), ("webex", "Webex"), ("dingtalk", "钉钉会议")]
        return names.first { host.contains($0.0) }?.1
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "9 分钟后", "进行中", "1 小时 20 分钟后".
    static func until(_ meeting: Meeting, now: Date = Date()) -> String {
        let seconds = meeting.start.timeIntervalSince(now)
        if seconds <= 0 { return meeting.end > now ? "已开始" : "已结束" }
        let minutes = Int(ceil(seconds / 60))
        return minutes < 60 ? "\(minutes) 分钟后" : "\(minutes / 60) 小时\(minutes % 60 > 0 ? " \(minutes % 60) 分钟" : "")后"
    }
}

struct AgendaView: View {
    @ObservedObject var agenda: Agenda

    var body: some View {
        Group { content }
            // Permission may have been granted in System Settings since.
            .onAppear { agenda.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch agenda.access {
        case .unknown, .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("读取系统日历").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text("Bangs 会列出今天剩下的日程，开会前 \(Int(agenda.lead / 60)) 分钟在刘海里提醒，识别 Zoom、Google Meet、Teams、飞书、腾讯会议的链接一键入会。日历内容只在本机读取。")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    PillButton(title: agenda.access == .denied ? "打开系统设置" : "允许访问日历", style: .primary) { agenda.requestAccess() }
                }
            }
        case .granted:
            if agenda.meetings.isEmpty {
                Text("今天没有其他日程了").font(.system(size: 12.5)).foregroundStyle(Palette.muted).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(agenda.meetings.prefix(6).enumerated()), id: \.element.id) { index, meeting in
                        if index == 0 { MeetingCard(meeting: meeting) } else { MeetingRow(meeting: meeting) }
                    }
                    if agenda.meetings.count > 6 {
                        Text("还有 \(agenda.meetings.count - 6) 个日程").font(.system(size: 11)).foregroundStyle(Palette.dim)
                    }
                }
            }
        }
    }
}

struct MeetingCard: View {
    let meeting: Agenda.Meeting

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: meeting.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text([ "\(Agenda.time(meeting.start))–\(Agenda.time(meeting.end))", Agenda.until(meeting, now: context.date), meeting.service ?? meeting.place ]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            Spacer()
            if let join = meeting.join {
                PillButton(title: "加入", style: .warn) { NSWorkspace.shared.open(join) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.wash(0.06)))
        .padding(.bottom, 4)
    }
}

struct MeetingRow: View {
    let meeting: Agenda.Meeting

    var body: some View {
        HStack(spacing: 12) {
            Text(Agenda.time(meeting.start)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.dim).frame(width: 38, alignment: .leading)
            Circle().fill(Color(nsColor: meeting.color)).frame(width: 6, height: 6)
            Text(meeting.title).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
            Spacer()
            if let join = meeting.join {
                Button { NSWorkspace.shared.open(join) } label: {
                    Text(meeting.service ?? "入会").font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            } else if !meeting.place.isEmpty {
                Text(meeting.place).font(.system(size: 11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }
}
