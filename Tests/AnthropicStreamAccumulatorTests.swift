import XCTest
@testable import Seminarly

final class AnthropicStreamAccumulatorTests: XCTestCase {
    func testAsyncLinesWithoutBlankSeparatorsStillDecodeEvents() async throws {
        let fixture = """
        event: message_start
        data: {"type":"message_start"}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Recovered"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seminarly-sse-\(UUID().uuidString).txt")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var stream = AnthropicStreamAccumulator()
        for try await line in url.lines {
            try stream.consume(line: line)
        }

        XCTAssertEqual(try stream.finish(), "Recovered")
    }

    func testAccumulatesTextAcrossEventsAndPings() throws {
        var stream = AnthropicStreamAccumulator()
        let lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\"}",
            "",
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\",\"text\":\"{\\\"title\\\":\\\"\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Notes\\\"}\"}}",
            "",
            "event: ping",
            "data: {\"type\":\"ping\"}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}"
        ]
        for line in lines { try stream.consume(line: line) }

        XCTAssertEqual(try stream.finish(), "{\"title\":\"Notes\"}")
    }

    func testIncompleteStreamDoesNotReturnPartialNotes() throws {
        var stream = AnthropicStreamAccumulator()
        try stream.consume(line: "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}")
        try stream.consume(line: "")

        XCTAssertThrowsError(try stream.finish()) { error in
            guard case LLMProviderError.incompleteResponse = error else {
                return XCTFail("Expected incomplete response, got \(error)")
            }
        }
    }

    func testMaxTokensStreamIsRejected() throws {
        var stream = AnthropicStreamAccumulator()
        let lines = [
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}",
            "",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}",
            "",
            "data: {\"type\":\"message_stop\"}",
            ""
        ]
        for line in lines { try stream.consume(line: line) }

        XCTAssertThrowsError(try stream.finish()) { error in
            guard case LLMProviderError.apiError(200, _) = error else {
                return XCTFail("Expected output limit error, got \(error)")
            }
        }
    }

    func testStreamErrorSurfacesProviderMessage() throws {
        var stream = AnthropicStreamAccumulator()
        try stream.consume(line: "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}")

        XCTAssertThrowsError(try stream.consume(line: "")) { error in
            guard case LLMProviderError.providerError("Overloaded") = error else {
                return XCTFail("Expected provider error, got \(error)")
            }
        }
    }
}
