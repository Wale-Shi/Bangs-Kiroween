import AppKit
import BangsCore
import Foundation

struct Session: Identifiable, Equatable {
    enum Status: Equatable { case idle, working, approval, finished }

    let id: String
    let harness: Harness
    var pid: pid_t
    var cwd: String
    var status: Status = .idle
    var prompt = ""
    var activity = ""
    var lastMessage = ""
    /// When the current turn started, for the elapsed time.
    var turnStartedAt: Date?
    var updatedAt = Date()
    /// Finished and not yet looked at.
    var unseen = false
    /// The CLI's transcript, where an interrupted turn shows (no hook says so).
    var transcript = ""
    /// When Bangs first heard of the session, and the parent its process had then.
    var firstSeen = Date()
    var parent: pid_t?
    /// Bangs ended the turn from its transcript; a Stop hook arriving late must not tell you again.
    var endedFromTranscript = false
    /// How full its context is, from its transcript (or Claude Code's status line, which also knows the window's size).
    var context: ContextFill?
    /// What its last turn changed in the project's git checkout; nil while a turn runs, or when it changed nothing.
    var changes: TurnChanges?
    /// Requests like these are allowed for the rest of the session without asking (see SessionRule).
    var rules: [SessionRule] = []

    var project: String { cwd.isEmpty ? harness.displayName : (cwd as NSString).lastPathComponent }
    /// The CLI's own id for the session (`id` is prefixed with the harness).
    var sessionId: String { String(id.dropFirst(harness.rawValue.count + 1)) }
    /// What to paste in a terminal to open this session again.
    var resumeCommand: String? { harness.resumeCommand(sessionId: sessionId, cwd: cwd) }
}

/// A tool call waiting for you. With a `reply` Bangs can answer it; without one (CLIs whose hooks cannot decide)
/// the CLI's own prompt is waiting in the terminal.
struct Approval: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let harness: Harness
    let project: String
    let tool: String
    let summary: String
    let reply: PendingReply?
    let pid: pid_t
    /// What the agent asks you to choose, when this is a question (AskUserQuestion) Bangs can answer.
    var questions: [AgentQuestion] = []
    /// Which call this is, to tell it from another call of the same tool: the CLI's id, and the input as `ToolCall`.
    var toolUseId: String?
    var input: ToolCall.Input?
    /// What the request may do beyond what it seems to, worked out as it arrives (no file is read for it).
    var risk: Risk?
    /// The files it would change, as diffs. Filled in off the main thread a moment after the request arrives.
    var changes: [FileChange] = []
    /// The rule that would allow requests like this one for the rest of the session, when one can.
    var sessionRule: SessionRule?
    /// The input as the CLI sent it, to tell whether a rule given later covers this request too.
    var rawInput: Any?

    var answerable: Bool { reply != nil }
    /// The same request, as far as its card shows: SwiftUI redraws it when its diff arrives.
    static func == (lhs: Approval, rhs: Approval) -> Bool { lhs.id == rhs.id && lhs.changes == rhs.changes }
}

/// A tool call that has run (PostToolUse), to find the request it settles.
struct ToolCall {
    /// The input's top-level fields, each as canonical JSON (a non-object input under ""), so inputs compare by value.
    typealias Input = [String: String]

    let tool: String
    let id: String?
    let input: Input?

    init(_ envelope: HookEnvelope) {
        tool = envelope.toolName
        id = envelope.toolUseId
        input = Self.input(envelope.toolInput)
    }

    static func input(_ value: Any?) -> Input? {
        guard let value, !(value is NSNull) else { return nil }
        func canonical(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed]) else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
        if let fields = value as? [String: Any] { return fields.isEmpty ? nil : fields.mapValues(canonical) }
        return ["": canonical(value)]
    }
}

extension Approval {
    /// Whether `call` is the call this request asked about. Two calls of one tool can wait at once (parallel calls, a
    /// sub-agent's), so the name alone would take the wrong one away: the CLI's call id decides when both have one, else
    /// the input. The input may come back with fields added (a question's answers), so the request's fields need only
    /// all be there unchanged. With nothing to compare, the name has to do, or the request would never go.
    func settled(by call: ToolCall) -> Bool {
        guard tool == call.tool else { return false }
        if let toolUseId, let id = call.id { return toolUseId == id }
        if let input, let ran = call.input { return input.allSatisfy { ran[$0.key] == $0.value } }
        return true
    }
}

/// Live state of every CLI session on this Mac, built from hook events.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = [] { didSet { updateReaper() } }
    @Published private(set) var approvals: [Approval] = []
    /// Fired when a session finishes a turn while you are not looking at its terminal.
    var onFinished: ((Session) -> Void)?
    /// The plans' limits, as the CLIs last reported them.
    let meter: UsageMeter
    /// Read limits and context from the transcripts and status line; git changes per turn; rules for the session.
    /// Off in tests unless one turns them on; the app follows the settings.
    var readsUsage = false
    var tracksChanges = false
    var allowsForSession = false
    /// Where each running turn began in its git checkout, worked out off the main thread as it starts.
    private var turnStarts: [String: Task<TurnStart?, Never>] = [:]
    /// When each session's transcript was last read for its usage.
    private var usageRead: [String: Date] = [:]

    init(meter: UsageMeter? = nil) {
        self.meter = meter ?? UsageMeter(persisted: false)
    }

    private var reaper: Timer?
    private var transcriptsRead: [String: Date] = [:]
    /// The clock, which tests set.
    var now: () -> Date = Date.init
    /// Whether you are looking at a session's terminal (its result needs no telling); tests set it.
    var watching: (pid_t) -> Bool = { Terminal.isFrontmost(for: $0) }
    /// How long a turn may go without a sign of life before it counts as dead, when its process cannot tell.
    static let silence: TimeInterval = 600
    /// A session left alone this long, with nothing new to show, leaves the list (the Codex app keeps every conversation
    /// you opened in one process, so they would otherwise stay until it quits). Its next event brings it back.
    static let forgotten: TimeInterval = 12 * 3600
    /// Sessions a CLI runs for itself (Codex naming a conversation), whose later events are dropped too.
    private var ownRequests: Set<String> = []
    /// Codex threads' sources, read once from their transcripts.
    private var threadSources: [String: String] = [:]
    /// The tool call each session's PreToolUse last reported, until it has run: what a terminal-side prompt is about.
    private var lastCalls: [String: (tool: String, input: Any?)] = [:]

    /// With no session there is nothing to reap: no timer wakes Bangs until a hook brings one in.
    private func updateReaper() {
        if sessions.isEmpty {
            reaper?.invalidate()
            reaper = nil
        } else if reaper == nil {
            reaper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reap() }
            }
            reaper?.tolerance = 0.5
        }
    }

    /// Whether the reaper runs; for tests.
    var reaping: Bool { reaper != nil }

    var working: [Session] { sessions.filter { $0.status == .working || $0.status == .approval } }
    var unseen: [Session] { sessions.filter(\.unseen) }
    /// Anything worth showing: a running turn, a decision waiting, or a result you have not seen.
    var active: Bool { !working.isEmpty || !approvals.isEmpty || !unseen.isEmpty }

    func receive(_ envelope: HookEnvelope, reply: PendingReply?) {
        if envelope.native == StatusLineRelay.event, envelope.harness == .claude {
            statusLine(envelope)
            reply?.answer(.terminal)
            return
        }
        guard let event = envelope.event else { reply?.answer(.terminal); return }
        let key = "\(envelope.harness.rawValue):\(envelope.sessionId)"
        if ownRequests.contains(key) || Self.isInternal(envelope) || internalThread(envelope, key: key) == true {
            ownRequests.insert(key)
            remove(key)
            reply?.answer(.terminal)
            return
        }
        if event == .sessionEnd {
            remove(key)
            return
        }
        var session = sessions.first { $0.id == key } ?? Session(id: key, harness: envelope.harness, pid: envelope.pid, cwd: envelope.cwd, firstSeen: now())
        if envelope.pid > 1, envelope.pid != session.pid || session.parent == nil {
            session.pid = envelope.pid
            session.parent = Processes.parent(of: envelope.pid)
        }
        if !envelope.cwd.isEmpty { session.cwd = envelope.cwd }
        if let path = envelope.transcriptPath { session.transcript = path }
        session.updatedAt = now()
        // Switched to running without approvals: a request still showing is answered by the CLI itself now.
        if envelope.approvesEverything {
            resolveWaits(key, keepingQuestions: true)
            if session.status == .approval, !approvals.contains(where: { $0.sessionId == key }) { session.status = .working }
        }

        switch event {
        case .sessionStart:
            session.status = .idle
        case .prompt:
            resolveWaits(key)
            session.status = .working
            session.unseen = false
            if let prompt = envelope.prompt { session.prompt = Self.oneLine(prompt) }
            session.activity = ""
            session.turnStartedAt = Date()
            session.endedFromTranscript = false
            session.changes = nil
            beginTurn(key, cwd: session.cwd)
        case .preTool:
            resolveTerminalWaits(key)
            begin(&session)
            session.activity = Self.describe(tool: envelope.toolName, input: envelope.toolInput)
            lastCalls[key] = envelope.toolName.isEmpty ? nil : (envelope.toolName, envelope.toolInput)
        case .postTool:
            lastCalls[key] = nil
            resolveWaits(key, ran: ToolCall(envelope))
            begin(&session)
            readUsage(of: session)
            if session.status == .approval, !approvals.contains(where: { $0.sessionId == key }) { session.status = .working }
        case .permissionRequest:
            begin(&session)
            // Nothing to ask while the CLI approves everything: handed back, it goes ahead on its own. A question
            // still waits for you.
            guard !envelope.approvesEverything || envelope.toolName == AgentQuestion.tool else {
                reply?.answer(.terminal)
                break
            }
            if let reply {
                let approval = approval(for: session, envelope: envelope, reply: reply)
                // Allowed for the session already: answered at once, and the session goes on.
                if allowsForSession, SessionRule.covers(session.rules, tool: approval.tool, input: envelope.toolInput, risk: approval.risk) {
                    reply.answer(.allow)
                    session.activity = "本会话已允许 · \(Self.oneLine(approval.summary, limit: 120))"
                    break
                }
                session.status = .approval
                approvals.append(approval)
                preview(approval, cwd: session.cwd)
            } else {
                session.status = .approval
            }
        case .notification:
            switch envelope.notificationKind {
            case .permission where !envelope.harness.answersPermissions:
                begin(&session)
                session.status = .approval
                if !approvals.contains(where: { $0.sessionId == key }) {
                    let approval = approval(for: session, envelope: envelope, reply: nil)
                    approvals.append(approval)
                    preview(approval, cwd: session.cwd)
                }
            case .idle where session.status == .working:
                // The turn is over and the session waits for you.
                session.status = .finished
            default:
                break
            }
        case .stop:
            resolveWaits(key)
            // Already ended from the transcript: the late hook only fills in the message.
            let told = session.endedFromTranscript
            session.endedFromTranscript = false
            session.status = .finished
            session.turnStartedAt = nil
            if let message = envelope.lastMessage { session.lastMessage = Self.oneLine(message) }
            session.activity = ""
            endTurn(key)
            readUsage(of: session, now: true)
            if !told, !watching(session.pid) {
                session.unseen = true
                upsert(session)
                onFinished?(session)
                return
            }
        case .sessionEnd:
            break
        }
        upsert(session)
    }

    /// Allows the request, and requests like it for the rest of its session: those waiting now, and those to come.
    func allowForSession(_ approval: Approval) {
        guard let rule = approval.sessionRule, let index = sessions.firstIndex(where: { $0.id == approval.sessionId }) else {
            answer(approval, with: .allow)
            return
        }
        if !sessions[index].rules.contains(rule) { sessions[index].rules.append(rule) }
        let rules = sessions[index].rules
        answer(approval, with: .allow)
        for other in approvals where other.sessionId == approval.sessionId && other.answerable
            && SessionRule.covers(rules, tool: other.tool, input: other.rawInput, risk: other.risk) {
            answer(other, with: .allow)
        }
    }

    /// Takes back the session's standing allows: its requests ask again.
    func clearRules(of session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].rules = [] }
    }

    func answer(_ approval: Approval, with decision: PermissionReply) {
        approval.reply?.answer(decision)
        approvals.removeAll { $0.id == approval.id }
        if let index = sessions.firstIndex(where: { $0.id == approval.sessionId }), !approvals.contains(where: { $0.sessionId == approval.sessionId }) {
            sessions[index].status = .working
            if decision == .deny { sessions[index].activity = "已拒绝 \(approval.tool)" }
        }
    }

    /// The hook went away (CLI timeout, Ctrl-C or the session ended) before you answered.
    func hangUp(_ id: ObjectIdentifier) {
        guard let approval = approvals.first(where: { $0.reply.map(ObjectIdentifier.init) == id }) else { return }
        approvals.removeAll { $0.id == approval.id }
        if let index = sessions.firstIndex(where: { $0.id == approval.sessionId }), sessions[index].status == .approval,
           !approvals.contains(where: { $0.sessionId == approval.sessionId }) {
            sessions[index].status = .working
        }
    }

    /// Puts a session on the list as it is, for snapshots.
    func seed(_ session: Session) { upsert(session) }

    /// Taken off the list by hand. Its next event brings it back.
    func dismiss(_ session: Session) { remove(session.id) }

    func markSeen(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].unseen = false }
    }

    /// Every finished session acknowledged at once, in one change so the list redraws once.
    func markAllSeen() {
        guard sessions.contains(where: \.unseen) else { return }
        sessions = sessions.map { var session = $0; session.unseen = false; return session }
    }

    private func approval(for session: Session, envelope: HookEnvelope, reply: PendingReply?) -> Approval {
        var tool = envelope.toolName, input = envelope.toolInput
        // CLIs whose prompt waits in the terminal say only that one does, in a notification: the call it is about is the
        // one their PreToolUse just reported.
        if tool.isEmpty, let call = lastCalls[session.id] {
            tool = call.tool
            input = call.input
        }
        let message = Self.oneLine(envelope.payload["message"] as? String ?? "")
        let summary = tool.isEmpty ? message : Self.describe(tool: tool, input: input, verbose: true)
        let questions = reply != nil && session.harness.answersQuestions && tool == AgentQuestion.tool ? AgentQuestion.parse(input) : []
        let edits = questions.isEmpty ? RequestPreview.edits(in: input) : []
        let risk = Risk.gravest([RequestPreview.command(in: input).flatMap { Risk.of(command: $0, cwd: session.cwd) }]
            + RequestPreview.paths(of: edits).map { Risk.of(path: $0, cwd: session.cwd) })
        let rule = reply != nil && questions.isEmpty ? SessionRule.rule(tool: tool, input: input, risk: risk) : nil
        return Approval(sessionId: session.id, harness: session.harness, project: session.project, tool: tool, summary: summary, reply: reply,
                        pid: session.pid, questions: questions, toolUseId: envelope.toolUseId, input: ToolCall.input(input), risk: risk,
                        sessionRule: rule, rawInput: input)
    }

    /// Works out the diffs of a request off the main thread (it reads the files it changes) and puts them on its card.
    private func preview(_ approval: Approval, cwd: String) {
        let edits = approval.questions.isEmpty ? RequestPreview.edits(in: approval.rawInput) : []
        guard !edits.isEmpty else { return }
        let id = approval.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let changes = RequestPreview.changes(edits, cwd: cwd)
            await self?.show(changes, on: id)
        }
    }

    /// Answered or gone by now: nothing to show it on.
    private func show(_ changes: [FileChange], on id: UUID) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals[index].changes = changes
    }

    /// A terminal-side prompt is over once the session moves on.
    private func resolveTerminalWaits(_ key: String) {
        approvals.removeAll { $0.sessionId == key && !$0.answerable }
    }

    /// Answered in the terminal or the agent's own window instead: the CLI goes on without hanging up on the hook, so a
    /// request is over once the tool it asked about has run (`ran`), or the turn has ended or moved on (nil). Bangs
    /// hands it back so the waiting hook exits without a decision.
    /// Questions are never answered by the CLI itself, so `keepingQuestions` leaves them waiting.
    private func resolveWaits(_ key: String, ran call: ToolCall? = nil, keepingQuestions: Bool = false) {
        let settled = approvals.filter { $0.sessionId == key && (!$0.answerable || call.map($0.settled(by:)) ?? true || $0.tool.isEmpty)
            && !(keepingQuestions && !$0.questions.isEmpty) }
        for approval in settled { approval.reply?.answer(.terminal) }
        approvals.removeAll { approval in settled.contains { $0.id == approval.id } }
    }

    private func begin(_ session: inout Session) {
        session.endedFromTranscript = false
        if session.status != .working && session.status != .approval {
            session.status = .working
            session.turnStartedAt = session.turnStartedAt ?? Date()
        }
        session.unseen = false
    }

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session } else { sessions.insert(session, at: 0) }
    }

    private func remove(_ key: String) {
        sessions.removeAll { $0.id == key }
        transcriptsRead[key] = nil
        lastCalls[key] = nil
        turnStarts[key]?.cancel()
        turnStarts[key] = nil
        usageRead[key] = nil
        for approval in approvals where approval.sessionId == key { approval.reply?.answer(.terminal) }
        approvals.removeAll { $0.sessionId == key }
    }

    /// Drops sessions whose CLI process has exited (they do not always send SessionEnd), and ends turns that ended
    /// without a hook saying so.
    func reap() {
        for session in sessions where !Processes.isAlive(session.pid) { remove(session.id) }
        for session in sessions where (session.status == .idle || session.status == .finished) && !session.unseen
            && now().timeIntervalSince(session.updatedAt) > Self.forgotten { remove(session.id) }
        var table: [pid_t: (parent: pid_t, start: Date)]?
        for session in sessions where session.status == .working || session.status == .approval {
            checkTranscript(session)
            if session.status == .working, let current = sessions.first(where: { $0.id == session.id }), current.status == .working {
                checkSilence(current, table: &table)
            }
        }
    }

    /// Stopped mid-turn (Esc, or a tool rejected), which no hook reports, or a Codex turn that ended or failed without
    /// its Stop hook: the transcript says so after the session's last event. It is read again only once it has changed.
    private func checkTranscript(_ session: Session) {
        guard !session.transcript.isEmpty, let modified = modification(of: session),
              modified > session.updatedAt, transcriptsRead[session.id] != modified else { return }
        guard let tail = Transcript.tail(of: session.transcript), let end = Transcript.end(in: tail),
              end.date > session.updatedAt.addingTimeInterval(-1) else {
            transcriptsRead[session.id] = modified
            return
        }
        switch end {
        case .interrupted:
            transcriptsRead[session.id] = modified
            interrupted(session.id)
        case .finished(let at, let message):
            // The Stop hook usually follows within a moment; only a turn it has left alone for a while is ended here.
            guard now().timeIntervalSince(at) > 8 else { return }
            transcriptsRead[session.id] = modified
            ended(session.id, message: message.map { Self.oneLine($0) } ?? "")
        case .failed(_, let message):
            transcriptsRead[session.id] = modified
            ended(session.id, message: message.isEmpty ? "出错，这一轮没有完成" : "出错：\(Self.oneLine(message))")
        }
    }

    /// A turn whose process outlives it says nothing when it dies: the Codex app's shared app-server keeps running, and a
    /// CLI whose terminal was closed under it can linger without one. Such a turn that has gone quiet (no hook, no
    /// transcript write, no command it started still running) for `silence` is taken to have died.
    private func checkSilence(_ session: Session, table: inout [pid_t: (parent: pid_t, start: Date)]?) {
        let lastSign = max(session.updatedAt, modification(of: session) ?? .distantPast)
        guard now().timeIntervalSince(lastSign) > Self.silence else { return }
        let hosted = (Processes.startTime(of: session.pid) ?? session.firstSeen) < session.firstSeen.addingTimeInterval(-60)
        let orphaned = Processes.parent(of: session.pid) == 1 && session.parent.map { $0 != 1 } == true
        guard hosted || orphaned else { return }
        if table == nil { table = Processes.table() }
        guard !Processes.hasDescendant(of: session.pid, startedAfter: session.updatedAt.addingTimeInterval(-2), in: table ?? [:]) else { return }
        Log.write("sessions: \(session.id) silent since \(lastSign), hosted \(hosted), orphaned \(orphaned)")
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].status = .idle
        sessions[index].activity = ""
        sessions[index].turnStartedAt = nil
        sessions[index].lastMessage = "很久没有动静，可能已异常结束"
    }

    private func modification(of session: Session) -> Date? {
        guard !session.transcript.isEmpty else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: session.transcript))?[.modificationDate] as? Date
    }

    /// A turn the transcript shows ended, told like one its Stop hook reported.
    private func ended(_ key: String, message: String) {
        guard let index = sessions.firstIndex(where: { $0.id == key }) else { return }
        for approval in approvals where approval.sessionId == key { approval.reply?.answer(.terminal) }
        approvals.removeAll { $0.sessionId == key }
        sessions[index].status = .finished
        sessions[index].activity = ""
        sessions[index].turnStartedAt = nil
        sessions[index].endedFromTranscript = true
        if !message.isEmpty { sessions[index].lastMessage = message }
        endTurn(key)
        if !watching(sessions[index].pid) {
            sessions[index].unseen = true
            onFinished?(sessions[index])
        }
    }

    func interrupted(_ key: String) {
        guard let index = sessions.firstIndex(where: { $0.id == key }) else { return }
        for approval in approvals where approval.sessionId == key { approval.reply?.answer(.terminal) }
        approvals.removeAll { $0.sessionId == key }
        sessions[index].status = .idle
        sessions[index].activity = ""
        sessions[index].turnStartedAt = nil
        sessions[index].lastMessage = "已中断"
        endTurn(key)
    }

    // MARK: Usage and changes

    /// Claude Code's status line, relayed: the plan's limits, and the session's context with its window's size.
    private func statusLine(_ envelope: HookEnvelope) {
        guard readsUsage else { return }
        let (limits, context) = Usage.statusLine(envelope.payload)
        if let limits { meter.report(.claude, limits) }
        let key = "\(envelope.harness.rawValue):\(envelope.sessionId)"
        if let context, let index = sessions.firstIndex(where: { $0.id == key }), sessions[index].context != context {
            sessions[index].context = context
        }
    }

    /// The CLIs whose transcripts say how full the context is (and, for Codex, the plan's limits).
    static let transcriptUsage: Set<Harness> = [.claude, .codex, .codebuddy, .pi, .omp, .gemini]

    /// Reads the session's latest limits and context from the end of its transcript, off the main thread: at a turn's
    /// end, and at most every 15 seconds while it runs.
    private func readUsage(of session: Session, now immediately: Bool = false) {
        guard readsUsage, !session.transcript.isEmpty, Self.transcriptUsage.contains(session.harness) else { return }
        if !immediately, let last = usageRead[session.id], now().timeIntervalSince(last) < 15 { return }
        usageRead[session.id] = now()
        let path = session.transcript, harness = session.harness, key = session.id
        Task.detached(priority: .utility) { [weak self] in
            guard let tail = Transcript.tail(of: path, bytes: 256 * 1024) else { return }
            let (limits, context) = harness == .codex ? Usage.codex(in: tail) : (nil, Usage.context(in: tail, harness: harness))
            await self?.show(limits: limits, context: context, harness: harness, on: key)
        }
    }

    private func show(limits: Limits?, context: ContextFill?, harness: Harness, on key: String) {
        if let limits { meter.report(harness, limits) }
        guard var context, let index = sessions.firstIndex(where: { $0.id == key }) else { return }
        // The transcript does not say how large the window is; the status line did.
        if context.window == nil { context.window = sessions[index].context?.window }
        if sessions[index].context != context { sessions[index].context = context }
    }

    /// Notes where the turn begins in its git checkout, off the main thread.
    private func beginTurn(_ key: String, cwd: String) {
        turnStarts[key]?.cancel()
        guard tracksChanges, !cwd.isEmpty else { turnStarts[key] = nil; return }
        turnStarts[key] = Task.detached(priority: .utility) { Git.start(in: cwd) }
    }

    /// Works out what the turn changed, off the main thread, and puts it on the session.
    private func endTurn(_ key: String) {
        guard let start = turnStarts.removeValue(forKey: key) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let begun = await start.value, let changes = Git.changes(since: begun), !changes.isEmpty else { return }
            await self?.show(changes, for: key)
        }
    }

    private func show(_ changes: TurnChanges, for key: String) {
        // A new turn has begun since: these are the last one's, and it will have its own.
        guard let index = sessions.firstIndex(where: { $0.id == key }), turnStarts[key] == nil else { return }
        sessions[index].changes = changes
    }

    /// A request the CLI makes on its own behalf rather than a conversation of yours. The Codex app names each new
    /// conversation with a separate thread that starts with a fixed instruction and answers {"title": …}, and sends
    /// other app-generated requests that say so; its approval reviewer and sub-agents are marked in their transcript.
    static func isInternal(_ envelope: HookEnvelope) -> Bool {
        guard envelope.harness == .codex else { return false }
        if let prompt = envelope.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           internalPrompts.contains(where: { prompt.range(of: $0, options: [.anchored, .caseInsensitive]) != nil }) {
            return true
        }
        return false
    }

    static let internalPrompts = ["You are a helpful assistant. You will be presented with a", "This is an app-generated"]

    /// Whether a Codex thread's transcript marks it as one Codex runs for itself; nil until the transcript is written.
    private func internalThread(_ envelope: HookEnvelope, key: String) -> Bool? {
        guard envelope.harness == .codex, let path = envelope.transcriptPath, !path.isEmpty else { return false }
        if let known = threadSources[key] { return Transcript.codexInternalSources.contains(known) }
        guard let source = Transcript.codexThreadSource(of: path) else { return nil }
        threadSources[key] = source
        return Transcript.codexInternalSources.contains(source)
    }

    nonisolated static func oneLine(_ text: String, limit: Int = 200) -> String {
        String(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ").prefix(limit))
    }

    /// A tool call in a few words: the command for shells, the path for file tools, else the tool name.
    static func describe(tool: String, input: Any?, verbose: Bool = false) -> String {
        let fields = input as? [String: Any] ?? [:]
        // Codex's `["bash", "-lc", script]` reads as the script.
        if let command = RequestPreview.command(in: input) { return verbose ? command : "\(tool) \(oneLine(command, limit: 120))" }
        for key in ["file_path", "path", "filePath", "absolute_path", "notebook_path", "url", "pattern", "query"] {
            if let value = fields[key] as? String, !value.isEmpty { return "\(tool) \(oneLine(value, limit: 160))" }
        }
        if verbose, !fields.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) {
            return "\(tool) \(String(json.prefix(300)))"
        }
        return tool
    }
}
