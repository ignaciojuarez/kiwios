import Foundation

struct PluginCatalogResult: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let repository: String
    let description: String?
    let stars: Int
    let updatedAt: Date
    let owner: String
}

struct CuratedPluginEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let repository: String
    let commit: String
    let path: String
    let version: String
    let kiwiosAPI: String
    let license: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, repository, commit, path, version, license
        case kiwiosAPI = "kiwios_api"
    }

    init(
        id: String, name: String, repository: String, commit: String, path: String,
        version: String, kiwiosAPI: String, license: String
    ) {
        self.id = id
        self.name = name
        self.repository = repository
        self.commit = commit
        self.path = path
        self.version = version
        self.kiwiosAPI = kiwiosAPI
        self.license = license
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repository = try container.decode(String.self, forKey: .repository)
        commit = try container.decode(String.self, forKey: .commit)
        path = try container.decode(String.self, forKey: .path)
        version = try container.decode(String.self, forKey: .version)
        kiwiosAPI = try container.decode(String.self, forKey: .kiwiosAPI)
        license = try container.decode(String.self, forKey: .license)
    }

    func validate() throws {
        guard id.range(of: #"\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z"#, options: .regularExpression) != nil else {
            throw PluginCatalogError.invalidCuratedCatalog("invalid plugin ID \(id)")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginCatalogError.invalidCuratedCatalog("\(id) has blank metadata")
        }
        guard (try? PluginRepositoryIdentity(repository).canonical) == repository else {
            throw PluginCatalogError.invalidCuratedCatalog("\(id) has a non-normalized repository")
        }
        guard commit.count == 40, commit.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }) else { throw PluginCatalogError.invalidCuratedCatalog("\(id) has an invalid commit") }
        guard PluginLexicalValidator.relativePath(path, allowRoot: true) else {
            throw PluginCatalogError.invalidCuratedCatalog("\(id) has an unsafe plugin path")
        }
        guard SemanticVersion(version) != nil, kiwiosAPI == "1" else {
            throw PluginCatalogError.invalidCuratedCatalog("\(id) has unsupported version metadata")
        }
    }

}

enum PluginCatalogError: LocalizedError {
    case invalidQuery
    case invalidResponse
    case rateLimited(Date?)
    case github(String)
    case invalidCuratedCatalog(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: "Search must be 100 characters or fewer and contain no control characters"
        case .invalidResponse: "GitHub returned an invalid plugin search response"
        case .rateLimited(let date):
            if let date { "GitHub search is rate limited until \(date.formatted())" }
            else { "GitHub search is rate limited; try again later" }
        case .github(let detail): "GitHub search failed: \(detail)"
        case .invalidCuratedCatalog(let detail): "Bundled plugin catalog is invalid: \(detail)"
        }
    }
}

/// User-triggered, unauthenticated discovery for repositories carrying the `kiwios-plugin` topic.
actor PluginCatalog {
    private struct CuratedCatalog: Decodable {
        let schema: String?
        let version: Int
        let plugins: [CuratedPluginEntry]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schema = "$schema"
            case version, plugins
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decodeIfPresent(String.self, forKey: .schema)
            version = try container.decode(Int.self, forKey: .version)
            plugins = try container.decode([CuratedPluginEntry].self, forKey: .plugins)
        }
    }
    private struct CacheEntry {
        let eTag: String?
        let results: [PluginCatalogResult]
    }
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct Owner: Decodable { let login: String }
            let id: Int64
            let name: String
            let htmlURL: String
            let description: String?
            let stars: Int
            let updatedAt: Date
            let owner: Owner
            enum CodingKeys: String, CodingKey {
                case id, name, description, owner
                case htmlURL = "html_url"
                case stars = "stargazers_count"
                case updatedAt = "updated_at"
            }
        }
        let items: [Item]
    }

    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]
    private var nextRequest = Date.distantPast

    init(session: URLSession = .shared) { self.session = session }

    func curatedEntries() throws -> [CuratedPluginEntry] {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "catalog") else {
            throw PluginCatalogError.invalidCuratedCatalog("catalog/catalog.json is missing")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1024 * 1024 else {
            throw PluginCatalogError.invalidCuratedCatalog("catalog.json exceeds 1 MiB")
        }
        let catalog: CuratedCatalog
        do { catalog = try JSONDecoder().decode(CuratedCatalog.self, from: data) }
        catch { throw PluginCatalogError.invalidCuratedCatalog(error.localizedDescription) }
        guard catalog.version == 1 else {
            throw PluginCatalogError.invalidCuratedCatalog("unsupported catalog version \(catalog.version)")
        }
        var ids = Set<String>()
        var revisions = Set<String>()
        for entry in catalog.plugins {
            try entry.validate()
            guard ids.insert(entry.id).inserted else {
                throw PluginCatalogError.invalidCuratedCatalog("duplicate plugin ID \(entry.id)")
            }
            let revision = "\(entry.repository)\n\(entry.commit)\n\(entry.path)"
            guard revisions.insert(revision).inserted else {
                throw PluginCatalogError.invalidCuratedCatalog("duplicate reviewed revision for \(entry.repository)")
            }
        }
        return catalog.plugins.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func search(_ text: String) async throws -> [PluginCatalogResult] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 100, !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginCatalogError.invalidQuery
        }
        let cacheKey = query.lowercased()
        let now = Date()
        let scheduled = max(now, nextRequest)
        nextRequest = scheduled.addingTimeInterval(2)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }

        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [
            URLQueryItem(name: "q", value: ([query, "topic:kiwios-plugin"].filter { !$0.isEmpty }).joined(separator: " ")),
            URLQueryItem(name: "sort", value: "stars"), URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "50"),
        ]
        guard let url = components.url else { throw PluginCatalogError.invalidQuery }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KiwiOS", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let tag = cache[cacheKey]?.eTag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PluginCatalogError.invalidResponse }
        if http.statusCode == 304, let cached = cache[cacheKey] { return cached.results }
        if http.statusCode == 403 || http.statusCode == 429 {
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw PluginCatalogError.rateLimited(reset)
        }
        guard http.statusCode == 200, data.count <= 2 * 1024 * 1024 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw PluginCatalogError.github(message ?? "HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: SearchResponse
        do { payload = try decoder.decode(SearchResponse.self, from: data) }
        catch { throw PluginCatalogError.invalidResponse }
        let results = try payload.items.map { item in
            let repository = try PluginRepositoryIdentity(item.htmlURL).canonical
            return PluginCatalogResult(id: item.id, name: item.name, repository: repository,
                description: item.description, stars: item.stars, updatedAt: item.updatedAt,
                owner: item.owner.login)
        }
        cache[cacheKey] = CacheEntry(eTag: http.value(forHTTPHeaderField: "ETag"), results: results)
        return results
    }
}
