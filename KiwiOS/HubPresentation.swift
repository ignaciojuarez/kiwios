import Foundation

/// Atomic presentation values; services and job admission retain their concrete runtime owners.
struct NativeToolsState: Sendable {
    var toolsSnapshot: NativeToolsSnapshot?
    var toolsRefreshing = false
    var pendingConfirmation: NativeConfirmation?
    var peers: [NamedSSHPeer] = []
    var generation = 0
    var editingPeers = false
}

enum NativeToolsRefreshPolicy {
    static let maximumAge: TimeInterval = 5 * 60

    static func needsRefresh(sampledAt: Date?, isRefreshing: Bool, now: Date = Date()) -> Bool {
        guard !isRefreshing else { return false }
        guard let sampledAt else { return true }
        return now.timeIntervalSince(sampledAt) >= maximumAge
    }
}

struct RemoteAccessState: Sendable {
    var desired = false
    var enabled = false
    var starting = false
    var stopping = false
    var origin: URL?
    var message = "Remote access is off"
    var challenges: [String: RemoteActionChallenge] = [:]
    var nativeChallenges: [String: RemoteNativeChallenge] = [:]
    var pluginEnableChallenges: [String: RemotePluginEnableChallenge] = [:]
    var installationChallenges: [String: RemoteInstallationChallenge] = [:]
    var removalChallenges: [String: RemoteRemovalChallenge] = [:]
    var artifactChallenges: [String: ArtifactInstallChallenge] = [:]
    var artifactGrants: [String: ArtifactGrant] = [:]
}
