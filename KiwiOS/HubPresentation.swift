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

struct RemoteAccessState: Sendable {
    var desired = false
    var enabled = false
    var starting = false
    var stopping = false
    var origin: URL?
    var message = "Remote access is off"
    var challenges: [String: RemoteActionChallenge] = [:]
}
