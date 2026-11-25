import XCTest
@testable import SessionTimeline

final class TimelineTests: XCTestCase {
    func testOrderedAndHidesPromptsAndArguments() {
        let input = """
        {"harness":"kiro","event":"UserPromptSubmit","pid":1,"payload":{"prompt":"TOPSECRET"}}
        {"harness":"kiro","event":"PreToolUse","pid":1,"payload":{"tool_name":"fs_read","tool_input":{"path":"ARGSECRET"}}}
        """
        let r = Timeline.render(Data(input.utf8))
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.out.contains("TOPSECRET") || r.out.contains("ARGSECRET"))
        let lines = r.out.split(separator: "\n")
        XCTAssertTrue(lines[0].contains("UserPromptSubmit"))
        XCTAssertTrue(lines[1].contains("tool=fs_read"))
    }
    func testEscapesControls() {
        let r = Timeline.render(Data(#"{"harness":"kiro","event":"A\u001b[2J\u009b","payload":{"tool_name":"x\u202Ey\n"}}"#.utf8))
        XCTAssertFalse(r.out.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x9B || $0.value == 0x202E })
        XCTAssertTrue(r.out.contains("\\u{1B}"))
    }
    func testMalformedReportsLineAndFails() {
        let r = Timeline.render(Data("{\"harness\":\"k\",\"payload\":{}}\nnope\n{\"harness\":\"k\"}\n".utf8))
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.err, "line 2: not valid JSON\nline 3: missing object field \"payload\"\n")
        XCTAssertTrue(r.out.contains("line 1"))
    }
    func testIntegerExtremes() {
        let r = Timeline.render(Data(#"{"harness":"k","event":"E","pid":18446744073709551615,"payload":{}}"#.utf8))
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.out.contains("pid=0"))
    }
    func testEmpty() {
        XCTAssertEqual(Timeline.render(Data()).out, "No events.\n")
    }
}
