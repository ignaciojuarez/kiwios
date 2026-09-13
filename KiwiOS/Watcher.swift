import Foundation
import CoreFoundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum WatchEventKind: String, Codable, Equatable, Sendable {
    case log, progress, ok, warn, error, state
}

enum WatchLogLevel: String, Codable, Equatable, Sendable {
    case debug, info, warn, error
}

struct WatchProgressStep: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let percentage: Double?
}

struct WatchProgress: Codable, Equatable, Sendable {
    let percentage: Double?
    let message: String?
    let id: String?
    let steps: [WatchProgressStep]
}

struct WatchEvent: Codable, Equatable, Sendable {
    let kind: WatchEventKind
    let message: String
    let level: String?
    let state: [String: JSONValue]?
    let progress: WatchProgress?

    init(
        kind: WatchEventKind,
        message: String,
        level: String?,
        state: [String: JSONValue]? = nil,
        progress: WatchProgress? = nil
    ) {
        self.kind = kind
        self.message = message
        self.level = level
        self.state = state
        self.progress = progress
    }
}

struct WatchDecodeResult: Codable, Equatable, Sendable {
    let events: [WatchEvent]
    let hadProtocolWarning: Bool
    let protocolWarnings: [String]

    init(events: [WatchEvent], hadProtocolWarning: Bool, protocolWarnings: [String] = []) {
        self.events = events
        self.hadProtocolWarning = hadProtocolWarning
        self.protocolWarnings = protocolWarnings
    }
}

struct WatchDecoder: Sendable {
    static let maximumEventLineBytes = 64 * 1024
    static let maximumStateBytes = 48 * 1024
    static let maximumStepCount = 32

    func decode(_ data: Data) -> WatchDecodeResult {
        var events: [WatchEvent] = []
        var warnings: [String] = []
        for lineData in Self.lines(in: data) {
            let decoded = decodeLine(lineData)
            events.append(decoded.event)
            if let warning = decoded.warning { warnings.append(warning) }
        }
        return WatchDecodeResult(
            events: events,
            hadProtocolWarning: !warnings.isEmpty,
            protocolWarnings: warnings
        )
    }

    private static func lines(in data: Data) -> [Data] {
        var result: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            var end = index
            if end > start, data[data.index(before: end)] == 0x0D { end = data.index(before: end) }
            if end > start { result.append(data[start..<end]) }
            start = data.index(after: index)
        }
        if start < data.endIndex { result.append(data[start..<data.endIndex]) }
        return result
    }

    private func decodeLine(_ data: Data) -> (event: WatchEvent, warning: String?) {
        guard data.count <= Self.maximumEventLineBytes else {
            let prefix = String(decoding: data.prefix(Self.maximumEventLineBytes), as: UTF8.self)
            return (WatchEvent(kind: .log, message: prefix + "… (event truncated)", level: nil), "event line exceeds 64 KiB")
        }
        let line = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return (WatchEvent(kind: .log, message: line, level: nil),
                    trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? "malformed structured event" : nil)
        }
        guard let rawKind = object["t"] as? String else {
            return (WatchEvent(kind: .log, message: line, level: nil), "event is missing string t")
        }
        guard let kind = WatchEventKind(rawValue: rawKind) else {
            return (WatchEvent(kind: .log, message: object["msg"] as? String ?? line, level: "info"), nil)
        }

        switch kind {
        case .log:
            guard let message = object["msg"] as? String else { return invalid(line, "log msg must be a string") }
            let level = object["lvl"] as? String
            if object["lvl"] != nil, level == nil { return invalid(line, "log lvl must be a string") }
            if let level, WatchLogLevel(rawValue: level) == nil {
                return (WatchEvent(kind: .log, message: message, level: "info"), "unknown log level")
            }
            return (WatchEvent(kind: .log, message: message, level: level), nil)
        case .progress:
            guard let progress = decodeProgress(object) else { return invalid(line, "invalid progress event") }
            return (WatchEvent(kind: .progress, message: progress.message ?? "", level: nil, progress: progress), nil)
        case .ok, .warn, .error:
            guard let message = object["msg"] as? String else { return invalid(line, "terminal msg must be a string") }
            var state: [String: JSONValue]?
            if object["state"] != nil {
                guard let decodedState = decodeRequiredState(object, eventData: data) else { return invalid(line, "invalid or oversized state") }
                state = decodedState
            }
            return (WatchEvent(kind: kind, message: message, level: nil, state: state), nil)
        case .state:
            guard let state = decodeRequiredState(object, eventData: data) else { return invalid(line, "invalid or oversized state") }
            return (WatchEvent(kind: .state, message: "", level: nil, state: state), nil)
        }
    }

    private func decodeProgress(_ object: [String: Any]) -> WatchProgress? {
        let percentage = number(object["pct"])
        if object["pct"] != nil, percentage == nil { return nil }
        if let percentage, !(0...100).contains(percentage) { return nil }
        let message = object["msg"] as? String
        if object["msg"] != nil, message == nil { return nil }
        let id = object["id"] as? String
        if object["id"] != nil, id == nil || !validContributionID(id!) { return nil }
        var steps: [WatchProgressStep] = []
        if let rawSteps = object["steps"] {
            guard let values = rawSteps as? [[String: Any]], values.count <= Self.maximumStepCount else { return nil }
            var seenIDs = Set<String>()
            for value in values {
                guard let stepID = value["id"] as? String, validContributionID(stepID),
                      seenIDs.insert(stepID).inserted,
                      let label = value["label"] as? String,
                      value["steps"] == nil else { return nil }
                let pct = number(value["pct"])
                if value["pct"] != nil, pct == nil { return nil }
                if let pct, !(0...100).contains(pct) { return nil }
                steps.append(WatchProgressStep(id: stepID, label: label, percentage: pct))
            }
        }
        return WatchProgress(percentage: percentage, message: message, id: id, steps: steps)
    }

    private func decodeRequiredState(_ object: [String: Any], eventData: Data) -> [String: JSONValue]? {
        guard let raw = object["state"] as? [String: Any],
              let encodedLength = encodedTopLevelValueLength(named: "state", in: eventData),
              encodedLength <= Self.maximumStateBytes,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              data.count <= Self.maximumStateBytes else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func encodedTopLevelValueLength(named wantedKey: String, in data: Data) -> Int? {
        let bytes = Array(data)
        var index = 0
        func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }
        func scanString() -> Range<Int>? {
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x5C { index += 2; continue }
                if bytes[index] == 0x22 { index += 1; return start..<index }
                index += 1
            }
            return nil
        }
        func scanValue() -> Range<Int>? {
            skipWhitespace()
            let start = index
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x22 {
                guard scanString() != nil else { return nil }
                return start..<index
            }
            if bytes[index] == 0x7B || bytes[index] == 0x5B {
                var stack = [bytes[index]]
                index += 1
                while index < bytes.count, !stack.isEmpty {
                    if bytes[index] == 0x22 { guard scanString() != nil else { return nil }; continue }
                    if bytes[index] == 0x7B || bytes[index] == 0x5B { stack.append(bytes[index]) }
                    else if bytes[index] == 0x7D {
                        guard stack.last == 0x7B else { return nil }; stack.removeLast()
                    } else if bytes[index] == 0x5D {
                        guard stack.last == 0x5B else { return nil }; stack.removeLast()
                    }
                    index += 1
                }
                return stack.isEmpty ? start..<index : nil
            }
            while index < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
            return start < index ? start..<index : nil
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        index += 1
        while index < bytes.count {
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7D { return nil }
            guard let keyRange = scanString(),
                  let key = try? JSONDecoder().decode(String.self, from: Data(bytes[keyRange])) else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else { return nil }
            index += 1
            guard let valueRange = scanValue() else { return nil }
            if key == wantedKey { return valueRange.count }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x7D { return nil }
            return nil
        }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private func validContributionID(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private func invalid(_ line: String, _ warning: String) -> (event: WatchEvent, warning: String?) {
        (WatchEvent(kind: .log, message: line, level: nil), warning)
    }
}

struct WatchLog: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case stdout, stderr }
    let source: Source
    let level: WatchLogLevel?
    let message: String
}

enum WatchRunOutcome: String, Codable, Equatable, Sendable {
    case succeeded, warning, failed, timedOut, canceled, interrupted
}

struct WatchRunResult: Codable, Equatable, Sendable {
    let outcome: WatchRunOutcome
    let message: String
    let state: [String: JSONValue]?
    let progress: WatchProgress?
    let logs: [WatchLog]
    let protocolWarnings: [String]
    let exitCode: Int32?
    let outputTruncated: Bool
}

struct WatchLiveSnapshot: Codable, Equatable, Sendable {
    let state: [String: JSONValue]?
    let progress: WatchProgress?
    let logs: [WatchLog]
    let protocolWarnings: [String]
}

struct WatchResultBuilder: Sendable {
    private(set) var events: [WatchEvent] = []
    private(set) var logs: [WatchLog] = []
    private(set) var protocolWarnings: [String] = []

    mutating func append(_ decoded: WatchDecodeResult) {
        events.append(contentsOf: decoded.events)
        protocolWarnings.append(contentsOf: decoded.protocolWarnings)
        logs.append(contentsOf: decoded.events.compactMap { event in
            guard event.kind == .log else { return nil }
            return WatchLog(source: .stdout, level: event.level.flatMap(WatchLogLevel.init), message: event.message)
        })
    }

    mutating func appendStderr(_ data: Data) {
        logs.append(contentsOf: String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { WatchLog(source: .stderr, level: nil, message: String($0)) })
    }

    func snapshot() -> WatchLiveSnapshot {
        WatchLiveSnapshot(
            state: events.reversed().compactMap(\.state).first,
            progress: events.reversed().compactMap(\.progress).first,
            logs: logs,
            protocolWarnings: protocolWarnings
        )
    }

    func finish(exitCode: Int32?, timedOut: Bool = false, canceled: Bool = false,
                interrupted: Bool = false, truncated: Bool = false) -> WatchRunResult {
        let live = snapshot()
        let emittedError = events.last(where: { $0.kind == .error })
        let terminal = events.last(where: { [.ok, .warn, .error].contains($0.kind) })
        let outcome: WatchRunOutcome
        if interrupted { outcome = .interrupted }
        else if canceled { outcome = .canceled }
        else if timedOut { outcome = .timedOut }
        else if emittedError != nil || !(exitCode.map { [0, 1].contains($0) } ?? false) { outcome = .failed }
        else if exitCode == 1 || terminal?.kind == .warn || !protocolWarnings.isEmpty || truncated { outcome = .warning }
        else { outcome = .succeeded }

        let fallback: String
        if let exitCode, ![0, 1].contains(exitCode) {
            fallback = logs.last(where: { $0.source == .stderr })?.message ?? "Exited \(exitCode)"
        } else {
            fallback = logs.last?.message ?? (exitCode == 0 ? "Completed" : exitCode.map { "Exited \($0)" } ?? "Interrupted")
        }
        let message: String
        switch outcome {
        case .timedOut: message = "Timed out"
        case .canceled: message = "Canceled"
        case .interrupted: message = "Interrupted"
        case .failed: message = emittedError?.message ?? fallback
        default: message = terminal?.message ?? fallback
        }
        return WatchRunResult(
            outcome: outcome,
            message: message,
            state: live.state,
            progress: live.progress,
            logs: logs,
            protocolWarnings: protocolWarnings,
            exitCode: exitCode,
            outputTruncated: truncated
        )
    }
}

extension CommandResult {
    func watchResult(canceled canceledOverride: Bool? = nil, interrupted: Bool = false) -> WatchRunResult {
        var builder = WatchResultBuilder()
        builder.append(WatchDecoder().decode(output))
        builder.appendStderr(errorOutput)
        return builder.finish(
            exitCode: timedOut ? nil : exitCode,
            timedOut: timedOut,
            canceled: canceledOverride ?? canceled,
            interrupted: interrupted,
            truncated: truncated
        )
    }
}
