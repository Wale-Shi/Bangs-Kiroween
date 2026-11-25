import XCTest
import SessionEvents
import BangsCore

final class SessionEventsTests: XCTestCase {
    func testFallbackEventName() throws {
        let e = try SessionEvent.parse(line: Data(#"{"harness":"kiro","payload":{"hook_event_name":"Stop"}}"#.utf8)).get()
        XCTAssertEqual(e.native, "Stop")
    }
    func testPidExtremesDoNotCrash() throws {
        for pid in ["99999999999", "-99999999999", "9223372036854775807", "18446744073709551615", "2147483648", "-1.5"] {
            let line = #"{"harness":"kiro","event":"Stop","pid":\#(pid),"payload":{}}"#
            XCTAssertEqual(try SessionEvent.parse(line: Data(line.utf8)).get().pid, 0, pid)
            _ = HookEnvelope(line: Data(line.utf8))
        }
        // Foundation rejects numbers beyond its JSON numeric range before a PID can be decoded.
        let overflow = Data(#"{"harness":"kiro","pid":1e999,"payload":{}}"#.utf8)
        XCTAssertThrowsError(try SessionEvent.parse(line: overflow).get())
        XCTAssertNil(HookEnvelope(line: overflow))
        let ok = try SessionEvent.parse(line: Data(#"{"harness":"kiro","pid":2147483647,"payload":{}}"#.utf8)).get()
        XCTAssertEqual(ok.pid, Int32.max)
    }
    func testMalformed() {
        let cases: [(String, SessionEvent.ParseError)] = [("{", .notJSON), ("[1]", .notObject), (#"{"payload":{}}"#, .missingHarness), (#"{"harness":"kiro"}"#, .missingPayload)]
        for (text, error) in cases {
            guard case .failure(let got) = SessionEvent.parse(line: Data(text.utf8)) else { return XCTFail(text) }
            XCTAssertEqual(got, error, text)
        }
        XCTAssertNil(HookEnvelope(line: Data("\u{FF}".utf8)))
    }
    func testHookEnvelopeCompatible() throws {
        let line = Data(#"{"harness":"kiro","pid":7,"payload":{"hook_event_name":"PreToolUse","sessionId":"s","tool_name":"x"}}"#.utf8)
        let env = try XCTUnwrap(HookEnvelope(line: line))
        XCTAssertEqual(env.native, "PreToolUse")
        XCTAssertEqual(env.event, .preTool)
        XCTAssertEqual(env.sessionId, "s")
        XCTAssertEqual(env.toolName, "x")
        XCTAssertEqual(env.pid, 7)
        XCTAssertNil(HookEnvelope(line: Data(#"{"harness":"nonesuch","payload":{}}"#.utf8)))
        let round = try XCTUnwrap(HookEnvelope(line: env.encoded()))
        XCTAssertEqual(round.native, "PreToolUse")
    }
    func testParseAllLineNumbers() {
        let all = SessionEvent.parseAll(Data("{}\n\n{\"harness\":\"k\",\"payload\":{}}\r\n".utf8))
        XCTAssertEqual(all.map(\.line), [1, 3])
    }
}
