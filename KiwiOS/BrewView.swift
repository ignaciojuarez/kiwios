import SwiftUI
import AppKit

struct BrewView: View {
    let status: NativeHomebrewStatus?
    let mode: OperationMode
    let isRefreshing: Bool
    let isBusy: (NativeOperation) -> Bool
    let refresh: @MainActor () async -> Void
    let request: @MainActor (NativeOperation) -> Void

    @State private var query = ""
    @State private var scope = Scope.all

    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case formula = "Formulae"
        case cask = "Casks"
        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Brew").font(.largeTitle)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(isRefreshing)
                }
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Brew")
        .searchable(text: $query, prompt: "Search installed packages")
    }

    @ViewBuilder private var content: some View {
        switch status {
        case nil where isRefreshing:
            ProgressView("Reading installed Homebrew packages…")
        case nil:
            ContentUnavailableView("No Homebrew status", systemImage: "mug",
                                   description: Text("Refresh to inspect installed formulae and casks."))
        case .unavailable:
            ContentUnavailableView("Homebrew not found", systemImage: "mug",
                                   description: Text("KiwiOS supports Homebrew at /opt/homebrew or /usr/local."))
        case .error(let path, let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(message).foregroundStyle(.orange).textSelection(.enabled)
            }
        case .available(let path, let packages):
            inventory(path: path, packages: packages)
        }
    }

    private func inventory(path: String, packages: [NativeHomebrewPackage]) -> some View {
        let formulaCount = packages.count { $0.kind == .formula }
        let caskCount = packages.count { $0.kind == .cask }
        let outdated = packages.filter(\.outdated)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 24) {
                    LabeledContent("Formulae", value: "\(formulaCount)")
                    LabeledContent("Casks", value: "\(caskCount)")
                    LabeledContent("Outdated", value: "\(outdated.count)")
                }
                HStack {
                    let update = NativeOperation.homebrewUpdate
                    Button("Update metadata") { request(update) }
                        .disabled(mode == .remote || isBusy(update))
                    let upgrade = NativeOperation.homebrewUpgrade(packages: outdated.map(\.qualifiedName))
                    Button("Upgrade outdated") { request(upgrade) }
                        .buttonStyle(.borderedProminent)
                        .disabled(mode == .remote || outdated.isEmpty || outdated.count > 50 || isBusy(upgrade))
                    if outdated.count > 50 {
                        Text("More than 50 updates; use Homebrew directly.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if mode == .remote {
                    Text("Homebrew changes are disabled in remote policy mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 14))

            Picker("Package type", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Installed package type")

            let visible = filtered(packages)
            if visible.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No installed packages" : "No matching packages",
                    systemImage: "shippingbox",
                    description: Text(query.isEmpty ? "No packages match this type." : "Try another search or package type.")
                )
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4),
                    spacing: 12
                ) {
                    ForEach(visible) { package in
                        packageCard(package, requiredBy: requiredBy(package, in: packages))
                    }
                }
            }
        }
    }

    private func filtered(_ packages: [NativeHomebrewPackage]) -> [NativeHomebrewPackage] {
        packages.filter { package in
            let inScope = scope == .all
                || scope == .formula && package.kind == .formula
                || scope == .cask && package.kind == .cask
            guard inScope else { return false }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            return ([package.displayName, package.name, package.description ?? "", package.tap ?? ""]
                + package.dependencies.map(\.name))
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private func requiredBy(
        _ package: NativeHomebrewPackage, in packages: [NativeHomebrewPackage]
    ) -> [String] {
        packages.filter { candidate in
            candidate.dependencies.contains {
                $0.kind == package.kind && ($0.name == package.name || $0.name == package.qualifiedName)
            }
        }.map(\.displayName).sorted()
    }

    private func packageCard(_ package: NativeHomebrewPackage, requiredBy: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                packageIcon(package)
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.displayName).font(.headline).lineLimit(2)
                    Text(package.kind == .formula ? "Formula" : "Cask")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if package.outdated {
                    Text("Outdated").font(.caption).foregroundStyle(.orange)
                }
                if package.pinned { Text("Pinned").font(.caption).foregroundStyle(.secondary) }
                if package.kegOnly { Text("Keg-only").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(package.installedVersions.joined(separator: ", "))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            if package.displayName != package.name {
                Text(package.name).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let description = package.description {
                Text(description).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 12) {
                if package.kind == .formula {
                    Text(package.installedOnRequest ? "Installed directly" : "Installed as a dependency")
                }
                if let latest = package.latestVersion,
                   !package.installedVersions.contains(latest) {
                    Text("Latest \(latest)")
                }
                if let tap = package.tap { Text(tap) }
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !package.dependencies.isEmpty {
                Text("Depends on: \(package.dependencies.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !requiredBy.isEmpty {
                Text("Required by: \(requiredBy.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(KiwiTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func packageIcon(_ package: NativeHomebrewPackage) -> some View {
        if let path = package.applicationPath, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: package.kind == .formula ? "terminal" : "app")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
