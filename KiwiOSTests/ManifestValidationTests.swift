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
        let defaultsRuntime = HubRuntime(
            pluginRoot: defaultsRoot,
            runner: CommandRunner(
                timeout: 0.001,
                pluginDataRoot: defaultsRoot.appendingPathComponent("PluginData")
            )
        )

        await defaultsRuntime.runCheck(pluginID: "manifest-tests", checkID: "check")
        XCTAssertEqual(defaultsRuntime.plugins.first?.status, .ok)
        await defaultsRuntime.runAction(pluginID: "manifest-tests", actionID: "action")
        XCTAssertEqual(defaultsRuntime.plugins.first?.status, .ok)

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
        let overrideRuntime = HubRuntime(
            pluginRoot: overrideRoot,
            runner: CommandRunner(
                timeout: 2,
                pluginDataRoot: overrideRoot.appendingPathComponent("PluginData")
            )
        )

        await overrideRuntime.runCheck(pluginID: "manifest-tests", checkID: "check")
        XCTAssertEqual(overrideRuntime.plugins.first?.status, .error)
        await overrideRuntime.runAction(pluginID: "manifest-tests", actionID: "action")
        XCTAssertEqual(overrideRuntime.plugins.first?.status, .error)
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

    private func makeExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
