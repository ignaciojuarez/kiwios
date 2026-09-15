import XCTest
@testable import KiwiOS

final class ManifestContractCompletionTests: XCTestCase {
    func testLoadsDependenciesPermissionsConfigAndForm() throws {
        let root = try plugin(id: "configured", extra: """
        [depends]
        "native.jobs" = "1"
        helper = "^0.2.0"

        [permissions]
        exec = ["xcodebuild", "xcrun"]
        read_paths = ["~/Developer"]
        write_paths = ["/Volumes/Builds"]
        network = ["tailnet"]
        ssh_peers = ["build-mac"]
        secrets = ["apple.team-id"]
        tcc = ["accessibility"]
        notify = true

        [config]
        schema = "config.schema.json"

        [[ui.pages]]
        id = "settings"
        title = "Settings"
        kind = "form"
        source = "config"
        """)
        try writeSchema("""
        {
          "type":"object",
          "title":"Build settings",
          "properties": {
            "retries":{"type":"integer","default":3},
            "team":{"type":"string","enum":["A","B"]},
            "token":{"type":"string","writeOnly":true}
          },
          "required":["team"]
        }
        """, in: root)

        let loaded = try PluginLoader().load(from: root)
        XCTAssertEqual(loaded.manifest.depends["helper"], "^0.2.0")
        XCTAssertTrue(loaded.manifest.permissions.notify)
        let schema = try XCTUnwrap(loaded.configSchema)
        XCTAssertEqual(schema.properties["token"]?.writeOnly, true)
        XCTAssertEqual(
            try schema.validated(values: ["team": .string("A")])["retries"],
            .number(3)
        )
    }

    func testRejectsUnknownPermissionAndSchemaFields() throws {
        let permission = try plugin(id: "bad-permission", extra: """
        [permissions]
        filesystem = ["/"]
        """)
        XCTAssertThrowsError(try PluginLoader().load(from: permission)) { error in
            XCTAssertEqual(error as? PluginLoadError, .unknownField("permissions.filesystem"))
        }

        let schema = try plugin(id: "bad-schema", extra: """
        [config]
        schema = "config.schema.json"
        """)
        try writeSchema("""
        {"type":"object","properties":{"name":{"type":"string","minLength":1}}}
        """, in: schema)
        XCTAssertThrowsError(try PluginLoader().load(from: schema)) { error in
            XCTAssertEqual(
                error as? PluginLoadError,
                .invalidConfigSchema("unsupported keyword properties.name.minLength")
            )
        }
    }

    func testConfigValidationRejectsWrongTypesAndMissingRequiredValues() throws {
        let schema = try PluginConfigSchema.decode(Data("""
        {"type":"object","properties":{"count":{"type":"integer"}},"required":["count"]}
        """.utf8))
        XCTAssertThrowsError(try schema.validated(values: [:]))
        XCTAssertThrowsError(try schema.validated(values: ["count": .number(1.5)]))
        XCTAssertEqual(try schema.validated(values: ["count": .number(2)])["count"], .number(2))
    }

    func testIntegerConfigUsesJSONSafeRange() throws {
        let schema = try PluginConfigSchema.decode(Data("""
        {"type":"object","properties":{"count":{"type":"integer"}},"required":["count"]}
        """.utf8))
        let limit = PluginLexicalValidator.maximumSafeInteger
        XCTAssertEqual(try schema.validated(values: ["count": .number(limit)])["count"], .number(limit))
        XCTAssertEqual(try schema.validated(values: ["count": .number(-limit)])["count"], .number(-limit))
        XCTAssertThrowsError(try schema.validated(values: ["count": .number(limit + 1)]))
        XCTAssertThrowsError(try schema.validated(values: ["count": .number(-limit - 1)]))
    }

    func testConfigCASPreservesRecoveryMarkerAfterConflict() async throws {
        let root = try directory()
        let store = try PersistenceStore(url: root.appendingPathComponent("state.sqlite"))
        let firstRevision = try await store.setConfig(
            pluginID: "configured", json: Data("{}".utf8), expectedRevision: 0
        )
        XCTAssertEqual(firstRevision, 1)

        try await store.beginConfigSecretUpdate(pluginID: "configured")
        do {
            _ = try await store.setConfig(
                pluginID: "configured", json: Data("{}".utf8), expectedRevision: 0
            )
            XCTFail("A stale revision must not overwrite configuration")
        } catch PersistenceError.configConflict {}
        let recoveryAfterConflict = try await store.configSecretRecoveryNeeded(pluginID: "configured")
        XCTAssertTrue(recoveryAfterConflict)

        let repairedRevision = try await store.setConfig(
            pluginID: "configured", json: Data("{}".utf8), expectedRevision: 1
        )
        XCTAssertEqual(repairedRevision, 2)
        let recoveryAfterRepair = try await store.configSecretRecoveryNeeded(pluginID: "configured")
        XCTAssertFalse(recoveryAfterRepair)
    }

    func testDependencyCompatibilityAndCycles() throws {
        let consumer = try PluginLoader().load(from: plugin(id: "consumer", extra: """
        [depends]
        helper = "^0.2.0"
        "native.jobs" = "1"
        """))
        let helper = try PluginLoader().load(from: plugin(id: "helper", version: "0.2.7"))
        XCTAssertTrue(DependencyGraphValidator.issues(
            in: [consumer, helper], nativeCapabilities: ["native.jobs": 1]
        ).isEmpty)
        let wrongHelper = try PluginLoader().load(from: plugin(id: "helper", version: "0.3.0"))
        XCTAssertEqual(DependencyGraphValidator.issues(
            in: [consumer, wrongHelper], nativeCapabilities: ["native.jobs": 1]
        )["consumer"], [.incompatible(dependency: "helper", required: "^0.2.0", actual: "0.3.0")])
        let first = try PluginLoader().load(from: plugin(id: "first", extra: "[depends]\nsecond = \"1.0.0\""))
        let second = try PluginLoader().load(from: plugin(id: "second", extra: "[depends]\nfirst = \"1.0.0\""))
        XCTAssertTrue(DependencyGraphValidator.issues(in: [first, second], nativeCapabilities: [:])
            .values.flatMap { $0 }.contains(.cycle(["first", "second", "first"])))
    }

    func testDiscoveryLoadsAllRootsAndRetainsDependencyIssues() throws {
        let bundle = try directory()
        _ = try plugin(id: "alpha", parent: bundle)
        _ = try plugin(id: "beta", parent: bundle, extra: "[depends]\nmissing = \"1.0.0\"")
        let malformed = bundle.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("not valid TOML = [".utf8).write(to: malformed.appendingPathComponent("plugin.toml"))
        let development = try plugin(id: "dev")

        let result = try PluginDiscovery().discover(
            bundledPluginRoots: [bundle], developmentDirectory: development
        )
        XCTAssertEqual(result.plugins.map(\.manifest.id), ["alpha", "beta", "dev"])
        XCTAssertEqual(result.plugins.last?.source, .development)
        XCTAssertEqual(result.dependencyIssues["beta"], [.missing("missing")])
        XCTAssertNil(result.dependencyIssues["alpha"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.path, malformed.path)
    }

    func testDiscoveryRejectsDuplicateIDsAndSourceConflicts() throws {
        let bundle = try directory()
        _ = try plugin(id: "same", parent: bundle)
        let development = try plugin(id: "same")
        _ = try plugin(id: "healthy", parent: bundle)
        let duplicates = try PluginDiscovery().discover(
            bundledPluginRoots: [bundle], developmentDirectory: development
        )
        XCTAssertEqual(duplicates.plugins.map(\.manifest.id), ["healthy"])
        XCTAssertEqual(duplicates.failures.filter { $0.pluginID == "same" }.count, 2)

        let direct = try plugin(id: "direct")
        let conflict = try PluginDiscovery().discover(
            bundledPluginRoots: [direct], developmentDirectory: direct
        )
        XCTAssertTrue(conflict.plugins.isEmpty)
        XCTAssertEqual(conflict.failures.count, 2)
    }

    func testManagedHomebrewOwnershipPersistsUntilForgotten() async throws {
        let root = try directory()
        let store = try PersistenceStore(url: root.appendingPathComponent("state.sqlite"))
        try await store.recordManagedHomebrewFormulae([
            ManagedHomebrewFormula(name: "smartmontools", receiptIdentity: "smart-receipt"),
            ManagedHomebrewFormula(name: "jq", receiptIdentity: "jq-receipt"),
            ManagedHomebrewFormula(name: "smartmontools", receiptIdentity: "smart-receipt"),
        ])
        let recorded = try await store.managedHomebrewFormulae()
        XCTAssertEqual(recorded, [
            ManagedHomebrewFormula(name: "jq", receiptIdentity: "jq-receipt"),
            ManagedHomebrewFormula(name: "smartmontools", receiptIdentity: "smart-receipt"),
        ])

        try await store.forgetManagedHomebrewFormulae(["smartmontools"])
        let remaining = try await store.managedHomebrewFormulae()
        XCTAssertEqual(remaining, [ManagedHomebrewFormula(name: "jq", receiptIdentity: "jq-receipt")])
    }

    func testLayoutBatchPersistsRemotePublicationStateTogether() async throws {
        let store = try PersistenceStore(url: try directory().appendingPathComponent("state.sqlite"))
        let enabled = try JSONEncoder().encode(true)
        let attempt = try JSONEncoder().encode(Optional<RemotePublicationPlan>.none)
        try await store.setLayouts(["remote-enabled": enabled, "remote-publication-attempt": attempt])

        let storedEnabled = try await store.layout(key: "remote-enabled")
        let storedAttempt = try await store.layout(key: "remote-publication-attempt")
        XCTAssertEqual(storedEnabled, enabled)
        XCTAssertEqual(storedAttempt, attempt)
    }

    func testRemoteLayoutAcceptsOnlyKnownUniqueContributions() throws {
        try RemoteLayoutPolicy.validate(
            widgets: ["monitor/temperature"], hiddenWidgets: [], wideWidgets: ["monitor/temperature"],
            sidebar: ["monitor/status"], validWidgetKeys: ["monitor/temperature"],
            validSidebarKeys: ["monitor/status"]
        )
        XCTAssertThrowsError(try RemoteLayoutPolicy.validate(
            widgets: ["monitor/temperature", "monitor/temperature"], hiddenWidgets: [], wideWidgets: [],
            sidebar: [], validWidgetKeys: ["monitor/temperature"], validSidebarKeys: []
        ))
        XCTAssertThrowsError(try RemoteLayoutPolicy.validate(
            widgets: ["unknown/widget"], hiddenWidgets: [], wideWidgets: [], sidebar: [],
            validWidgetKeys: ["monitor/temperature"], validSidebarKeys: []
        ))
    }

    func testRemoteLayoutNormalizationRemovesStaleContributions() {
        let layout = HomeLayout(
            widgets: ["removed/widget", "monitor/temperature"],
            hiddenWidgets: ["removed/widget", "monitor/temperature"],
            wideWidgets: ["removed/widget", "monitor/temperature"],
            sidebar: ["removed/page", "monitor/status"],
            initialized: true
        )
        let normalized = RemoteLayoutPolicy.normalized(
            layout,
            validWidgetKeys: ["monitor/temperature"],
            declaredWideWidgetKeys: [],
            validSidebarKeys: ["monitor/status"]
        )

        XCTAssertEqual(normalized.widgets, ["monitor/temperature"])
        XCTAssertEqual(normalized.hiddenWidgets, ["monitor/temperature"])
        XCTAssertEqual(normalized.wideWidgets, [])
        XCTAssertEqual(normalized.sidebar, ["monitor/status"])
        XCTAssertTrue(normalized.initialized)
    }

    func testRemoteSettingsMutationsDecodeWithoutPluginFields() throws {
        let doctorData = Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000001","operation":"refreshDoctor"}"#.utf8
        )
        try RemoteServer.validateMutationShape(doctorData)
        let doctor = try JSONDecoder().decode(RemoteMutation.self, from: doctorData)
        XCTAssertEqual(doctor.operation, .refreshDoctor)
        let layoutData = Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000002","operation":"saveLayout","widgets":[],"hiddenWidgets":[],"wideWidgets":[],"sidebar":[]}"#.utf8
        )
        try RemoteServer.validateMutationShape(layoutData)
        let layout = try JSONDecoder().decode(RemoteMutation.self, from: layoutData)
        XCTAssertEqual(layout.widgets, [])
        XCTAssertEqual(layout.sidebar, [])
        XCTAssertThrowsError(try RemoteServer.validateMutationShape(Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000003","operation":"refreshDoctor","pluginID":"unexpected"}"#.utf8
        )))
        let enableData = Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000004","operation":"enablePlugin","pluginID":"monitor"}"#.utf8
        )
        try RemoteServer.validateMutationShape(enableData)
        XCTAssertEqual(try JSONDecoder().decode(RemoteMutation.self, from: enableData).operation, .enablePlugin)
        XCTAssertThrowsError(try RemoteServer.validateMutationShape(Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000005","operation":"enablePlugin"}"#.utf8
        )))
    }

    func testRemotePluginLifecycleMutationShapesAreExact() throws {
        let accepted = [
            #"{"requestID":"00000000-0000-0000-0000-000000000006","operation":"requestPluginInstall","repository":"https://github.com/example/plugin"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000040","operation":"requestPluginInstall","repository":"https://github.com/example/plugin","commit":"0123456789abcdef0123456789abcdef01234567","pluginPath":".","catalogID":"example.plugin"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000041","operation":"searchPlugins","query":""}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000042","operation":"searchPlugins","query":"xcodes"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000020","operation":"requestPluginUpdate","pluginID":"monitor"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000007","operation":"confirmPluginInstall","confirmationToken":"token"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000018","operation":"requestPluginDependencies","pluginID":"monitor"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000016","operation":"confirmPluginEnable","confirmationToken":"token"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000008","operation":"requestPluginRemoval","pluginID":"monitor"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000009","operation":"confirmPluginRemoval","confirmationToken":"token"}"#,
        ]
        for json in accepted {
            let data = Data(json.utf8)
            try RemoteServer.validateMutationShape(data)
            _ = try JSONDecoder().decode(RemoteMutation.self, from: data)
        }
        let rejected = [
            #"{"requestID":"00000000-0000-0000-0000-000000000010","operation":"requestPluginInstall"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000021","operation":"requestPluginUpdate"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000011","operation":"requestPluginInstall","repository":"https://github.com/example/plugin","commit":"0123456789abcdef0123456789abcdef01234567"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000043","operation":"requestPluginInstall","repository":"https://github.com/example/plugin","commit":"0123456789abcdef0123456789abcdef01234567","pluginPath":"."}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000044","operation":"requestPluginInstall","repository":"https://github.com/example/plugin","catalogID":"example.plugin"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000045","operation":"searchPlugins"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000046","operation":"searchPlugins","query":null}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000012","operation":"confirmPluginInstall","confirmationToken":"token","pluginID":"monitor"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000017","operation":"confirmPluginEnable","confirmationToken":"token","pluginID":"monitor"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000019","operation":"requestPluginDependencies","pluginID":"monitor","confirmationToken":"token"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000013","operation":"requestPluginRemoval"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000014","operation":"confirmPluginRemoval","confirmationToken":null}"#,
        ]
        for json in rejected {
            XCTAssertThrowsError(try RemoteServer.validateMutationShape(Data(json.utf8)))
        }
        let catalogInstall = Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000040","operation":"requestPluginInstall","repository":"https://github.com/example/plugin","commit":"0123456789abcdef0123456789abcdef01234567","pluginPath":".","catalogID":"example.plugin"}"#.utf8
        )
        let catalogMutation = try JSONDecoder().decode(RemoteMutation.self, from: catalogInstall)
        XCTAssertEqual(catalogMutation.catalogID, "example.plugin")
        XCTAssertEqual(catalogMutation.commit, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(catalogMutation.pluginPath, ".")
        let search = try JSONDecoder().decode(RemoteMutation.self, from: Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000041","operation":"searchPlugins","query":""}"#.utf8
        ))
        XCTAssertEqual(search.operation, .searchPlugins)
        XCTAssertEqual(search.query, "")
    }

    func testCuratedCatalogDecoderRejectsUnknownKeysAndInvalidRevisions() throws {
        let valid = Data(#"""
        {"version":1,"plugins":[{"id":"example.plugin","name":"Example","description":"Reviewed example subtitle","repository":"https://github.com/example/kiwios-plugin","commit":"0123456789abcdef0123456789abcdef01234567","path":".","version":"1.2.0","kiwios_api":"1","license":"MIT"}]}
        """#.utf8)
        let decoded = try PluginCatalog.decodeCuratedEntries(from: valid)
        XCTAssertEqual(decoded.map(\.id), ["example.plugin"])
        XCTAssertEqual(decoded.first?.description, "Reviewed example subtitle")
        XCTAssertEqual(try PluginCatalog.decodeCuratedEntries(from: Data(#"""
        {"version":1,"plugins":[{"id":"example.plugin","name":"Example","repository":"https://github.com/example/kiwios-plugin","commit":"0123456789abcdef0123456789abcdef01234567","path":".","version":"1.2.0","kiwios_api":"1","license":"MIT"}]}
        """#.utf8)).first?.description, nil)
        XCTAssertThrowsError(try PluginCatalog.decodeCuratedEntries(from: Data(#"""
        {"version":1,"plugins":[{"id":"example.plugin","name":"Example","repository":"https://github.com/example/kiwios-plugin","commit":"0123456789abcdef0123456789abcdef01234567","path":".","version":"1.2.0","kiwios_api":"1","license":"MIT","extra":true}]}
        """#.utf8)))
        XCTAssertThrowsError(try PluginCatalog.decodeCuratedEntries(from: Data(#"""
        {"version":1,"plugins":[{"id":"example.plugin","name":"Example","description":"   ","repository":"https://github.com/example/kiwios-plugin","commit":"0123456789abcdef0123456789abcdef01234567","path":".","version":"1.2.0","kiwios_api":"1","license":"MIT"}]}
        """#.utf8)))
        XCTAssertThrowsError(try PluginCatalog.decodeCuratedEntries(from: Data(#"""
        {"version":1,"plugins":[{"id":"example.plugin","name":"Example","repository":"https://github.com/Example/kiwios-plugin","commit":"0123456789abcdef0123456789abcdef01234567","path":".","version":"1.2.0","kiwios_api":"1","license":"MIT"}]}
        """#.utf8)))
        XCTAssertThrowsError(try PluginCatalog.decodeCuratedEntries(from: Data(#"""
        {"version":1,"plugins":[{"id":"example.plugin","name":"Example","repository":"https://github.com/example/kiwios-plugin","commit":"MAIN","path":".","version":"1.2.0","kiwios_api":"1","license":"MIT"}]}
        """#.utf8)))
        let empty = Data(#"{"$schema":"catalog.schema.json","version":1,"plugins":[]}"#.utf8)
        XCTAssertEqual(try PluginCatalog.decodeCuratedEntries(from: empty), [])
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("catalog/catalog.json")
        let bundled = try PluginCatalog.decodeCuratedEntries(from: Data(contentsOf: catalogURL))
        XCTAssertEqual(Set(bundled.map(\.id)), ["ios-build-library", "xcodes"])
        XCTAssertEqual(bundled.map(\.path), [".", "."])
    }

    func testPluginSearchRejectsOversizedAndControlQueries() async {
        let catalog = PluginCatalog()
        do {
            _ = try await catalog.search(String(repeating: "a", count: 101))
            XCTFail("oversized search must fail closed")
        } catch PluginCatalogError.invalidQuery {}
        catch { XCTFail("unexpected error \(error)") }
        do {
            _ = try await catalog.search("xcodes\n")
            XCTFail("control characters must fail closed")
        } catch PluginCatalogError.invalidQuery {}
        catch { XCTFail("unexpected error \(error)") }
    }

    func testPluginUpdaterRequiresAValidHeadAndNewerSemanticVersion() throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(try PluginInstaller.parseRemoteHead(Data("\(sha)\tHEAD\n".utf8)), sha)
        XCTAssertThrowsError(try PluginInstaller.parseRemoteHead(Data("main\tHEAD\n".utf8)))
        XCTAssertTrue(PluginInstaller.isNewerVersion("1.1.0", than: "1.0.9"))
        XCTAssertFalse(PluginInstaller.isNewerVersion("1.0.0", than: "1.0.0"))
        XCTAssertFalse(PluginInstaller.isNewerVersion("1.0.0-beta.1", than: "1.0.0"))
    }

    func testInstalledPluginSubfolderPersistsForUpdates() async throws {
        let store = try PersistenceStore(url: directory().appendingPathComponent("state.sqlite"))
        let record = PluginRecord(id: "nested", name: "Nested", version: "1.0.0",
            sourceRepository: "https://github.com/example/plugins",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567",
            sourcePath: "plugins/nested", manifestDigest: "manifest", contentDigest: "content",
            enabled: true, lifecycleState: "active", updatedAt: Date())
        try await store.upsertPlugin(record)
        let stored = try await store.plugin(id: record.id)
        XCTAssertEqual(stored?.sourcePath, "plugins/nested")
    }

    func testRemotePluginLifecycleRejectsLegacyOperationNames() {
        for operation in ["installPlugin", "updatePlugin", "removePlugin"] {
            XCTAssertThrowsError(try RemoteServer.validateMutationShape(Data(
                "{\"requestID\":\"00000000-0000-0000-0000-000000000015\",\"operation\":\"\(operation)\",\"pluginID\":\"monitor\"}".utf8
            )))
        }
    }

    func testRemoteNativeMutationShapesAreExact() throws {
        let accepted = [
            #"{"requestID":"00000000-0000-0000-0000-000000000011","operation":"refreshNativeTools"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000012","operation":"requestProcessTermination","pid":123}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000013","operation":"requestLaunchAgentRestart","launchAgentLabel":"example.agent"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000014","operation":"confirmNativeOperation","confirmationToken":"token"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000015","operation":"probeSSH","peerName":"Server"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000016","operation":"deliverNotification","title":"KiwiOS","body":"Done"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000028","operation":"requestArtifactInstall","pluginID":"ios-build-library","artifactID":"b-abc"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000029","operation":"confirmArtifactInstall","confirmationToken":"token"}"#,
        ]
        for json in accepted {
            let data = Data(json.utf8)
            try RemoteServer.validateMutationShape(data)
            _ = try JSONDecoder().decode(RemoteMutation.self, from: data)
        }
        let rejected = [
            #"{"requestID":"00000000-0000-0000-0000-000000000021","operation":"requestProcessTermination"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000022","operation":"probeSSH","peerName":"Server","destination":"untrusted"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000023","operation":"deliverNotification","title":"KiwiOS"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000024","operation":"requestLaunchAgentRestart"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000025","operation":"requestLaunchAgentRestart","launchAgentLabel":"example.agent","pid":123}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000026","operation":"refreshNativeTools","pluginID":"unexpected"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000030","operation":"requestArtifactInstall","pluginID":"ios-build-library"}"#,
            #"{"requestID":"00000000-0000-0000-0000-000000000031","operation":"confirmArtifactInstall","confirmationToken":"token","pluginID":"ios-build-library"}"#,
        ]
        for json in rejected {
            XCTAssertThrowsError(try RemoteServer.validateMutationShape(Data(json.utf8)))
        }
        let wrongType = Data(
            #"{"requestID":"00000000-0000-0000-0000-000000000027","operation":"requestProcessTermination","pid":"123"}"#.utf8
        )
        try RemoteServer.validateMutationShape(wrongType)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteMutation.self, from: wrongType))
    }

    func testLaunchAgentRestartRejectsStaleAndDuplicateAgents() throws {
        let agent = NativeLaunchAgent(
            label: "example.agent", plistPath: "/Users/example/Library/LaunchAgents/example.agent.plist",
            isLoaded: true, issue: nil
        )
        XCTAssertNoThrow(try NativeCapabilities.restartableLaunchAgent(label: agent.label, in: [agent]))
        XCTAssertThrowsError(try NativeCapabilities.restartableLaunchAgent(label: agent.label, in: []))
        XCTAssertThrowsError(try NativeCapabilities.restartableLaunchAgent(label: agent.label, in: [agent, agent]))
        XCTAssertThrowsError(try NativeCapabilities.restartableLaunchAgent(
            label: agent.label,
            in: [NativeLaunchAgent(label: agent.label, plistPath: agent.plistPath, isLoaded: nil,
                                    issue: "Duplicate Label appears in more than one owned plist")]
        ))
    }

    func testRemoteNativeConfirmationIsIdentityBoundAndExpires() {
        let owner = RemoteIdentity(login: "owner@example", displayName: "Owner")
        let other = RemoteIdentity(login: "other@example", displayName: "Other")
        let now = Date()
        let process = NativeProcessIdentity(
            pid: 123, uid: 501, startTimeMicroseconds: 456, executablePath: "/example",
            displayName: "Example", bundleIdentifier: nil, canTerminate: true
        )
        let challenge = RemoteNativeChallenge(
            identity: owner, operation: .terminateProcess(process), expiresAt: now.addingTimeInterval(60),
            originPluginID: nil
        )
        XCTAssertTrue(challenge.isValid(for: owner, now: now))
        XCTAssertFalse(challenge.isValid(for: other, now: now))
        XCTAssertFalse(challenge.isValid(for: owner, now: now.addingTimeInterval(60)))
    }

    func testRemotePluginReviewsAreIdentityBoundAndExpire() throws {
        let owner = RemoteIdentity(login: "owner@example", displayName: "Owner")
        let other = RemoteIdentity(login: "other@example", displayName: "Other")
        let now = Date()
        let loaded = try PluginLoader().load(from: plugin(id: "reviewed"))
        let installation = InstallationReview(
            id: UUID(), repository: "https://github.com/example/reviewed",
            commit: "0123456789abcdef0123456789abcdef01234567", pluginPath: ".",
            pluginID: loaded.manifest.id, name: loaded.manifest.name, version: loaded.manifest.version,
            license: loaded.manifest.license, dependencies: [:], brew: [], permissions: [],
            permissionChanges: PermissionDisclosureDiff(added: [], removed: []), manifestDigest: "manifest",
            contentDigest: "content", loadedPlugin: loaded
        )
        let installChallenge = RemoteInstallationChallenge(
            identity: owner, review: installation, missingBrew: [], expiresAt: now.addingTimeInterval(60)
        )
        let removalChallenge = RemoteRemovalChallenge(
            identity: owner, review: PluginRemovalReview(pluginID: "reviewed", name: "Reviewed", homebrew: []),
            expiresAt: now.addingTimeInterval(60)
        )
        for challenge in [installChallenge.isValid(for: owner, now: now), removalChallenge.isValid(for: owner, now: now)] {
            XCTAssertTrue(challenge)
        }
        for challenge in [installChallenge.isValid(for: other, now: now), removalChallenge.isValid(for: owner, now: now.addingTimeInterval(60))] {
            XCTAssertFalse(challenge)
        }
    }

    @MainActor
    func testRemoteNativeToolsWireShapeIsStable() throws {
        let snapshot = NativeToolsSnapshot(
            sampledAt: Date(timeIntervalSince1970: 0),
            processes: [NativeProcessIdentity(
                pid: 123, uid: 501, startTimeMicroseconds: 456,
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                displayName: "Example", bundleIdentifier: "example.app", canTerminate: true
            )],
            launchAgents: [NativeLaunchAgent(
                label: "example.agent", plistPath: "/Users/example/Library/LaunchAgents/example.agent.plist",
                isLoaded: true, issue: nil
            )],
            launchAgentWarning: nil, homebrew: .unavailable,
            power: NativePowerStatus(
                lowPowerModeEnabled: false, fileVault: "On", restartSupport: "Unavailable"
            ),
            notificationAuthorization: .authorized
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let value = try HubRuntime.remoteNativeTools(snapshot, sshPeerNames: ["Server"], encoder: encoder)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "sampledAt", "power", "notifications", "processes", "launchAgents",
            "launchAgentWarning", "sshPeers", "homebrew",
        ])
        let homebrew = try XCTUnwrap(object["homebrew"] as? [String: Any])
        XCTAssertEqual(Set(homebrew.keys), ["status", "packages"])
        XCTAssertEqual(homebrew["status"] as? String, "unavailable")
        let peers = try XCTUnwrap(object["sshPeers"] as? [[String: Any]])
        XCTAssertEqual(peers.first?["name"] as? String, "Server")
        let process = try XCTUnwrap((object["processes"] as? [[String: Any]])?.first)
        XCTAssertEqual(process["pid"] as? Int, 123)
        XCTAssertEqual(process["canTerminate"] as? Bool, true)
    }

    func testHomebrewOwnershipRequiresTheSameReadableReceipt() {
        let managed = ManagedHomebrewFormula(name: "smartmontools", receiptIdentity: "receipt-a")
        XCTAssertTrue(HomebrewCleanupPolicy.owns(managed, currentReceiptIdentity: "receipt-a"))
        XCTAssertFalse(HomebrewCleanupPolicy.owns(managed, currentReceiptIdentity: "receipt-b"))
        XCTAssertFalse(HomebrewCleanupPolicy.owns(managed, currentReceiptIdentity: nil))
        XCTAssertFalse(HomebrewCleanupPolicy.owns(
            ManagedHomebrewFormula(name: "smartmontools", receiptIdentity: nil),
            currentReceiptIdentity: "receipt-a"
        ))
    }

    func testNativeToolsRefreshPolicyUsesAFiveMinuteCache() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NativeToolsRefreshPolicy.needsRefresh(sampledAt: nil, isRefreshing: false, now: now))
        XCTAssertFalse(NativeToolsRefreshPolicy.needsRefresh(
            sampledAt: now.addingTimeInterval(-299), isRefreshing: false, now: now
        ))
        XCTAssertTrue(NativeToolsRefreshPolicy.needsRefresh(
            sampledAt: now.addingTimeInterval(-300), isRefreshing: false, now: now
        ))
        XCTAssertFalse(NativeToolsRefreshPolicy.needsRefresh(sampledAt: nil, isRefreshing: true, now: now))
    }

    func testPluginSetupRequirementSeparatesConfigurationAndAuthorization() {
        let publicConfig = PluginConfigSchema(title: nil, description: nil, properties: [
            "endpoint": PluginConfigField(type: .string, title: nil, description: nil, warning: nil,
                enumValues: nil, defaultValue: nil, writeOnly: false, required: true),
        ])
        let secretConfig = PluginConfigSchema(title: nil, description: nil, properties: [
            "token": PluginConfigField(type: .string, title: nil, description: nil, warning: nil,
                enumValues: nil, defaultValue: nil, writeOnly: true, required: true),
        ])
        let authorization = DoctorFinding(id: "accessibility", title: "Accessibility", status: .blocked, detail: "Grant access")
        XCTAssertEqual(PluginSetupRequirement.classify(configSchema: publicConfig, tcc: [], doctorIssue: nil, configurationIssue: "Missing endpoint"), .configurationRequired)
        XCTAssertEqual(PluginSetupRequirement.classify(configSchema: secretConfig, tcc: [], doctorIssue: nil, configurationIssue: "Missing token"), .attendedSetupRequired)
        XCTAssertEqual(PluginSetupRequirement.classify(configSchema: nil, tcc: ["accessibility"], doctorIssue: authorization, configurationIssue: nil), .authorizationRequired)
        XCTAssertEqual(PluginSetupRequirement.classify(configSchema: nil, tcc: [], doctorIssue: nil, configurationIssue: nil), .ready)
    }

    func testAdmittedNativeGrantRetainsItsApproval() {
        let grant = NativeExecutionGrant(
            operation: .homebrewInstall(packages: ["smartmontools"]),
            requestedBy: "local",
            originPluginID: "monitor"
        )
        XCTAssertEqual(grant.operation, .homebrewInstall(packages: ["smartmontools"]))
    }

    func testHomebrewCleanupPolicyOnlyOffersOwnedUnusedFormulae() {
        let removable = HomebrewCleanupPolicy.item(
            formula: "smartmontools", isInstalled: true, installedByKiwiOS: true,
            otherPluginNames: [], installedDependents: []
        )
        XCTAssertTrue(removable.canUninstall)

        XCTAssertFalse(HomebrewCleanupPolicy.item(
            formula: "smartmontools", isInstalled: true, installedByKiwiOS: false,
            otherPluginNames: [], installedDependents: []
        ).canUninstall)
        XCTAssertFalse(HomebrewCleanupPolicy.item(
            formula: "smartmontools", isInstalled: true, installedByKiwiOS: true,
            otherPluginNames: ["Disk monitor"], installedDependents: []
        ).canUninstall)
        XCTAssertFalse(HomebrewCleanupPolicy.item(
            formula: "smartmontools", isInstalled: true, installedByKiwiOS: true,
            otherPluginNames: [], installedDependents: ["some-tool"]
        ).canUninstall)
        XCTAssertFalse(HomebrewCleanupPolicy.item(
            formula: "smartmontools", isInstalled: true, installedByKiwiOS: true,
            otherPluginNames: [], installedDependents: nil
        ).canUninstall)
    }

    func testPluginRemovalDeletesAllPersistedPluginContent() async throws {
        let root = try directory()
        let store = try PersistenceStore(url: root.appendingPathComponent("state.sqlite"))
        let record = PluginRecord(id: "remove-me", name: "Remove Me", version: "1.0.0",
            sourceRepository: "kiwios-bundled:remove-me", sourceCommit: nil,
            manifestDigest: "manifest", contentDigest: "content", enabled: true,
            lifecycleState: PluginLifecycle.active.rawValue, updatedAt: Date())
        try await store.upsertPlugin(record)
        try await store.recordApproval(ApprovalRecord(pluginID: record.id,
            manifestDigest: record.manifestDigest, contentDigest: record.contentDigest,
            disclosureDigest: record.manifestDigest, sourceRepository: record.sourceRepository,
            sourceCommit: nil, approvedBy: "local", approvedAt: Date()))
        _ = try await store.setConfig(pluginID: record.id, json: Data("{}".utf8), expectedRevision: 0)
        try await store.recordPluginSecretFields(pluginID: record.id, fields: ["token"])

        let job = StoredJob(id: UUID(), pluginID: record.id, contributionID: "run", kind: .action,
            resource: "action-run", status: .queued, requestedBy: "local", createdAt: Date(),
            scheduledAt: nil, startedAt: nil, finishedAt: nil, summary: nil,
            resultJSON: nil)
        try await store.admitJob(job, event: "job.queued")
        try await store.finishJob(id: job.id, status: .succeeded, summary: "Done",
            resultJSON: nil)

        let removal = PendingPluginRemoval(pluginID: record.id,
            secretFields: ["token"], requestedBy: "local")
        try await store.beginPluginRemoval(id: record.id,
            secretFields: removal.secretFields, requestedBy: removal.requestedBy)
        try await store.finishPluginRemoval(removal)

        let removedPlugin = try await store.plugin(id: record.id)
        let removedConfig = try await store.storedConfig(pluginID: record.id)
        let removedSecretFields = try await store.pluginSecretFields(pluginID: record.id)
        XCTAssertNil(removedPlugin)
        XCTAssertEqual(removedConfig, StoredPluginConfig(json: Data("{}".utf8), revision: 0))
        XCTAssertTrue(removedSecretFields.isEmpty)
        let snapshot = try await store.runtimeSnapshot()
        XCTAssertFalse(snapshot.jobs.contains { $0.pluginID == record.id })
        XCTAssertFalse(snapshot.latestResults.contains { $0.pluginID == record.id })
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func plugin(
        id: String, version: String = "1.0.0", parent: URL? = nil, extra: String = ""
    ) throws -> URL {
        let root: URL
        if let parent {
            root = parent.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else { root = try directory() }
        let manifest = """
        id = "\(id)"
        name = "\(id)"
        version = "\(version)"
        kiwios_api = "1"
        license = "MIT"

        \(extra)
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.toml"))
        return root
    }

    private func writeSchema(_ schema: String, in root: URL) throws {
        try Data(schema.utf8).write(to: root.appendingPathComponent("config.schema.json"))
    }
}
