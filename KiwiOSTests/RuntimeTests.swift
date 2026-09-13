import Darwin
import XCTest
@testable import KiwiOS

final class RuntimeTests: XCTestCase {
    func testHomebrewInstalledInventoryDecodesFormulaeCasksAndDependencies() throws {
        let status = try NativeHomebrewStatus.decode(path: "/opt/homebrew/bin/brew", data: Data(#"""
        {
          "formulae": [{
            "name": "imagemagick", "full_name": "imagemagick", "desc": "Image tools",
            "tap": "homebrew/core", "versions": {"stable": "7.1.2"}, "revision": 1,
            "installed": [{"version": "7.1.1", "installed_on_request": true}],
            "dependencies": ["libpng"], "outdated": true, "pinned": false, "keg_only": false,
            "future_field": "ignored"
          }],
          "casks": [{
            "token": "firefox", "full_token": "firefox", "name": ["Mozilla Firefox"],
            "desc": "Web browser", "tap": "homebrew/cask", "version": "130.0",
            "installed": "129.0", "depends_on": {"formula": ["libpng"], "cask": "xquartz"},
            "artifacts": [{"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}],
            "outdated": false, "pinned": true
          }]
        }
        """#.utf8))

        guard case .available(let path, let packages) = status else {
            return XCTFail("Expected an available Homebrew inventory")
        }
        XCTAssertEqual(path, "/opt/homebrew/bin/brew")
        XCTAssertEqual(packages.count, 2)
        let formula = try XCTUnwrap(packages.first { $0.kind == .formula })
        XCTAssertEqual(formula.installedVersions, ["7.1.1"])
        XCTAssertEqual(formula.latestVersion, "7.1.2_1")
        XCTAssertEqual(formula.dependencies, [.init(kind: .formula, name: "libpng")])
        XCTAssertTrue(formula.installedOnRequest)
        XCTAssertTrue(formula.outdated)
        let cask = try XCTUnwrap(packages.first { $0.kind == .cask })
        XCTAssertEqual(cask.displayName, "Mozilla Firefox")
        XCTAssertEqual(cask.installedVersions, ["129.0"])
        XCTAssertEqual(cask.dependencies, [
            .init(kind: .formula, name: "libpng"),
            .init(kind: .cask, name: "xquartz"),
        ])
        XCTAssertEqual(cask.applicationPath, "/Applications/Firefox.app")
        XCTAssertTrue(cask.pinned)
    }

    @MainActor
    func testNativeBusyUsesThePersistedResourceNamespace() async throws {
        let runtime = HubRuntime(storageRoot: try temporaryStorage())
        await runtime.waitUntilReady()
        runtime.jobs = [StoredJob(
            id: UUID(), pluginID: "@native", contributionID: "homebrew-install",
            kind: .action, resource: "@native/homebrew", status: .queued,
            requestedBy: "local", createdAt: Date(), scheduledAt: nil,
            startedAt: nil, finishedAt: nil, summary: nil, resultJSON: nil
        )]

        XCTAssertTrue(runtime.isNativeBusy(.homebrewUpdate))
        XCTAssertTrue(runtime.isNativeBusy(.homebrewInstall(packages: ["smartmontools"])))
        XCTAssertFalse(runtime.isNativeBusy(.requestNotificationAuthorization))
        await runtime.shutdown()
    }

    @MainActor
    func testRuntimeDiscoversBundledHelloPlugin() async throws {
        let runtime = HubRuntime(storageRoot: try temporaryStorage())
        await runtime.waitUntilReady()

        XCTAssertEqual(runtime.plugins.map(\.id), ["hello-check", "monitor", "volume-health", "watcher"])
        await runtime.shutdown()
    }

    @MainActor
    func testBundledPluginSurvivesAppBuildDirectoryChange() async throws {
        let storage = try temporaryStorage()
        let store = try PersistenceStore(url: storage.appendingPathComponent("KiwiOS.sqlite"))
        try await store.upsertPlugin(PluginRecord(id: "monitor", name: "Monitor", version: "0.1.0",
            sourceRepository: "/tmp/old-build/KiwiOS.app/Contents/Resources/plugins/monitor",
            sourceCommit: nil, manifestDigest: "old", contentDigest: "old", enabled: false,
            lifecycleState: PluginLifecycle.disabled.rawValue, updatedAt: Date()))

        let runtime = HubRuntime(storageRoot: storage)
        await runtime.waitUntilReady()

        XCTAssertNotEqual(runtime.plugins.first(where: { $0.id == "monitor" })?.lifecycle, .error)
        let migrated = try await store.plugin(id: "monitor")
        XCTAssertEqual(migrated?.sourceRepository, "kiwios-bundled:monitor")
        await runtime.shutdown()
    }

    func testMonitorAcceptsAppleSiliconSmartctlIOServiceDevices() throws {
        let tools = try temporaryStorage()
        try makeExecutable(at: tools.appendingPathComponent("smartctl"), contents: """
        #!/bin/sh
        if [ "$1" = "--scan" ]; then
          echo 'IOService:/AppleARMPE/example/AppleNVMeController/NS_01@1 -d nvme # NVMe device'
        else
          echo '{"temperature":{"current":42}}'
        fi
        """)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugins/monitor/monitor.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "drive-temperatures"]
        process.environment = ["PATH": "\(tools.path):/usr/bin:/bin"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(result.contains("Drive temperatures read successfully"))
        XCTAssertTrue(result.contains("\"temperature-c\":42"))
    }

    func testVolumeHealthTableRunsWithSystemAwk() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugins/volume-health/volume-health.sh")
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "table"]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertTrue(result.contains("\"columns\""))
        XCTAssertTrue(result.contains("\"rows\""))
        XCTAssertFalse(result.contains("\"t\":\"log\""))
        XCTAssertFalse(result.contains("\"mount\":\"/dev\""))
        XCTAssertFalse(result.contains("CoreSimulator"))
        XCTAssertFalse(result.contains("cryptex"))
    }

    func testCompletedJobsDoNotRemainInRuntimeSnapshot() async throws {
        let storage = try temporaryStorage()
        let store = try PersistenceStore(url: storage.appendingPathComponent("KiwiOS.sqlite"))
        let queue = JobQueue(store: store) { _ in
            return JobExecutionResult(status: .succeeded, summary: "Done")
        }
        try await queue.start()

        let check = JobRequest(pluginID: "example", contributionID: "health", kind: .check,
            requestedBy: "scheduler")
        _ = try await queue.submit(check)
        _ = await queue.waitForCompletion(check.id)
        let afterCheck = try await store.runtimeSnapshot()
        XCTAssertTrue(afterCheck.jobs.isEmpty)
        XCTAssertEqual(afterCheck.latestResults.map(\.contributionID), ["health"])

        let action = JobRequest(pluginID: "example", contributionID: "repair", kind: .action,
            requestedBy: "local")
        _ = try await queue.submit(action)
        _ = await queue.waitForCompletion(action.id)
        let afterAction = try await store.runtimeSnapshot()
        XCTAssertTrue(afterAction.jobs.isEmpty)
        XCTAssertEqual(Set(afterAction.latestResults.map(\.contributionID)), Set(["health", "repair"]))
        await queue.shutdown()
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
            runner: CommandRunner(timeout: 2),
            storageRoot: try temporaryStorage()
        )
        try await enable("single-flight", in: runtime)

        let first = Task { await runtime.runAction(pluginID: "single-flight", actionID: "run") }
        await Task.yield()
        let second = Task { await runtime.runAction(pluginID: "single-flight", actionID: "run") }
        await first.value
        await second.value

        let runs = try String(contentsOf: root.appendingPathComponent("runs.txt"), encoding: .utf8)
        XCTAssertEqual(runs.split(whereSeparator: \.isNewline).count, 1)
        await runtime.shutdown()
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
            runner: CommandRunner(timeout: 2),
            storageRoot: try temporaryStorage()
        )
        try await enable("warning", in: runtime)

        await runtime.runCheck(pluginID: "warning", checkID: "check")
        await waitForTerminalState(in: runtime)

        XCTAssertEqual(runtime.plugins.first?.results["checks.check"]?.outcome, .warning)
        XCTAssertTrue(runtime.plugins.first?.message.hasPrefix("Protocol warning:") == true)
        await runtime.shutdown()
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
            runner: CommandRunner(),
            storageRoot: try temporaryStorage()
        )
        try await enable("failed-exit", in: runtime)

        await runtime.runCheck(pluginID: "failed-exit", checkID: "check")
        await waitForTerminalState(in: runtime)

        XCTAssertEqual(runtime.plugins.first?.results["checks.check"]?.outcome, .failed)
        XCTAssertEqual(runtime.plugins.first?.message, "Exited 2")
        await runtime.shutdown()
    }

    @MainActor
    func testConfirmedActionCannotRunBeforeEnableOrBeforeConfirmation() async throws {
        let root = try temporaryPlugin(manifest: """
        id = "confirmed"
        name = "Confirmed"
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"

        [[actions]]
        id = "run"
        label = "Run"
        confirm = true
        command = ["./run.sh"]
        """)
        try makeExecutable(at: root.appendingPathComponent("run.sh"), contents: """
        #!/bin/sh
        touch executed
        """)
        let executed = root.appendingPathComponent("executed")
        let runtime = HubRuntime(pluginRoot: root, storageRoot: try temporaryStorage())
        await runtime.waitUntilReady()

        await runtime.runAction(pluginID: "confirmed", actionID: "run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: executed.path))

        try await enable("confirmed", in: runtime)
        await runtime.runAction(pluginID: "confirmed", actionID: "run")
        XCTAssertNotNil(runtime.pendingConfirmation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: executed.path))
        await runtime.shutdown()
    }

    private func temporaryPlugin(manifest: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.toml"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func temporaryStorage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiwiOSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    private func enable(_ pluginID: String, in runtime: HubRuntime) async throws {
        await runtime.waitUntilReady()
        await runtime.requestEnable(pluginID: pluginID)
        let review = try XCTUnwrap(runtime.pendingReview, runtime.operationError ?? runtime.discoveryError ?? runtime.plugins.map(\.message).joined(separator: "; "))
        await runtime.approvePlugin(review)
        XCTAssertEqual(runtime.plugins.first(where: { $0.id == pluginID })?.lifecycle, .active)
    }

    @MainActor
    private func waitForTerminalState(in runtime: HubRuntime) async {
        let deadline = Date().addingTimeInterval(2)
        while runtime.plugins.first?.results.isEmpty == true {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

final class TailscaleServiceTests: XCTestCase {
    func testReadinessDistinguishesLoginAndHTTPSPrerequisites() async {
        let loggedOut = FakeTailscaleBackend(backendState: "NeedsLogin")
        let loggedOutService = TailscaleService(executable: URL(fileURLWithPath: "/bin/sh")) {
            _, arguments in try await loggedOut.run(arguments)
        }
        let loggedOutState = await loggedOutService.inspect()
        XCTAssertEqual(loggedOutState.unavailability, .loggedOut)

        let noHTTPS = FakeTailscaleBackend(certDomains: [])
        let noHTTPSService = TailscaleService(executable: URL(fileURLWithPath: "/bin/sh")) {
            _, arguments in try await noHTTPS.run(arguments)
        }
        let noHTTPSState = await noHTTPSService.inspect()
        XCTAssertEqual(noHTTPSState.unavailability, .httpsUnavailable)
    }

    func testExactManagedServeLifecycle() async throws {
        let backend = FakeTailscaleBackend()
        let service = TailscaleService(executable: URL(fileURLWithPath: "/bin/sh")) {
            _, arguments in try await backend.run(arguments)
        }

        let plan = try await service.prepare()
        let trust = try await service.start(plan: plan)
        let valid = try await service.validate(trust)
        XCTAssertTrue(valid)
        let managedState = await service.inspect()
        XCTAssertEqual(managedState.status, .managed(origin: trust.origin))

        try await service.stop()
        let availableState = await service.inspect()
        let mutationCount = await backend.mutationCount
        XCTAssertEqual(availableState.status, .available(origin: trust.origin))
        XCTAssertEqual(mutationCount, 2)
    }

    func testServeCleanupFinishesAfterCallerCancellation() async throws {
        let backend = FakeTailscaleBackend()
        let service = TailscaleService(executable: URL(fileURLWithPath: "/bin/sh")) {
            _, arguments in
            try Task.checkCancellation()
            return try await backend.run(arguments)
        }

        let plan = try await service.prepare()
        _ = try await service.start(plan: plan)
        let cleanup = Task { try await service.stop() }
        cleanup.cancel()
        try await cleanup.value

        let state = await service.inspect()
        let mutationCount = await backend.mutationCount
        XCTAssertEqual(state.status, .available(origin: plan.origin))
        XCTAssertEqual(mutationCount, 2)
    }
}

private actor FakeTailscaleBackend {
    private let backendState: String
    private let certDomains: [String]
    private var configured = false
    private(set) var mutationCount = 0

    init(backendState: String = "Running", certDomains: [String] = ["kiwi.example.ts.net"]) {
        self.backendState = backendState
        self.certDomains = certDomains
    }

    func run(_ arguments: [String]) throws -> Data {
        if arguments == ["status", "--json"] {
            return try JSONSerialization.data(withJSONObject: [
                "BackendState": backendState,
                "CertDomains": certDomains,
                "Self": [
                    "DNSName": "kiwi.example.ts.net.",
                ],
            ])
        }
        if arguments == ["serve", "status", "--json"] {
            return try JSONSerialization.data(withJSONObject: configured ? [
                "TCP": ["443": ["HTTPS": true]],
                "Web": [
                    "kiwi.example.ts.net:443": [
                        "Handlers": ["/": ["Proxy": "http://127.0.0.1:31928"]],
                    ],
                ],
            ] : [:])
        }
        if arguments == ["serve", "--bg", "--https=443", "http://127.0.0.1:31928"] {
            configured = true
            mutationCount += 1
            return Data()
        }
        if arguments == ["serve", "--https=443", "off"] {
            configured = false
            mutationCount += 1
            return Data()
        }
        throw TailscaleServiceError.commandFailed("Unexpected test command: \(arguments)")
    }
}
