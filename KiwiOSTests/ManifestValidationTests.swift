import XCTest
@testable import KiwiOS

final class ManifestValidationTests: XCTestCase {
    func testLoadsCompleteManifestAndDecodesDurations() throws {
        let root = try temporaryPlugin(manifest: baseManifest + """

        [[checks]]
        id = "health"
        label = "Health"
        command = ["./check.sh"]
        every = "1ms"
        timeout = "2s"

        [[actions]]
        id = "restart"
        label = "Restart"
        confirm = true
        command = ["./action.sh"]
        timeout = "3m"
        lock = "service"

        [[actions]]
        id = "rebuild"
        label = "Rebuild"
        confirm = false
        command = ["tool-that-need-not-be-installed"]
        timeout = "4h"

        [[ui.pages]]
        id = "status"
        title = "Status"
        kind = "checks"
        source = "checks"

        [[ui.pages]]
        id = "activity"
        title = "Activity"
        kind = "log"
        source = "actions.restart"

        [[ui.sidebar]]
        id = "status"
        label = "Status"
        page = "status"

        [[ui.widgets]]
        id = "health"
        title = "Health"
        kind = "stat"
        source = "checks.health"
        size = "1x1"
        """)
        try makeExecutable(at: root.appendingPathComponent("check.sh"))
        try makeExecutable(at: root.appendingPathComponent("action.sh"))

        let manifest = try PluginLoader().load(from: root).manifest

        XCTAssertEqual(manifest.checks[0].every?.rawValue, "1ms")
        XCTAssertEqual(manifest.checks[0].every?.seconds, 0.001)
        XCTAssertEqual(manifest.checks[0].timeout?.seconds, 2)
        XCTAssertEqual(manifest.actions[0].timeout?.seconds, 180)
        XCTAssertEqual(manifest.actions[0].lock, "service")
        XCTAssertEqual(manifest.actions[1].timeout?.seconds, 14_400)
        XCTAssertEqual(manifest.ui.pages.map(\.id), ["status", "activity"])
        XCTAssertEqual(manifest.ui.sidebar.first?.page, "status")
        XCTAssertEqual(manifest.ui.widgets.first?.source, "checks.health")
        XCTAssertEqual(manifest.brew, [])
    }

    func testValidatesAndDetectsHomebrewRequirements() throws {
        let root = try temporaryPlugin(manifest: baseManifest + "\nbrew = [\"smartmontools\"]")
        XCTAssertEqual(try PluginLoader().load(from: root).manifest.brew, ["smartmontools"])

        let cellar = root.appendingPathComponent("Cellar", isDirectory: true)
        let version = cellar.appendingPathComponent("smartmontools/7.5", isDirectory: true)
        try FileManager.default.createDirectory(
            at: version,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: version.appendingPathComponent("INSTALL_RECEIPT.json"))
        let installation = BrewFormulaStatus.Installation(executable: "/test/brew", cellar: cellar)
        XCTAssertTrue(installation.isInstalled("smartmontools"))
        XCTAssertFalse(installation.isInstalled("missing"))
        let receipt = try XCTUnwrap(installation.receiptIdentity("smartmontools"))
        try Data("{\"changed\":true}".utf8).write(
            to: version.appendingPathComponent("INSTALL_RECEIPT.json")
        )
        XCTAssertNotEqual(installation.receiptIdentity("smartmontools"), receipt)

        let invalid = try temporaryPlugin(manifest: baseManifest + "\nbrew = [\"owner/tap/formula\"]")
        XCTAssertThrowsError(try PluginLoader().load(from: invalid))
    }

    func testRejectsTCCGrantsWithoutPromptFreePreflight() throws {
        for grant in ["fda", "apple-events", "developer-tools", "local-network"] {
            let root = try temporaryPlugin(manifest: baseManifest + """

            [permissions]
            tcc = ["\(grant)"]
            """)
            XCTAssertThrowsError(try PluginLoader().load(from: root), grant) { error in
                XCTAssertEqual(
                    error as? PluginLoadError,
                    .invalidPermission(field: "tcc", value: grant)
                )
            }
        }
    }

    func testDoctorReadinessUsesOnlyHostFindings() {
        let required = [
            DoctorFinding(id: "session", title: "Session", status: .passed, detail: "Ready"),
            DoctorFinding(id: "storage", title: "Storage", status: .passed, detail: "Ready"),
            DoctorFinding(id: "host-tools", title: "Tools", status: .passed, detail: "Ready"),
            DoctorFinding(id: "app-signing", title: "Signing", status: .passed, detail: "Ready"),
            DoctorFinding(id: "database", title: "Database", status: .passed, detail: "Ready"),
            DoctorFinding(id: "launch-at-login", title: "Login", status: .passed, detail: "Ready"),
        ]
        let findings = required + [
            DoctorFinding(id: "monitor/brew-smartmontools", title: "Monitor", status: .blocked, detail: "Missing"),
        ]

        XCTAssertTrue(DoctorReadiness.hostIsReady(findings))
        XCTAssertFalse(DoctorReadiness.hostIsReady([
            DoctorFinding(id: "session", title: "Session", status: .blocked, detail: "Blocked"),
            findings.last!,
        ]))
        XCTAssertTrue(DoctorReadiness.hostIsReady(required.dropLast() + [
            DoctorFinding(id: "launch-at-login", title: "Login", status: .blocked, detail: "Blocked"),
        ], excluding: ["launch-at-login"]))
    }

    func testDoctorClassifiesStorageCapacityAndSigning() {
        func storage(_ capacity: Int64?) -> DoctorFinding {
            HostDoctor.storageFinding(
                isDirectory: true, isReadable: true, isWritable: true, isReadOnly: false,
                availableCapacity: capacity
            )
        }

        XCTAssertEqual(storage(nil).status, .unknown)
        XCTAssertEqual(storage(HostDoctor.minimumAvailableCapacity - 1).status, .blocked)
        XCTAssertEqual(storage(HostDoctor.minimumAvailableCapacity).status, .passed)
        XCTAssertEqual(HostDoctor.signingFinding(teamIdentifier: nil, inspectionSucceeded: true).status, .blocked)
        XCTAssertEqual(HostDoctor.signingFinding(teamIdentifier: "TEAM", inspectionSucceeded: true).status, .passed)
        XCTAssertEqual(HostDoctor.fileVaultFinding("FileVault is On.").status, .passed)
        XCTAssertEqual(HostDoctor.fileVaultFinding("indeterminate").status, .unknown)
    }

    func testHomebrewInstallRequiresExplicitPackageConfirmation() {
        let operation = NativeOperation.homebrewInstall(packages: ["smartmontools"])
        XCTAssertEqual(operation.confirmationTitle, "Install 1 Homebrew package?")
        XCTAssertEqual(operation.confirmationDetail, "KiwiOS will run Homebrew to install:\nsmartmontools")
        XCTAssertEqual(operation.resource, "homebrew")

        let removal = NativeOperation.homebrewUninstall(packages: ["smartmontools"])
        XCTAssertEqual(removal.confirmationTitle, "Uninstall 1 Homebrew package?")
        XCTAssertTrue(removal.confirmationDetail?.contains("smartmontools") == true)
        XCTAssertTrue(removal.confirmationDetail?.contains("not visible") == true)
        XCTAssertEqual(removal.resource, "homebrew")
    }

    func testAbsentDurationsRemainAbsentForRuntimeDefaults() throws {
        let root = try temporaryPlugin(manifest: baseManifest + """

        [[checks]]
        id = "check"
        label = "Check"
        command = ["uninstalled-check-tool"]

        [[actions]]
        id = "action"
        label = "Action"
        confirm = false
        command = ["uninstalled-action-tool"]
        """)

        let manifest = try PluginLoader().load(from: root).manifest

        XCTAssertNil(manifest.checks[0].every)
        XCTAssertNil(manifest.checks[0].timeout)
        XCTAssertNil(manifest.actions[0].timeout)
        XCTAssertNil(manifest.actions[0].lock)
    }

    func testWatchReferencesExistingPluginCheckAndAction() throws {
        let valid = try temporaryPlugin(manifest: baseManifest + """

        [watch]
        status = "health"
        start = "start"

        [[checks]]
        id = "health"
        label = "Health"
        command = ["health-tool"]

        [[actions]]
        id = "start"
        label = "Start"
        confirm = false
        command = ["start-tool"]
        """)
        let watch = try XCTUnwrap(PluginLoader().load(from: valid).manifest.watch)
        XCTAssertEqual(watch.status, "health")
        XCTAssertEqual(watch.start, "start")

        let missing = try temporaryPlugin(manifest: baseManifest + """

        [watch]
        status = "missing"
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: missing)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidWatchReference("checks.missing"))
        }

        let missingAction = try temporaryPlugin(manifest: baseManifest + """

        [watch]
        status = "health"
        start = "missing"

        [[checks]]
        id = "health"
        label = "Health"
        command = ["health-tool"]
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: missingAction)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidWatchReference("actions.missing"))
        }
    }

    func testRejectsUnknownKeysAtEveryManifestScope() throws {
        let cases: [(String, String)] = [
            ("top level", "mystery = true"),
            ("check", """
            [[checks]]
            id = "check"
            label = "Check"
            command = ["check-tool"]
            mystery = true
            """),
            ("action", """
            [[actions]]
            id = "action"
            label = "Action"
            confirm = false
            command = ["action-tool"]
            mystery = true
            """),
            ("ui", """
            [ui]
            mystery = true
            """),
            ("page", """
            [[ui.pages]]
            id = "status"
            title = "Status"
            kind = "checks"
            source = "checks"
            mystery = true
            """),
            ("sidebar", """
            [[ui.pages]]
            id = "status"
            title = "Status"
            kind = "checks"
            source = "checks"

            [[ui.sidebar]]
            id = "status"
            label = "Status"
            page = "status"
            mystery = true
            """),
            ("widget", """
            [[checks]]
            id = "health"
            label = "Health"
            command = ["health-tool"]

            [[ui.widgets]]
            id = "health"
            title = "Health"
            kind = "stat"
            source = "checks.health"
            size = "1x1"
            mystery = true
            """),
        ]

        for (scope, body) in cases {
            let root = try temporaryPlugin(manifest: baseManifest + "\n" + body)
            XCTAssertThrowsError(try PluginLoader().load(from: root), scope) { error in
                guard let loadError = error as? PluginLoadError,
                      case .unknownField(let field) = loadError else {
                    return XCTFail("unexpected error for \(scope): \(error)")
                }
                XCTAssertTrue(field.hasSuffix("mystery"), field)
            }
        }
    }

    func testRejectsInvalidDurations() throws {
        for duration in ["0s", "-1s", "1", "1d", "1.5s", "9223372036854775807h"] {
            let root = try temporaryPlugin(manifest: baseManifest + """

            [[checks]]
            id = "check"
            label = "Check"
            command = ["check-tool"]
            timeout = "\(duration)"
            """)

            XCTAssertThrowsError(try PluginLoader().load(from: root), duration) { error in
                XCTAssertEqual(error as? PluginLoadError, .invalidDuration(duration))
            }
        }
    }

    func testRejectsBlankUserFacingText() throws {
        let root = try temporaryPlugin(manifest: """
        id = "manifest-tests"
        name = "   "
        version = "1.0.0"
        kiwios_api = "1"
        license = "MIT"
        """)

        XCTAssertThrowsError(try PluginLoader().load(from: root)) { error in
            XCTAssertEqual(error as? PluginLoadError, .emptyField("name"))
        }
    }

    func testRejectsInvalidAndDuplicateUIContributions() throws {
        let invalidID = try temporaryPlugin(manifest: baseManifest + """

        [[checks]]
        id = "health"
        label = "Health"
        command = ["health-tool"]

        [[ui.widgets]]
        id = "Bad_ID"
        title = "Health"
        kind = "stat"
        source = "checks.health"
        size = "1x1"
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: invalidID)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidContributionID("Bad_ID"))
        }

        let duplicatePage = try temporaryPlugin(manifest: baseManifest + """

        [[ui.pages]]
        id = "status"
        title = "Status"
        kind = "checks"
        source = "checks"

        [[ui.pages]]
        id = "status"
        title = "Other status"
        kind = "checks"
        source = "checks"
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: duplicatePage)) { error in
            XCTAssertEqual(error as? PluginLoadError, .duplicateDescriptorID("status"))
        }
    }

    func testRejectsBrokenUIReferencesAndKinds() throws {
        let cases: [(PluginLoadError, String)] = [
            (.invalidUIKind("chart"), """
            [[ui.pages]]
            id = "status"
            title = "Status"
            kind = "chart"
            source = "checks"
            """),
            (.invalidSource("checks.missing"), """
            [[ui.pages]]
            id = "status"
            title = "Status"
            kind = "stat"
            source = "checks.missing"
            """),
            (.invalidSource("checks.health"), """
            [[checks]]
            id = "health"
            label = "Health"
            command = ["health-tool"]

            [[ui.pages]]
            id = "actions"
            title = "Actions"
            kind = "actions"
            source = "checks.health"
            """),
            (.invalidSource("checks.health.extra"), """
            [[checks]]
            id = "health"
            label = "Health"
            command = ["health-tool"]

            [[ui.pages]]
            id = "status"
            title = "Status"
            kind = "stat"
            source = "checks.health.extra"
            """),
            (.invalidPageReference("missing"), """
            [[ui.sidebar]]
            id = "missing"
            label = "Missing"
            page = "missing"
            """),
            (.invalidWidgetSize("3x2"), """
            [[checks]]
            id = "health"
            label = "Health"
            command = ["health-tool"]

            [[ui.widgets]]
            id = "health"
            title = "Health"
            kind = "stat"
            source = "checks.health"
            size = "3x2"
            """),
        ]

        for (expectedError, body) in cases {
            let root = try temporaryPlugin(manifest: baseManifest + "\n" + body)
            XCTAssertThrowsError(try PluginLoader().load(from: root)) { error in
                XCTAssertEqual(error as? PluginLoadError, expectedError)
            }
        }
    }

    func testValidatesLocalExecutablesButDoesNotRequireBareTools() throws {
        let bare = try temporaryPlugin(manifest: manifest(command: "tool-that-is-deliberately-not-installed"))
        XCTAssertNoThrow(try PluginLoader().load(from: bare))

        let missing = try temporaryPlugin(manifest: manifest(command: "./missing"))
        XCTAssertThrowsError(try PluginLoader().load(from: missing)) { error in
            XCTAssertEqual(error as? PluginLoadError, .executableMissingOrNotExecutable("check"))
        }

        let nonExecutable = try temporaryPlugin(manifest: manifest(command: "./run"))
        try Data("#!/bin/sh\n".utf8).write(to: nonExecutable.appendingPathComponent("run"))
        XCTAssertThrowsError(try PluginLoader().load(from: nonExecutable)) { error in
            XCTAssertEqual(error as? PluginLoadError, .executableMissingOrNotExecutable("check"))
        }

        let directory = try temporaryPlugin(manifest: manifest(command: "./run"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("run"),
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try PluginLoader().load(from: directory)) { error in
            XCTAssertEqual(error as? PluginLoadError, .executableMissingOrNotExecutable("check"))
        }
    }

    func testRejectsLocalExecutableSymlinkEscape() throws {
        let root = try temporaryPlugin(manifest: manifest(command: "./run"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeExecutable(at: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("run"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try PluginLoader().load(from: root)) { error in
            XCTAssertEqual(error as? PluginLoadError, .invalidCommandPath("check"))
        }
    }

    @MainActor
    func testRuntimeUsesDefaultsAndManifestTimeoutOverrides() async throws {
        let defaultsRoot = try temporaryPlugin(manifest: baseManifest + """

        [[checks]]
        id = "check"
        label = "Check"
        command = ["./slow.sh"]

        [[actions]]
        id = "action"
        label = "Action"
        confirm = false
        command = ["./slow.sh"]
        """)
        try makeExecutable(at: defaultsRoot.appendingPathComponent("slow.sh"), contents: """
        #!/bin/sh
        sleep 0.05
        printf '{"t":"ok","msg":"done"}\n'
        """)
        let defaultsStorage = try temporaryStorage()
        let defaultsRuntime = HubRuntime(
            pluginRoot: defaultsRoot,
            runner: CommandRunner(
                timeout: 0.001,
                pluginDataRoot: defaultsStorage.appendingPathComponent("PluginData")
            ),
            storageRoot: defaultsStorage
        )
        do {
            try await enable("manifest-tests", in: defaultsRuntime)
            let initialCheck = try await terminalCheckStatus(in: defaultsRuntime, contributionID: "check")
            XCTAssertEqual(initialCheck.status, .succeeded)
            await defaultsRuntime.runCheck(pluginID: "manifest-tests", checkID: "check")
            let manualCheck = try await terminalCheckStatus(
                in: defaultsRuntime, contributionID: "check", after: initialCheck.date
            )
            XCTAssertEqual(manualCheck.status, .succeeded)
            await defaultsRuntime.runAction(pluginID: "manifest-tests", actionID: "action")
            let actionJob = try await terminalActionStatus(in: defaultsRuntime, contributionID: "action")
            XCTAssertEqual(actionJob.status, .succeeded)
        } catch {
            await defaultsRuntime.shutdown()
            throw error
        }
        await defaultsRuntime.shutdown()

        let overrideRoot = try temporaryPlugin(manifest: baseManifest + """

        [[checks]]
        id = "check"
        label = "Check"
        command = ["./slow.sh"]
        timeout = "1ms"

        [[actions]]
        id = "action"
        label = "Action"
        confirm = false
        command = ["./slow.sh"]
        timeout = "1ms"
        """)
        try makeExecutable(at: overrideRoot.appendingPathComponent("slow.sh"), contents: """
        #!/bin/sh
        sleep 0.05
        printf '{"t":"ok","msg":"done"}\n'
        """)
        let overrideStorage = try temporaryStorage()
        let overrideRuntime = HubRuntime(
            pluginRoot: overrideRoot,
            runner: CommandRunner(
                timeout: 2,
                pluginDataRoot: overrideStorage.appendingPathComponent("PluginData")
            ),
            storageRoot: overrideStorage
        )
        do {
            try await enable("manifest-tests", in: overrideRuntime)
            let initialCheck = try await terminalCheckStatus(in: overrideRuntime, contributionID: "check")
            XCTAssertEqual(initialCheck.status, .timedOut)
            await overrideRuntime.runCheck(pluginID: "manifest-tests", checkID: "check")
            let manualCheck = try await terminalCheckStatus(
                in: overrideRuntime, contributionID: "check", after: initialCheck.date
            )
            XCTAssertEqual(manualCheck.status, .timedOut)
            await overrideRuntime.runAction(pluginID: "manifest-tests", actionID: "action")
            let actionJob = try await terminalActionStatus(in: overrideRuntime, contributionID: "action")
            XCTAssertEqual(actionJob.status, .timedOut)
        } catch {
            await overrideRuntime.shutdown()
            throw error
        }
        await overrideRuntime.shutdown()
    }

    private let baseManifest = """
    id = "manifest-tests"
    name = "Manifest tests"
    version = "1.0.0"
    kiwios_api = "1"
    license = "MIT"
    """

    private func manifest(command: String) -> String {
        baseManifest + """

        [[checks]]
        id = "check"
        label = "Check"
        command = ["\(command)"]
        """
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
        let review = try XCTUnwrap(runtime.pendingReview,
            runtime.operationError ?? runtime.discoveryError ?? "Plugin review was not created")
        await runtime.approvePlugin(review)
        XCTAssertEqual(runtime.plugins.first(where: { $0.id == pluginID })?.lifecycle, .active)
    }

    @MainActor
    private func terminalActionStatus(
        in runtime: HubRuntime, contributionID: String
    ) async throws -> (status: JobStatus, date: Date) {
        let source = "actions.\(contributionID)"
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            await runtime.refreshResults()
            if let plugin = runtime.plugins.first(where: { $0.id == "manifest-tests" }),
               let result = plugin.results[source], let date = plugin.resultDates[source] {
                return (HubRuntime.jobStatus(result.outcome), date)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for terminal action \(contributionID)")
        throw NSError(domain: "KiwiOSTests", code: 1)
    }

    @MainActor
    private func terminalCheckStatus(
        in runtime: HubRuntime, contributionID: String, after previousDate: Date? = nil
    ) async throws -> (status: JobStatus, date: Date) {
        let source = "checks.\(contributionID)"
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            await runtime.refreshResults()
            if let plugin = runtime.plugins.first(where: { $0.id == "manifest-tests" }),
               let result = plugin.results[source], let date = plugin.resultDates[source],
               previousDate.map({ date > $0 }) ?? true {
                return (HubRuntime.jobStatus(result.outcome), date)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for check result \(contributionID)")
        throw NSError(domain: "KiwiOSTests", code: 1)
    }

    private func makeExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
