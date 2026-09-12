import Darwin
import XCTest
@testable import KiwiOS

final class RuntimeTests: XCTestCase {
    @MainActor
    func testRuntimeDiscoversBundledHelloPlugin() {
        let runtime = HubRuntime()

        XCTAssertEqual(runtime.plugins.map(\.id), ["hello-check"])
    }

    func testLoadsHelloManifestShape() throws {
        let root = try temporaryPlugin(manifest: """
        id = "hello-check"
        name = "Hello"
        version = "0.1.0"
        kiwios_api = "1"
        license = "MIT"

        [[checks]]
        id = "hello"
        label = "Hello"
        command = ["./check.sh"]

        [[actions]]
        id = "ping"
        label = "Ping"
        confirm = true
        command = ["./check.sh"]
        """)
        try makeExecutable(at: root.appendingPathComponent("check.sh"), contents: "#!/bin/sh\nexit 0\n")

        let plugin = try PluginLoader().load(from: root)

        XCTAssertEqual(plugin.manifest.id, "hello-check")
        XCTAssertEqual(plugin.manifest.license, "MIT")
        XCTAssertEqual(plugin.manifest.checks.first?.label, "Hello")
        XCTAssertEqual(plugin.manifest.checks.first?.command, ["./check.sh"])
        XCTAssertEqual(plugin.manifest.actions.first?.confirm, true)
    }

    func testRejectsUnsupportedAPI() throws {
        let root = try temporaryPlugin(manifest: """
        id = "future"
        name = "Future"
        version = "1.0.0"
        kiwios_api = "2"
        license = "MIT"
        """)

        XCTAssertThrowsError(try PluginLoader().load(from: root)) { error in
            XCTAssertEqual(error as? PluginLoadError, .unsupportedAPI("2"))
        }
    }

    func testRejectsInvalidContributionIDAndTraversal() throws {
        let invalidID = try temporaryPlugin(manifest: """
        id = "example.plugin"
        name = "Example"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[checks]]
        id = "Bad_ID"
        label = "Bad"
        command = ["./check.sh"]
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: invalidID)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidContributionID("Bad_ID"))
        }

        let traversal = try temporaryPlugin(manifest: """
        id = "example.plugin"
        name = "Example"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[actions]]
        id = "escape"
        label = "Escape"
        confirm = true
        command = ["../escape.sh"]
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: traversal)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidCommandPath("escape"))
        }

        let absolute = try temporaryPlugin(manifest: """
        id = "example.plugin"
        name = "Example"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[actions]]
        id = "absolute"
        label = "Absolute"
        confirm = true
        command = ["/bin/sh"]
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: absolute)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidCommandPath("absolute"))
        }
    }

    func testRejectsInvalidSemanticVersions() throws {
        for version in ["01.0.0", "1.0", "1.0.0-01", "1.0.0-alpha.01"] {
            let root = try temporaryPlugin(manifest: """
            id = "example.plugin"
            name = "Example"
            version = "\(version)"
            kiwios_api = "1"
            license = "MIT"
            """)

            XCTAssertThrowsError(try PluginLoader().load(from: root), version) { error in
                XCTAssertEqual(error as? PluginLoadError, .invalidVersion(version))
            }
        }
    }

    func testWatchDecoderFallsBackToLogs() {
        let decoded = WatchDecoder().decode(Data("""
        {"t":"ok","msg":"hello"}
        plain stderr
        {"t":"future","msg":"kept"}
        """.utf8))

        XCTAssertEqual(decoded.events, [
            WatchEvent(kind: .ok, message: "hello", level: nil),
            WatchEvent(kind: .log, message: "plain stderr", level: nil),
            WatchEvent(kind: .log, message: "kept", level: "info"),
        ])
        XCTAssertFalse(decoded.hadProtocolWarning)
    }

    func testWatchDecoderMarksMalformedStructuredEvents() {
        let decoded = WatchDecoder().decode(Data("""
        {"t":"ok"
        {"t":"log","lvl":"verbose","msg":"hello"}
        {"t":"state","state":"wrong"}
        """.utf8))

        XCTAssertEqual(decoded.events.count, 3)
        XCTAssertEqual(decoded.events[1], WatchEvent(kind: .log, message: "hello", level: "info"))
        XCTAssertTrue(decoded.hadProtocolWarning)
    }

    func testWatchDecoderRejectsOversizedState() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "t": "state",
            "state": ["value": String(repeating: "x", count: WatchDecoder.maximumStateBytes)],
        ])

        let decoded = WatchDecoder().decode(data)

        XCTAssertEqual(decoded.events.first?.kind, .log)
        XCTAssertTrue(decoded.hadProtocolWarning)
    }

    func testRunnerUsesPluginWorkingDirectoryAndBoundsOutput() async throws {
        let root = try temporaryPlugin(manifest: "id = \"x\"")
        try makeExecutable(at: root.appendingPathComponent("check.sh"), contents: """
        #!/bin/sh
        basename "$PWD"
        printf '1234567890'
        """)

        let result = try await CommandRunner(timeout: 2, maximumOutputBytes: 8)
            .run(command: ["./check.sh"], in: root)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(
            String(decoding: result.output, as: UTF8.self)
                .hasPrefix(root.lastPathComponent.prefix(8))
        )
    }

    func testRunnerResolvesBareExecutableAndSeparatesStderr() async throws {
        let root = try temporaryPlugin(manifest: "id = \"x\"")
        let result = try await CommandRunner(timeout: 2)
            .run(command: ["sh", "-c", "printf output; printf error >&2"], in: root)

        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "output")
        XCTAssertEqual(String(decoding: result.errorOutput, as: UTF8.self), "error")
    }

    func testRunnerTimesOut() async throws {
        let root = try temporaryPlugin(manifest: "id = \"x\"")
        try makeExecutable(at: root.appendingPathComponent("sleep.sh"), contents: """
        #!/bin/sh
        echo started
        sleep 5 &
        echo $! > child.pid
        wait
        """)

        let start = Date()
        let result = try await CommandRunner(timeout: 0.5)
            .run(command: ["./sleep.sh"], in: root)

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "started\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pidText = try String(
            contentsOf: root.appendingPathComponent("child.pid"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(pidText))
        let deadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(kill(childPID, 0), -1, "the timed-out command left a child process running")
    }

    func testCancelingRunnerStopsTheProcessTree() async throws {
        let root = try temporaryPlugin(manifest: "id = \"x\"")
        try makeExecutable(at: root.appendingPathComponent("wait.sh"), contents: """
        #!/bin/sh
        sleep 30 &
        echo $! > child.pid
        wait
        """)
        let task = Task {
            try await CommandRunner(timeout: 30).run(command: ["./wait.sh"], in: root)
        }
        let pidURL = root.appendingPathComponent("child.pid")
        let launchDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: pidURL.path), Date() < launchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(pidText))

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("canceling the caller should cancel the command")
        } catch is CancellationError {
            // Expected.
        }

        let teardownDeadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < teardownDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(kill(childPID, 0), -1, "the canceled command left a child process running")
    }

    @MainActor
    func testRuntimeSkipsAConcurrentRunForTheSamePlugin() async throws {
        let root = try temporaryPlugin(manifest: """
        id = "single-flight"
        name = "Single flight"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[actions]]
        id = "run"
        label = "Run"
        confirm = false
        command = ["./run.sh"]
        """)
        try makeExecutable(at: root.appendingPathComponent("run.sh"), contents: """
        #!/bin/sh
        printf 'run\\n' >> runs.txt
        sleep 0.2
        printf '{"t":"ok","msg":"done"}\\n'
        """)
        let runtime = HubRuntime(
            pluginRoot: root,
            runner: CommandRunner(timeout: 2, pluginDataRoot: root.appendingPathComponent("PluginData"))
        )

        let first = Task { await runtime.runAction(pluginID: "single-flight", actionID: "run") }
        await Task.yield()
        let second = Task { await runtime.runAction(pluginID: "single-flight", actionID: "run") }
        await first.value
        await second.value

        let runs = try String(contentsOf: root.appendingPathComponent("runs.txt"), encoding: .utf8)
        XCTAssertEqual(runs.split(whereSeparator: \.isNewline).count, 1)
    }

    @MainActor
    func testRuntimeSurfacesAProtocolWarning() async throws {
        let root = try temporaryPlugin(manifest: """
        id = "warning"
        name = "Warning"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[checks]]
        id = "check"
        label = "Check"
        command = ["./check.sh"]
        """)
        try makeExecutable(at: root.appendingPathComponent("check.sh"), contents: """
        #!/bin/sh
        printf '{"t":"ok"\\n'
        """)
        let runtime = HubRuntime(
            pluginRoot: root,
            runner: CommandRunner(timeout: 2, pluginDataRoot: root.appendingPathComponent("PluginData"))
        )

        await runtime.runCheck(pluginID: "warning", checkID: "check")

        XCTAssertEqual(runtime.plugins.first?.status, .warn)
        XCTAssertTrue(runtime.plugins.first?.message.hasPrefix("Protocol warning:") == true)
    }

    @MainActor
    func testRuntimeDoesNotUseASuccessMessageForAFailedExit() async throws {
        let root = try temporaryPlugin(manifest: """
        id = "failed-exit"
        name = "Failed exit"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[checks]]
        id = "check"
        label = "Check"
        command = ["./check.sh"]
        """)
        try makeExecutable(at: root.appendingPathComponent("check.sh"), contents: """
        #!/bin/sh
        printf '{"t":"ok","msg":"healthy"}\n'
        exit 2
        """)
        let runtime = HubRuntime(
            pluginRoot: root,
            runner: CommandRunner(pluginDataRoot: root.appendingPathComponent("PluginData"))
        )

        await runtime.runCheck(pluginID: "failed-exit", checkID: "check")

        XCTAssertEqual(runtime.plugins.first?.status, .error)
        XCTAssertEqual(runtime.plugins.first?.message, "Exited 2")
    }

    private func temporaryPlugin(manifest: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.toml"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
