import XCTest
@testable import KiwiOS

final class WatcherTests: XCTestCase {
    func testDecodesTypedStateProgressStepsAndLogs() {
        let decoded = WatchDecoder().decode(Data("""
        {"t":"log","lvl":"warn","msg":"slow"}
        {"t":"state","state":{"ready":true,"count":2,"items":["a",null]}}
        {"t":"progress","pct":42,"msg":"Build","id":"build","steps":[{"id":"resolve","label":"Packages","pct":100},{"id":"compile","label":"Compile"}]}
        """.utf8))

        XCTAssertFalse(decoded.hadProtocolWarning)
        XCTAssertEqual(decoded.events[0].level, "warn")
        XCTAssertEqual(decoded.events[1].state?["ready"], .bool(true))
        XCTAssertEqual(decoded.events[1].state?["count"], .number(2))
        XCTAssertEqual(decoded.events[2].progress?.percentage, 42)
        XCTAssertEqual(decoded.events[2].progress?.steps.count, 2)
        XCTAssertNil(decoded.events[2].progress?.steps[1].percentage)
    }

    func testValidatesExactLineAndStateLimits() throws {
        let exactPlainLine = Data(repeating: Character("x").asciiValue!, count: WatchDecoder.maximumEventLineBytes)
        XCTAssertFalse(WatchDecoder().decode(exactPlainLine).hadProtocolWarning)
        XCTAssertTrue(WatchDecoder().decode(exactPlainLine + Data([0x78])).hadProtocolWarning)

        func stateEvent(payloadBytes: Int) throws -> Data {
            var low = 0
            var high = WatchDecoder.maximumStateBytes * 2
            while low < high {
                let middle = (low + high) / 2
                let state = try JSONSerialization.data(withJSONObject: ["v": String(repeating: "x", count: middle)])
                if state.count < payloadBytes { low = middle + 1 } else { high = middle }
            }
            let state = try JSONSerialization.data(withJSONObject: ["v": String(repeating: "x", count: low)])
            XCTAssertEqual(state.count, payloadBytes)
            return try JSONSerialization.data(withJSONObject: ["t": "state", "state": ["v": String(repeating: "x", count: low)]])
        }

        XCTAssertFalse(WatchDecoder().decode(try stateEvent(payloadBytes: WatchDecoder.maximumStateBytes)).hadProtocolWarning)
        XCTAssertTrue(WatchDecoder().decode(try stateEvent(payloadBytes: WatchDecoder.maximumStateBytes + 1)).hadProtocolWarning)

        let whitespaceHeavyState = Data(
            (#"{"t":"state","state":{"# + String(repeating: " ", count: WatchDecoder.maximumStateBytes) + #""v":1}}"#).utf8
        )
        XCTAssertTrue(WatchDecoder().decode(whitespaceHeavyState).hadProtocolWarning)
    }

    func testRejectsInvalidProgressBoundariesAndTooManySteps() throws {
        for pct in [-0.1, 100.1] {
            let data = try JSONSerialization.data(withJSONObject: ["t": "progress", "pct": pct])
            XCTAssertTrue(WatchDecoder().decode(data).hadProtocolWarning)
        }
        let steps = (0...WatchDecoder.maximumStepCount).map {
            ["id": "step-\($0)", "label": "Step"]
        }
        let tooMany = try JSONSerialization.data(withJSONObject: ["t": "progress", "steps": steps])
        XCTAssertTrue(WatchDecoder().decode(tooMany).hadProtocolWarning)

        let duplicates = Data(#"{"t":"progress","steps":[{"id":"same","label":"A"},{"id":"same","label":"B"}]}"#.utf8)
        XCTAssertTrue(WatchDecoder().decode(duplicates).hadProtocolWarning)
        let nested = Data(#"{"t":"progress","steps":[{"id":"parent","label":"A","steps":[]}]}"#.utf8)
        XCTAssertTrue(WatchDecoder().decode(nested).hadProtocolWarning)
    }

    func testTerminalPrecedenceAndAllDistinctOutcomes() {
        var builder = WatchResultBuilder()
        builder.append(WatchDecoder().decode(Data("""
        {"t":"state","state":{"value":"Up"}}
        {"t":"progress","pct":50,"msg":"Half"}
        {"t":"warn","msg":"degraded"}
        {"t":"error","msg":"broken"}
        {"t":"ok","msg":"later"}
        """.utf8)))
        XCTAssertEqual(builder.finish(exitCode: 0).outcome, .failed)
        XCTAssertEqual(builder.finish(exitCode: 0).message, "broken")
        XCTAssertEqual(builder.finish(exitCode: 0).state?["value"], .string("Up"))
        XCTAssertEqual(builder.finish(exitCode: 0).progress?.percentage, 50)
        XCTAssertEqual(builder.snapshot().state?["value"], .string("Up"))
        XCTAssertEqual(builder.snapshot().progress?.message, "Half")
        XCTAssertEqual(builder.finish(exitCode: 0, timedOut: true).outcome, .timedOut)
        XCTAssertEqual(builder.finish(exitCode: 0, canceled: true).outcome, .canceled)
        XCTAssertEqual(builder.finish(exitCode: 0, interrupted: true).outcome, .interrupted)

        var successful = WatchResultBuilder()
        successful.append(WatchDecoder().decode(Data(#"{"t":"ok","msg":"done"}"#.utf8)))
        XCTAssertEqual(successful.finish(exitCode: 0).outcome, .succeeded)
        XCTAssertEqual(successful.finish(exitCode: 1).outcome, .warning)
        XCTAssertEqual(successful.finish(exitCode: 2).outcome, .failed)
        XCTAssertEqual(successful.finish(exitCode: 2).message, "Exited 2")
    }

    func testMalformedStructuredAndUnknownEventsFollowCompatibilityRules() {
        let decoded = WatchDecoder().decode(Data("""
        plain
        {"t":"future","msg":"kept","new":true}
        {"t":"progress","pct":true}
        {"t":"state","state":[]}
        """.utf8))
        XCTAssertEqual(decoded.events[0], WatchEvent(kind: .log, message: "plain", level: nil))
        XCTAssertEqual(decoded.events[1], WatchEvent(kind: .log, message: "kept", level: "info"))
        XCTAssertEqual(decoded.protocolWarnings.count, 2)
    }

    func testRunnerDeliversAndRedactsSecretsThenRemovesFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await CommandRunner(timeout: 2).run(
            command: ["sh", "-c", "stat -f '%Lp' \"$KIWIOS_SECRETS_FILE\"; printf '%s\\n' \"$KIWIOS_SECRETS_FILE\"; cat \"$KIWIOS_SECRETS_FILE\""],
            in: root,
            secrets: ["token": "very-secret-value"]
        )
        let lines = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.first, "600")
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(lines[1])))
        XCTAssertNil(result.output.range(of: Data("very-secret-value".utf8)))
        XCTAssertNotNil(result.output.range(of: Data("[REDACTED]".utf8)))
    }

    func testRunnerStreamsRedactedOutputIndependentlyOfCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = OutputCollector()

        let result = try await CommandRunner(timeout: 2, maximumOutputBytes: 5).run(
            command: ["sh", "-c", "printf '123456789'"],
            in: root,
            onOutput: { await collector.append($0.data) }
        )
        let streamed = await collector.data
        XCTAssertEqual(streamed, Data("123456789".utf8))
        XCTAssertEqual(result.output.count, 5)
    }

    func testRunnerCanReturnCanceledPartialResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = OutputCollector()
        let task = Task {
            try await CommandRunner(timeout: 30).run(
                command: ["sh", "-c", "printf 'started\\n'; sleep 30"],
                in: root,
                retainPartialResultOnCancellation: true,
                onOutput: { await collector.append($0.data) }
            )
        }
        for _ in 0..<100 {
            if !(await collector.data).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        let result = try await task.value
        XCTAssertTrue(result.canceled)
        XCTAssertEqual(result.watchResult().outcome, .canceled)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "started\n")
    }

    func testStderrInvalidUTF8IsRetainedAsReplacementText() {
        var builder = WatchResultBuilder()
        builder.appendStderr(Data([0xFF, 0x0A]))
        XCTAssertEqual(builder.finish(exitCode: 1).logs.first?.message, "�")
    }
}

private actor OutputCollector {
    private(set) var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
}
