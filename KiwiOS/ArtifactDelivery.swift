import Foundation
import CryptoKit
import Hummingbird
import HTTPTypes
import NIOCore

struct ArtifactInstallChallenge: Sendable {
    let identity: RemoteIdentity
    let pluginID: String
    let artifactID: String
    let sha256: String
    let label: String
    let expiresAt: Date
}

struct ArtifactGrant: Sendable {
    let pluginID: String
    let artifactID: String
    let sha256: String
    let size: Int64
    let fileURL: URL
    let bundleID: String
    let version: String
    let title: String
    let expiresAt: Date
    var remainingManifestGets: Int
    var remainingIPAGets: Int
}

enum ArtifactDelivery {
    static let maximumIPABytes = 512 * 1_024 * 1_024
    static let grantLifetime: TimeInterval = 10 * 60
    static let maximumConcurrentGrants = 2

    struct IndexItem: Sendable {
        let id: String
        let status: String
        let relativeDir: String
        let ipa: String
        let sha256: String
        let size: Int64
        let project: String
        let title: String
        let version: String
        let build: String
        let bundleID: String
        let createdAt: String
    }

    static func loadIndex(at url: URL) throws -> [IndexItem] {
        let data = try Data(contentsOf: url)
        guard data.count <= 512 * 1_024 else { throw PolicyError.blocked("Build index is too large") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? Int == 1,
              let rawItems = root["items"] as? [[String: Any]] else {
            throw PolicyError.blocked("Build index is missing or unreadable")
        }
        return try rawItems.compactMap { item in
            guard let status = item["status"] as? String else {
                throw PolicyError.blocked("Build index has an unreadable item")
            }
            guard status == "valid" else { return nil }
            guard let id = item["id"] as? String, Self.contributionID(id),
                  let relativeDir = item["relativeDir"] as? String, Self.singleComponent(relativeDir),
                  let ipa = item["ipa"] as? String, ipa.hasSuffix(".ipa"), Self.singleComponent(ipa),
                  let sha256 = item["sha256"] as? String, sha256.count == 64,
                  sha256.allSatisfy(\.isHexDigit),
                  let size = int64(item["size"]), size > 0, size <= maximumIPABytes,
                  let project = item["project"] as? String, !project.isEmpty,
                  let title = item["title"] as? String, !title.isEmpty,
                  let version = item["version"] as? String, !version.isEmpty,
                  let build = item["build"] as? String, !build.isEmpty,
                  let bundleID = item["bundleID"] as? String, !bundleID.isEmpty,
                  let createdAt = item["createdAt"] as? String else {
                throw PolicyError.blocked("Build index has an unreadable valid item")
            }
            return IndexItem(
                id: id, status: status, relativeDir: relativeDir, ipa: ipa, sha256: sha256.lowercased(),
                size: size, project: project, title: title, version: version, build: build,
                bundleID: bundleID, createdAt: createdAt
            )
        }
    }

    static func libraryRoot(_ raw: String, home: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else {
            throw PolicyError.blocked("Set an absolute or ~ library folder")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        let path = url.path
        guard path.hasPrefix(home + "/") || path.hasPrefix("/Volumes/"),
              path != home, path != "/Volumes", path != "/" else {
            throw PolicyError.blocked("The library folder must be a directory under the home folder or /Volumes")
        }
        try requireDirectory(url, label: "library folder")
        return url
    }

    static func revalidate(_ item: IndexItem, root: URL) throws -> URL {
        let directory = root.appendingPathComponent(item.relativeDir, isDirectory: true)
        try requireDirectory(directory, label: "build directory")
        let ipa = directory.appendingPathComponent(item.ipa, isDirectory: false)
        let values = try ipa.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw PolicyError.blocked("The IPA is a symbolic link") }
        guard values.isRegularFile == true else { throw PolicyError.blocked("The IPA is missing") }
        let size = Int64(values.fileSize ?? -1)
        guard size == item.size, size <= maximumIPABytes else {
            throw PolicyError.blocked("The IPA changed or is too large to install")
        }
        let digest = try sha256(of: ipa)
        guard digest == item.sha256 else { throw PolicyError.blocked("The IPA changed after it was indexed") }
        return ipa
    }

    static func manifestPlist(grant: ArtifactGrant, ipaURL: String) -> Data {
        let title = xml(grant.title)
        let bundle = xml(grant.bundleID)
        let version = xml(grant.version)
        let url = xml(ipaURL)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>items</key>
          <array>
            <dict>
              <key>assets</key>
              <array>
                <dict>
                  <key>kind</key>
                  <string>software-package</string>
                  <key>url</key>
                  <string>\(url)</string>
                </dict>
              </array>
              <key>metadata</key>
              <dict>
                <key>bundle-identifier</key>
                <string>\(bundle)</string>
                <key>bundle-version</key>
                <string>\(version)</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>\(title)</string>
              </dict>
            </dict>
          </array>
        </dict>
        </plist>
        """
        return Data(plist.utf8)
    }

    static func fileResponse(url: URL, size: Int64, contentType: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        headers[.contentLength] = "\(size)"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        let path = url.path
        return Response(status: .ok, headers: headers, body: .init(contentLength: Int(size)) { writer in
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 64 * 1_024)
                guard let chunk, !chunk.isEmpty else { break }
                try await writer.write(ByteBuffer(bytes: chunk))
            }
        })
    }

    static func dataResponse(_ data: Data, contentType: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        headers[.contentLength] = "\(data.count)"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1_024 * 1_024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func encodedInstallURL(origin: URL, token: String) -> String {
        let manifest = origin.appending(path: "ota").appending(path: token).appending(path: "manifest.plist")
        let encoded = manifest.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? manifest.absoluteString
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    private static func requireDirectory(_ url: URL, label: String) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw PolicyError.blocked("The \(label) is a symbolic link") }
        guard values.isDirectory == true else { throw PolicyError.blocked("The \(label) is not a directory") }
    }

    private static func contributionID(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func singleComponent(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && value != "." && value != ".."
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double, value.rounded() == value { return Int64(value) }
        return nil
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
