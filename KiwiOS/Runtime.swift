import Foundation
import Subprocess
import System

enum WatchEventKind: String, Equatable, Sendable {
    case log, progress, ok, warn, error, state
}

struct WatchEvent: Equatable, Sendable {
    let kind: WatchEventKind
    let message: String
    let level: String?
}

struct WatchDecodeResult: Equatable, Sendable {
    let events: [WatchEvent]
    let hadProtocolWarning: Bool
}

struct WatchDecoder {
    static let maximumEventLineBytes = 64 * 1024
    static let maximumStateBytes = 48 * 1024

    private struct WireEvent: Decodable {
        let t: String?
        let msg: String?
        let lvl: String?
    }

    func decode(_ data: Data) -> WatchDecodeResult {
        var events: [WatchEvent] = []
        var hadProtocolWarning = false
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init) {
            let decoded = decodeLine(line)
            events.append(decoded.event)
            hadProtocolWarning = hadProtocolWarning || decoded.hadProtocolWarning
        }
        return WatchDecodeResult(events: events, hadProtocolWarning: hadProtocolWarning)
    }

    private func decodeLine(_ line: String) -> (event: WatchEvent, hadProtocolWarning: Bool) {
        guard let data = line.data(using: .utf8) else {
            return (WatchEvent(kind: .log, message: line, level: nil), true)
        }
        guard data.count <= Self.maximumEventLineBytes else {
            let prefix = String(decoding: data.prefix(Self.maximumEventLineBytes), as: UTF8.self)
            return (WatchEvent(kind: .log, message: prefix + "… (event truncated)", level: nil), true)
        }
        guard let wire = try? JSONDecoder().decode(WireEvent.self, from: data) else {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let looksStructured = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            return (WatchEvent(kind: .log, message: line, level: nil), looksStructured)
        }
        guard let rawKind = wire.t else {
            return (WatchEvent(kind: .log, message: line, level: nil), true)
        }
        guard let kind = WatchEventKind(rawValue: rawKind) else {
            return (WatchEvent(kind: .log, message: wire.msg ?? line, level: "info"), false)
        }

        if [.ok, .warn, .error, .log].contains(kind), wire.msg == nil {
            return (WatchEvent(kind: .log, message: line, level: nil), true)
        }
        if kind == .log, let level = wire.lvl, !["debug", "info", "warn", "error"].contains(level) {
            return (WatchEvent(kind: .log, message: wire.msg ?? line, level: "info"), true)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let state = object?["state"] {
            guard state is [String: Any],
                  let encodedState = try? JSONSerialization.data(withJSONObject: state),
                  encodedState.count <= Self.maximumStateBytes else {
                return (WatchEvent(kind: .log, message: line, level: nil), true)
            }
        } else if kind == .state {
            return (WatchEvent(kind: .log, message: line, level: nil), true)
        }
        return (WatchEvent(kind: kind, message: wire.msg ?? line, level: wire.lvl), false)
    }
}

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: Data
    let errorOutput: Data
    let timedOut: Bool
    let truncated: Bool
}

enum CommandRunnerError: LocalizedError {
    case emptyCommand
    case commandOutsidePlugin
    case executableMissing(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand: "Command has no argv"
        case .commandOutsidePlugin: "Executable must be bare or a ./ path inside the plugin"
        case .executableMissing(let path): "Executable not found: \(path)"
        }
    }
}

struct CommandRunner: Sendable {
    private static let executablePaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let pluginDataRoot: URL?

    init(
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 64 * 1024,
        pluginDataRoot: URL? = nil
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.pluginDataRoot = pluginDataRoot
    }

    func run(
        command: [String],
        in pluginRoot: URL,
        pluginID: String? = nil,
        timeout overrideTimeout: TimeInterval? = nil
    ) async throws -> CommandResult {
        guard let executable = command.first, !executable.isEmpty else {
            throw CommandRunnerError.emptyCommand
        }
        let executableURL = try resolve(executable, in: pluginRoot)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CommandRunnerError.executableMissing(executableURL.path)
        }

        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(5)),
        ]
        let inheritedEnvironment = try environment(pluginRoot: pluginRoot, pluginID: pluginID)
        let subprocessEnvironment = Dictionary(uniqueKeysWithValues: inheritedEnvironment.map {
            (Subprocess.Environment.Key(rawValue: $0.key)!, $0.value)
        })
        let configuration = Subprocess.Configuration(
            executable: .path(FilePath(executableURL.path)),
            arguments: Subprocess.Arguments(Array(command.dropFirst())),
            environment: .custom(subprocessEnvironment),
            workingDirectory: FilePath(pluginRoot.path),
            platformOptions: platformOptions
        )
        let outputBuffer = BoundedOutputBuffer(limit: maximumOutputBytes)
        let errorBuffer = BoundedOutputBuffer(limit: maximumOutputBytes)
        let effectiveTimeout = overrideTimeout ?? timeout

        let outcome = try await withThrowingTaskGroup(of: CommandOutcome.self) { group in
            group.addTask {
                .completed(try await Self.execute(
                    configuration,
                    outputBuffer: outputBuffer,
                    errorBuffer: errorBuffer
                ))
            }
            group.addTask {
                let seconds = min(max(0, effectiveTimeout), 9_223_372_036)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }

            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let output = await outputBuffer.snapshot()
        let errorOutput = await errorBuffer.snapshot()

        switch outcome {
        case .completed(let exitCode):
            return CommandResult(
                exitCode: exitCode,
                output: output.data,
                errorOutput: errorOutput.data,
                timedOut: false,
                truncated: output.truncated || errorOutput.truncated
            )
        case .timedOut:
            return CommandResult(
                exitCode: -1,
                output: output.data,
                errorOutput: errorOutput.data,
                timedOut: true,
                truncated: output.truncated || errorOutput.truncated
            )
        }
    }

    private func resolve(_ executable: String, in pluginRoot: URL) throws -> URL {
        guard executable != ".", executable != "./", !executable.hasPrefix("/") else {
            throw CommandRunnerError.commandOutsidePlugin
        }

        if !executable.contains("/") {
            for directory in Self.executablePaths {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            throw CommandRunnerError.executableMissing(executable)
        }

        guard executable.hasPrefix("./") else { throw CommandRunnerError.commandOutsidePlugin }
        let root = pluginRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(executable).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw CommandRunnerError.commandOutsidePlugin
        }
        return candidate
    }

    private func environment(pluginRoot: URL, pluginID: String?) throws -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result = inherited.filter { ["HOME", "USER", "TMPDIR", "LANG"].contains($0.key) }
        result["PATH"] = Self.executablePaths.joined(separator: ":")
        result["KIWIOS_PLUGIN_ROOT"] = pluginRoot.path

        if let pluginID {
            let root = pluginDataRoot ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("KiwiOS/PluginData", isDirectory: true)
            let dataDirectory = root.appendingPathComponent(pluginID, isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            result["KIWIOS_PLUGIN_ID"] = pluginID
            result["KIWIOS_DATA_DIR"] = dataDirectory.path
            result["KIWIOS_CONFIG_FILE"] = dataDirectory.appendingPathComponent("config.json").path
        }
        return result
    }

    private static func execute(
        _ configuration: Subprocess.Configuration,
        outputBuffer: BoundedOutputBuffer,
        errorBuffer: BoundedOutputBuffer
    ) async throws -> Int32 {
        let result = try await Subprocess.run(
            configuration,
            input: .none,
            output: .sequence,
            error: .sequence
        ) { execution in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await readBounded(from: execution.standardOutput, into: outputBuffer)
                }
                group.addTask {
                    try await readBounded(from: execution.standardError, into: errorBuffer)
                }
                try await group.waitForAll()
            }
        }
        switch result.terminationStatus {
        case .exited(let code): return code
        case .signaled(let signal): return -signal
        }
    }

    private static func readBounded(
        from stream: SubprocessOutputSequence,
        into buffer: BoundedOutputBuffer
    ) async throws {
        for try await chunk in stream {
            await buffer.append(Data(buffer: chunk))
        }
    }
}

private struct BoundedOutput: Sendable {
    var data = Data()
    var truncated = false
}

private actor BoundedOutputBuffer {
    private let limit: Int
    private var output = BoundedOutput()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        let remaining = max(0, limit - output.data.count)
        if remaining > 0 {
            output.data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            output.truncated = true
        }
    }

    func snapshot() -> BoundedOutput {
        output
    }
}

private enum CommandOutcome: Sendable {
    case completed(Int32)
    case timedOut
}

enum PluginRunStatus: Equatable, Sendable {
    case idle, running, ok, warn, error

    var label: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .ok: "ok"
        case .warn: "warn"
        case .error: "error"
        }
    }
}

struct PluginState: Identifiable, Equatable, Sendable {
    var id: String { manifest.id }
    let manifest: PluginManifest
    var status: PluginRunStatus = .idle
    var message = "Ready"
}

@MainActor
final class HubRuntime: ObservableObject {
    @Published private(set) var plugins: [PluginState] = []
    @Published private(set) var discoveryError: String?

    private let runner: CommandRunner
    private let decoder = WatchDecoder()
    private var loaded: [String: LoadedPlugin] = [:]
    private var activePluginIDs = Set<String>()

    init(
        pluginRoot: URL? = Bundle.main.url(forResource: "hello-check", withExtension: nil),
        runner: CommandRunner = CommandRunner()
    ) {
        self.runner = runner
        guard let root = pluginRoot else {
            discoveryError = "Bundled hello-check plugin not found"
            return
        }
        do {
            let plugin = try PluginLoader().load(from: root)
            loaded[plugin.manifest.id] = plugin
            plugins = [PluginState(manifest: plugin.manifest)]
        } catch {
            discoveryError = error.localizedDescription
        }
    }

    func runCheck(pluginID: String, checkID: String) async {
        guard let plugin = loaded[pluginID],
              let check = plugin.manifest.checks.first(where: { $0.id == checkID }) else { return }
        await run(command: check.command, timeout: check.timeout?.seconds ?? 30, plugin: plugin)
    }

    func runAction(pluginID: String, actionID: String) async {
        guard let plugin = loaded[pluginID],
              let action = plugin.manifest.actions.first(where: { $0.id == actionID }) else { return }
        await run(command: action.command, timeout: action.timeout?.seconds ?? 3_600, plugin: plugin)
    }

    private func run(command: [String], timeout: TimeInterval, plugin: LoadedPlugin) async {
        guard activePluginIDs.insert(plugin.manifest.id).inserted else { return }
        defer { activePluginIDs.remove(plugin.manifest.id) }
        update(plugin.manifest.id, status: .running, message: "Running…")
        do {
            let result = try await runner.run(
                command: command,
                in: plugin.rootURL,
                pluginID: plugin.manifest.id,
                timeout: timeout
            )
            let decoded = decoder.decode(result.output)
            let events = decoded.events
            let terminal = events.last(where: { [.ok, .warn, .error].contains($0.kind) })
            let emittedError = events.last(where: { $0.kind == .error })
            let status: PluginRunStatus
            if result.timedOut || emittedError != nil || ![0, 1].contains(result.exitCode) {
                status = .error
            } else if result.exitCode == 1 || terminal?.kind == .warn || decoded.hadProtocolWarning || result.truncated {
                status = .warn
            } else {
                status = .ok
            }
            let stderr = String(decoding: result.errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let messageFromResult: String
            if result.timedOut {
                messageFromResult = "Timed out"
            } else if let emittedError {
                messageFromResult = emittedError.message
            } else if ![0, 1].contains(result.exitCode) {
                messageFromResult = stderr.isEmpty ? "Exited \(result.exitCode)" : stderr
            } else if let terminal {
                messageFromResult = terminal.message
            } else if let lastEvent = events.last {
                messageFromResult = lastEvent.message
            } else if !stderr.isEmpty {
                messageFromResult = stderr
            } else {
                messageFromResult = result.exitCode == 0 ? "Completed" : "Exited 1"
            }
            var message = messageFromResult
            if (decoded.hadProtocolWarning || result.truncated), status == .warn {
                message = "Protocol warning: \(message)"
            }
            if result.truncated { message += " (output truncated)" }
            update(plugin.manifest.id, status: status, message: message)
        } catch {
            update(plugin.manifest.id, status: .error, message: error.localizedDescription)
        }
    }

    private func update(_ id: String, status: PluginRunStatus, message: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].status = status
        plugins[index].message = message
    }
}
