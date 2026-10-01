import XCTest
@testable import DuckyCore

final class TranscriptTailTests: XCTestCase {
    private func line(_ type: String, _ text: String, at time: String) -> String {
        #"{"type":"\#(type)","message":{"role":"\#(type)","content":[{"type":"text","text":"\#(text)"}]},"timestamp":"\#(time)"}"#
    }

    func testInterruptIsTheLastExchange() {
        let tail = [
            line("user", "fais ceci", at: "2026-10-01T08:13:00.000Z"),
            line("assistant", "je commence", at: "2026-10-01T08:13:05.000Z"),
            line("user", "[Request interrupted by user]", at: "2026-10-01T08:13:16.203Z"),
            #"{"type":"cost-state","total":1}"#,
        ].joined(separator: "\n")
        let date = TranscriptTail.interruption(in: Data(tail.utf8))
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_790_842_396.203, accuracy: 0.01)
    }

    func testToolInterruptCountsAndLaterMessagesDoNot() {
        let tool = line("user", "[Request interrupted by user for tool use]", at: "2026-10-01T08:13:16.000Z")
        XCTAssertNotNil(TranscriptTail.interruption(in: Data(tool.utf8)))
        let resumed = [tool, line("user", "reprends", at: "2026-10-01T08:14:00.000Z")].joined(separator: "\n")
        XCTAssertNil(TranscriptTail.interruption(in: Data(resumed.utf8)))
    }

    func testCutFirstLineAndGarbageAreIgnored() {
        let tail = #"ial line"}}"# + "\n" + "not json\n" + line("assistant", "fini", at: "2026-10-01T08:13:05.000Z")
        XCTAssertNil(TranscriptTail.interruption(in: Data(tail.utf8)))
        XCTAssertNil(TranscriptTail.interruption(in: Data()))
    }
}
