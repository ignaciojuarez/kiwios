import Foundation
import Subprocess
import System

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: Data
    let errorOutput: Data
    let timedOut: Bool
    let canceled: Bool
    let truncated: Bool
}

enum CommandOutputStream: Sendable {
    case stdout, stderr
}

struct CommandOutputChunk: Sendable {
    let stream: CommandOutputStream
    let data: Data
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
        timeout overrideTimeout: TimeInterval? = nil,
        secrets: [String: String] = [:],
        retainPartialResultOnCancellation: Bool = false,
        onOutput: (@Sendable (CommandOutputChunk) async -> Void)? = nil
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
        var inheritedEnvironment = try environment(pluginRoot: pluginRoot, pluginID: pluginID)
        let secretsFile = try makeSecretsFile(secrets)
        defer {
            if let secretsFile { try? FileManager.default.removeItem(at: secretsFile) }
        }
        if let secretsFile { inheritedEnvironment["KIWIOS_SECRETS_FILE"] = secretsFile.path }
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
        return try await ProcessTransport.run(configuration: configuration,
            timeout: overrideTimeout ?? timeout, maximumOutputBytes: maximumOutputBytes,
            secrets: Array(secrets.values), retainPartialResultOnCancellation: retainPartialResultOnCancellation,
            onOutput: onOutput)
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

    private func makeSecretsFile(_ secrets: [String: String]) throws -> URL? {
        guard !secrets.isEmpty else { return nil }
        let data = try JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiwios-secrets-\(UUID().uuidString).json")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

}

enum ProcessTransportError: LocalizedError {
    case outputLimitExceeded
    var errorDescription: String? { "Command output exceeded the allowed capture size" }
}

/// Shared mechanics only. Each caller owns executable, environment, timeout,
/// output overflow and process-group teardown policy through its configuration.
enum ProcessTransport {
    static func run(
        configuration: Subprocess.Configuration,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        maximumErrorBytes: Int? = nil,
        secrets: [String] = [],
        retainPartialResultOnCancellation: Bool = false,
        onOutput: (@Sendable (CommandOutputChunk) async -> Void)? = nil,
        failOnOutputOverflow: Bool = false
    ) async throws -> CommandResult {
        let outputBuffer = BoundedOutputBuffer(limit: maximumOutputBytes, secrets: secrets)
        let errorBuffer = BoundedOutputBuffer(limit: maximumErrorBytes ?? maximumOutputBytes, secrets: secrets)

        var outcome: CommandOutcome
        do {
            outcome = try await withThrowingTaskGroup(of: CommandOutcome.self) { group in
                group.addTask {
                    .completed(try await Self.execute(
                        configuration,
                        outputBuffer: outputBuffer,
                        errorBuffer: errorBuffer,
                        onOutput: onOutput, failOnOutputOverflow: failOnOutputOverflow
                    ))
                }
                group.addTask {
                    let seconds = min(max(0, timeout), 9_223_372_036)
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return .timedOut
                }

                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            guard retainPartialResultOnCancellation else { throw CancellationError() }
            outcome = .canceled
        }
        if Task.isCancelled {
            guard retainPartialResultOnCancellation else { throw CancellationError() }
            outcome = .canceled
        }
        // A canceled reader may still hold a secret-length suffix. Flush it through
        // the same redactor before taking the smaller structured-result snapshots.
        let outputTail = await outputBuffer.finish()
        if !outputTail.isEmpty { await onOutput?(CommandOutputChunk(stream: .stdout, data: outputTail)) }
        let errorTail = await errorBuffer.finish()
        if !errorTail.isEmpty { await onOutput?(CommandOutputChunk(stream: .stderr, data: errorTail)) }
        let output = await outputBuffer.snapshot()
        let errorOutput = await errorBuffer.snapshot()

        switch outcome {
        case .completed(let exitCode):
            return CommandResult(
                exitCode: exitCode,
                output: output.data,
                errorOutput: errorOutput.data,
                timedOut: false,
                canceled: false,
                truncated: output.truncated || errorOutput.truncated
            )
        case .timedOut:
            return CommandResult(
                exitCode: -1,
                output: output.data,
                errorOutput: errorOutput.data,
                timedOut: true,
                canceled: false,
                truncated: output.truncated || errorOutput.truncated
            )
        case .canceled:
            return CommandResult(
                exitCode: -1,
                output: output.data,
                errorOutput: errorOutput.data,
                timedOut: false,
                canceled: true,
                truncated: output.truncated || errorOutput.truncated
            )
        }
    }

    private static func execute(
        _ configuration: Subprocess.Configuration,
        outputBuffer: BoundedOutputBuffer,
        errorBuffer: BoundedOutputBuffer,
        onOutput: (@Sendable (CommandOutputChunk) async -> Void)?,
        failOnOutputOverflow: Bool
    ) async throws -> Int32 {
        let result = try await Subprocess.run(
            configuration,
            input: .none,
            output: .sequence,
            error: .sequence
        ) { execution in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await readBounded(
                        from: execution.standardOutput,
                        stream: .stdout,
                        into: outputBuffer,
                        onOutput: onOutput, failOnOutputOverflow: failOnOutputOverflow
                    )
                }
                group.addTask {
                    try await readBounded(
                        from: execution.standardError,
                        stream: .stderr,
                        into: errorBuffer,
                        onOutput: onOutput, failOnOutputOverflow: failOnOutputOverflow
                    )
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
        stream outputStream: CommandOutputStream,
        into buffer: BoundedOutputBuffer,
        onOutput: (@Sendable (CommandOutputChunk) async -> Void)?,
        failOnOutputOverflow: Bool
    ) async throws {
        for try await chunk in stream {
            let data = Data(buffer: chunk)
            let retained = await buffer.append(data)
            if failOnOutputOverflow, await buffer.truncated { throw ProcessTransportError.outputLimitExceeded }
            if !retained.isEmpty {
                await onOutput?(CommandOutputChunk(stream: outputStream, data: retained))
            }
        }
        let final = await buffer.finish()
        if failOnOutputOverflow, await buffer.truncated { throw ProcessTransportError.outputLimitExceeded }
        if !final.isEmpty {
            await onOutput?(CommandOutputChunk(stream: outputStream, data: final))
        }
    }
}

private struct BoundedOutput: Sendable {
    var data = Data()
    var truncated = false
}

private actor BoundedOutputBuffer {
    private let limit: Int
    private let secrets: [Data]
    private let withheldByteCount: Int
    private var pending = Data()
    private var output = BoundedOutput()

    init(limit: Int, secrets: [String] = []) {
        self.limit = limit
        self.secrets = secrets.filter { !$0.isEmpty }.map { Data($0.utf8) }.sorted { $0.count > $1.count }
        withheldByteCount = max(0, (self.secrets.map(\.count).max() ?? 1) - 1)
    }

    func append(_ chunk: Data) -> Data {
        pending.append(chunk)
        let safeRawCount = max(0, pending.count - withheldByteCount)
        return consume(rawByteCount: safeRawCount)
    }

    func finish() -> Data {
        consume(rawByteCount: pending.count)
    }

    private func consume(rawByteCount: Int) -> Data {
        guard rawByteCount > 0 else { return Data() }
        var redacted = Data()
        var consumed = 0
        if secrets.isEmpty {
            redacted = Data(pending.prefix(rawByteCount))
            consumed = rawByteCount
        }
        while consumed < rawByteCount {
            let remaining = pending.dropFirst(consumed)
            if let secret = secrets.first(where: { remaining.starts(with: $0) }) {
                redacted.append(Data("[REDACTED]".utf8))
                consumed += secret.count
            } else {
                redacted.append(pending[pending.index(pending.startIndex, offsetBy: consumed)])
                consumed += 1
            }
        }
        pending.removeFirst(consumed)
        let remaining = max(0, limit - output.data.count)
        let retained = Data(redacted.prefix(remaining))
        if remaining > 0 {
            output.data.append(retained)
        }
        if redacted.count > remaining {
            output.truncated = true
        }
        // The file sink has its own larger bound; stream every redacted byte to it.
        return redacted
    }

    var truncated: Bool { output.truncated }

    func snapshot() -> BoundedOutput {
        _ = consume(rawByteCount: pending.count)
        return output
    }
}

private enum CommandOutcome: Sendable {
    case completed(Int32)
    case timedOut
    case canceled
}
