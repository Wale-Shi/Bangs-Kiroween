import BangsCore
import SwiftUI

/// What the right of the closed notch shows: the agents' activity, a meeting about to start, and the CPU or memory load.
/// One alone is shown plainly: three bars, the time left, the percentage. Together they nest: the bars shrink into the
/// meeting's countdown ring, and four dots under them count the load.
struct NotchStatus: Equatable {
    enum Activity: Equatable {
        case working
        /// Waiting for your answer: the bars turn orange.
        case asking
        /// Finished and not yet looked at.
        case done
    }

    /// Whose countdown the ring shows.
    enum Tint: Equatable { case meeting, focus, rest }

    var activity: Activity?
    /// When the meeting starts, while its countdown runs; or when a focus or break ends.
    var meeting: Date?
    /// How long before a meeting its countdown starts; the length of a focus or break.
    var lead: TimeInterval = 300
    /// The load, 0 to 1.
    var usage: Double?
    var tint: Tint = .meeting
    /// A paused focus: the countdown stands still as it was at this moment.
    var frozen: Date?

    var count: Int { [activity != nil, meeting != nil, usage != nil].filter { $0 }.count }
    var isEmpty: Bool { count == 0 }
    /// The meeting or the load on its own is written out.
    var spelled: Bool { count == 1 && activity == nil }

    /// Lit dots for the load: one per 25%.
    static func lit(_ usage: Double) -> Int { min(4, Int((usage * 100).rounded(.down)) / 25) }

    static func usageColor(_ usage: Double) -> Color {
        switch lit(usage) {
        case 4: Palette.danger
        case 3: Palette.warn
        default: Palette.ink
        }
    }

    /// Blue while the meeting is a way off, orange in its last 30%.
    static func meetingColor(left: Double) -> Color { left > 0.3 ? Palette.meeting : Palette.warn }

    /// A meeting turns orange as it nears; a focus stays blue and a break green.
    func color(left: Double) -> Color {
        switch tint {
        case .meeting: Self.meetingColor(left: left)
        case .focus: Palette.meeting.opacity(frozen == nil ? 1 : 0.5)
        case .rest: Palette.ok.opacity(frozen == nil ? 1 : 0.5)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds.rounded(.up)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)

    /// How wide a side of the closed notch needs to be: room for the ring, or for the value written out, measured with
    /// as many digits as it has now (a countdown only loses digits, so it never outgrows the room it was given).
    func width(at now: Date = Date()) -> CGFloat {
        guard spelled else { return NotchGeometry.side }
        let now = frozen ?? now
        let text = meeting.map { Self.clock($0.timeIntervalSince(now)) } ?? ((usage ?? 0) >= 0.995 ? "100%" : "88%")
        let digits = String(text.map { $0.isNumber ? "8" : $0 })
        return max(NotchGeometry.side, ceil((digits as NSString).size(withAttributes: [.font: Self.font]).width) + 10)
    }
}

struct NotchStatusView: View {
    let status: NotchStatus
    /// Off while the island is tucked into the notch: nothing to see, so nothing moves.
    var live = true
    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        // Drawn by SwiftUI (snapshots), the bars move all the time; as layers they play themselves, and only a meeting's
        // seconds need redrawing.
        let moving = live && !Self.reduceMotion && !LayerMotion.usesLayers && (status.activity == .working || status.activity == .asking)
        TimelineView(.animation(minimumInterval: moving ? 1 / 30 : 1 / 2, paused: !live || (!moving && (status.meeting == nil || status.frozen != nil)))) { context in
            content(at: status.frozen ?? context.date)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: layout)
    }

    /// What changes the arrangement, for the transition between them.
    private var layout: [Bool] { [status.activity != nil, status.meeting != nil, status.usage != nil, status.spelled] }

    @ViewBuilder private func content(at now: Date) -> some View {
        let left = status.meeting.map { max(0, min(1, $0.timeIntervalSince(now) / status.lead)) }
        ZStack {
            if status.spelled {
                if let meeting = status.meeting, let left {
                    Text(NotchStatus.clock(meeting.timeIntervalSince(now)))
                        .foregroundStyle(status.color(left: left))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else if let usage = status.usage {
                    Text("\(Int((usage * 100).rounded()))%")
                        .foregroundStyle(NotchStatus.usageColor(usage))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            } else {
                if let left {
                    Circle().stroke(Palette.wash(0.18), lineWidth: 2)
                        .overlay(Circle().trim(from: 0, to: left).stroke(status.color(left: left), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)))
                        .frame(width: 19, height: 19)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
                VStack(spacing: status.meeting != nil ? 2 : 3) {
                    if let activity = status.activity {
                        Group {
                            if LayerMotion.usesLayers && activity != .done {
                                PulseBars(asking: activity == .asking, running: live, size: 13 * activityScale)
                            } else {
                                ActivityGlyph(activity: activity, time: now.timeIntervalSinceReferenceDate).scaleEffect(activityScale)
                            }
                        }
                        .frame(width: 13 * activityScale, height: 13 * activityScale)
                            .transition(.opacity.combined(with: .scale(scale: 0.5)))
                    }
                    if let usage = status.usage {
                        UsageDots(usage: usage)
                            .scaleEffect(status.meeting != nil ? 0.8 : 1)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
        .font(Font(NotchStatus.font))
    }

    private var activityScale: CGFloat {
        switch (status.meeting != nil, status.usage != nil) {
        case (true, true): 0.5
        case (true, false): 0.58
        case (false, true): 0.78
        case (false, false): 1
        }
    }
}

/// Three bars stretching one after another while an agent works; a green tick once it is done.
private struct ActivityGlyph: View {
    let activity: NotchStatus.Activity
    let time: TimeInterval

    var body: some View {
        switch activity {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ok)
        case .working, .asking:
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    // Each bar follows the one before it by a sixth of a beat.
                    let phase = (time / 0.9 - Double(index) / 6) * 2 * .pi
                    Capsule()
                        .fill(activity == .asking ? Palette.warn : Palette.ink)
                        .frame(width: 3, height: 13)
                        .scaleEffect(y: 0.3 + 0.7 * (0.5 - 0.5 * cos(phase)), anchor: .center)
                }
            }
            .frame(width: 13, height: 13)
        }
    }
}

/// Four dots for the load, one lit per 25%: orange with three lit, red with four.
private struct UsageDots: View {
    let usage: Double

    var body: some View {
        let lit = NotchStatus.lit(usage)
        HStack(spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                Circle().fill(index < lit ? NotchStatus.usageColor(usage) : Palette.wash(0.22)).frame(width: 2.6, height: 2.6)
            }
        }
        .animation(.easeOut(duration: 0.3), value: lit)
    }
}

/// The closed notch's two sides, equally wide so the island stays centred on the notch: the agent that matters most on
/// the left (Bangs' own face when no agent is about), how it is going on the right.
struct ClosedNotch: View {
    let harness: Harness?
    let others: Int
    let status: NotchStatus
    /// Bangs' face, for the left when there is no agent to show.
    let pointer: Pointer
    let awake: Bool
    let side: CGFloat
    var live = true

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if harness != nil {
                    NotchLeading(harness: harness, others: others)
                } else {
                    NotchFace(pointer: pointer, awake: awake).transition(.opacity)
                }
            }
            .frame(width: side)
            Spacer(minLength: 0)
            NotchStatusView(status: status, live: live).frame(width: side)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: harness)
    }
}

/// The left of the closed notch: the agent that matters most, with a count of the other sessions.
struct NotchLeading: View {
    let harness: Harness?
    let others: Int

    var body: some View {
        if let harness {
            HarnessIcon(harness: harness, size: 14)
                .overlay(alignment: .bottomTrailing) {
                    if others > 0 {
                        Text("+\(others)")
                            .font(.system(size: 7.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, 2.5)
                            .frame(minWidth: 11, minHeight: 9)
                            .background(Capsule().fill(Color(white: 0.24)))
                            .offset(x: 6, y: 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: others)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }
}

/// Where Bangs' face in the notch looks: towards the pointer, a little, and asleep after a minute without it.
@MainActor
final class Pointer: ObservableObject {
    /// How far the eyes are turned, in the face's own units (it is 64 wide).
    @Published private(set) var look = CGSize.zero
    @Published private(set) var asleep = false
    private var sleep: DispatchWorkItem?
    private var scheduled = Date.distantPast
    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init() { rest() }

    /// The pointer moved to `point`; the face is at `face`, both in screen coordinates.
    func moved(to point: CGPoint, face: CGPoint) {
        if asleep { asleep = false }
        // Rescheduling the nap on every event would be wasteful; once a second is plenty.
        if Date().timeIntervalSince(scheduled) > 1 { rest() }
        guard !Self.reduceMotion else { return }
        let dx = point.x - face.x, dy = face.y - point.y
        let distance = max(1, hypot(dx, dy))
        // Close by the eyes barely turn; from 400 pt away they are fully round.
        let reach = min(1, distance / 400)
        let quarter = { (value: CGFloat) in (value * 4).rounded() / 4 }
        let next = CGSize(width: quarter(dx / distance * reach * 5), height: quarter(dy / distance * reach * 3))
        if next != look { look = next }
    }

    private func rest() {
        scheduled = Date()
        sleep?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.asleep = true }
        sleep = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
}

/// Bangs' face alone, for the notch: the fringe and two eyes that follow the pointer and close when it rests.
struct NotchFace: View {
    @ObservedObject var pointer: Pointer
    /// Keep-awake is on: the Mac does not sleep, nor does Bangs.
    var awake = false
    var size: CGFloat = 17

    var body: some View {
        let asleep = pointer.asleep && !awake
        ZStack(alignment: .topLeading) {
            // The fringe spans 21–79 across and 19–51 down in the status icon's 100-unit box.
            StatusGlyph.hair.offsetBy(dx: -18, dy: -16).fill(Palette.ink)
            ForEach([38, 62], id: \.self) { (x: CGFloat) in
                if asleep {
                    Path { path in
                        path.move(to: CGPoint(x: x - 24, y: 47))
                        path.addQuadCurve(to: CGPoint(x: x - 12, y: 47), control: CGPoint(x: x - 18, y: 52))
                    }
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .transition(.opacity)
                } else {
                    Circle().fill(Palette.ink)
                        .frame(width: 12, height: 12)
                        .position(x: x - 18 + pointer.look.width, y: 47 + pointer.look.height)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 64, height: 56, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pointer.look)
        .animation(.easeInOut(duration: 0.3), value: asleep)
        .scaleEffect(size / 64, anchor: .topLeading)
        .frame(width: size, height: size * 56 / 64, alignment: .topLeading)
    }
}
