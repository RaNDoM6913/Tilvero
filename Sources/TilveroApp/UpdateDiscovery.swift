import Foundation

enum UpdateReleaseKind: String, Codable, Sendable { case sourcePreview, macApp, unqualified }
enum UpdateAvailability: String, Codable, Sendable { case appAvailable, current, sourceOnly, manual, noCompatibleRelease }

/// Public metadata only. No archive URL, executable payload, or installer authorization is exposed.
struct UpdateRelease: Equatable, Codable, Sendable {
    let tag: String
    let name: String
    let version: String?
    let build: String?
    let notes: String
    let releaseURL: URL
    let kind: UpdateReleaseKind
}

struct UpdateDiscoveryResult: Equatable, Codable, Sendable {
    let availability: UpdateAvailability
    let release: UpdateRelease?
    let sourceRelease: UpdateRelease?
}

enum UpdateCheckFailure: Error, Equatable, Sendable {
    case offline, timedOut, rateLimited(retryAfter: Date?), malformed, responseTooLarge, unavailable

    static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        guard let error = error as? URLError else { return .unavailable }
        switch error.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed: return .offline
        default: return .unavailable
        }
    }
}

struct UpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    var headers: [String: String] = [:]
}

protocol UpdateHTTPTransport: Sendable {
    func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse
}

/// An ephemeral anonymous session for one bounded metadata response. Bytes are bounded
/// while streaming, before accumulating an arbitrarily large response in memory.
struct URLSessionUpdateTransport: UpdateHTTPTransport {
    func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        guard let url = request.url, UpdateDiscovery.isMetadataURL(url), maximumBytes > 0 else {
            throw UpdateCheckFailure.malformed
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var anonymous = request
        anonymous.timeoutInterval = 15
        anonymous.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        anonymous.httpShouldHandleCookies = false
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        let (bytes, response) = try await session.bytes(for: anonymous)
        guard let response = response as? HTTPURLResponse, let finalURL = response.url,
              UpdateDiscovery.isResponseURL(finalURL) else { throw UpdateCheckFailure.malformed }
        if response.expectedContentLength > Int64(maximumBytes) { throw UpdateCheckFailure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw UpdateCheckFailure.responseTooLarge }
            data.append(byte)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { output, field in
            output[String(describing: field.key).lowercased()] = String(describing: field.value)
        }
        return UpdateHTTPResponse(data: data, statusCode: response.statusCode, headers: headers)
    }
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // API asset downloads can redirect to GitHub's signed object storage. No
        // user-supplied host, HTTP fallback, credentials, or browser endpoint is admitted.
        guard let url = request.url, UpdateDiscovery.isResponseURL(url),
              task.countOfBytesReceived <= 2_097_152 else { completionHandler(nil); return }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(anonymous)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep normal TLS validation; never supply account credentials or accept
        // a different server trust policy for metadata discovery.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

struct UpdateDiscovery: Sendable {
    static let releasesURL = URL(string: "https://api.github.com/repos/RaNDoM6913/Tilvero/releases?per_page=30")!
    static let releasesPageURL = URL(string: "https://github.com/RaNDoM6913/Tilvero/releases")!
    private let transport: any UpdateHTTPTransport
    private let now: @Sendable () -> Date

    init(transport: any UpdateHTTPTransport = URLSessionUpdateTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.now = now
    }

    func discover(identity: UpdateIdentity, channel: UpdateChannel) async throws -> UpdateDiscoveryResult {
        // Bound the entire release-list + manifest operation as well as each
        // URLSession response. Cancelling the check cancels the underlying I/O.
        try await withThrowingTaskGroup(of: UpdateDiscoveryResult.self) { group in
            group.addTask { try await self.load(identity: identity, channel: channel) }
            group.addTask { try await Task.sleep(for: .seconds(35)); throw UpdateCheckFailure.timedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw UpdateCheckFailure.unavailable }
            return result
        }
    }

    private func load(identity: UpdateIdentity, channel: UpdateChannel) async throws -> UpdateDiscoveryResult {
        let data = try await response(url: Self.releasesURL, limit: 2_097_152, asset: false)
        let releases: [GitHubRelease]
        do { releases = try JSONDecoder().decode([GitHubRelease].self, from: data) }
        catch { throw UpdateCheckFailure.malformed }
        guard releases.count <= 30 else { throw UpdateCheckFailure.malformed }
        var sources: [UpdateRelease] = [], apps: [UpdateRelease] = []
        for release in releases where !release.draft && (channel == .beta || !release.prerelease) {
            try Task.checkCancellation()
            guard let page = Self.releaseURL(tag: release.tag_name),
                  release.html_url == page.absoluteString,
                  Self.parseDate(release.published_at) != nil,
                  release.assets.count <= 50 else { throw UpdateCheckFailure.malformed }
            let manifestAssets = release.assets.filter { ["source-release.json", "release.json"].contains($0.name) }
            guard manifestAssets.count <= 1 else { throw UpdateCheckFailure.malformed }
            guard let asset = manifestAssets.first else { continue }
            guard asset.id > 0, asset.state == "uploaded", (1...131_072).contains(asset.size),
                  let url = URL(string: asset.url),
                  url.absoluteString == "https://api.github.com/repos/RaNDoM6913/Tilvero/releases/assets/\(asset.id)" else {
                throw UpdateCheckFailure.malformed
            }
            let manifest = try await response(url: url, limit: 131_072, asset: true)
            if let classified = try classify(manifest: manifest, assetName: asset.name, release: release, page: page) {
                if classified.kind == .sourcePreview { sources.append(classified) }
                else { apps.append(classified) }
            }
        }
        let source = sources.max { Self.isLowerBuild($0, $1) }
        guard identity.supportsInstallerProfile else {
            return UpdateDiscoveryResult(availability: source == nil ? .manual : .sourceOnly, release: nil, sourceRelease: source)
        }
        let latest = apps.max { Self.isLowerBuild($0, $1) }
        if let latest, let build = latest.build, let installed = identity.build,
           let comparison = UpdateIdentity.compareBuilds(build, installed) {
            if comparison == .orderedDescending {
                return UpdateDiscoveryResult(availability: .appAvailable, release: latest, sourceRelease: source)
            }
            if comparison == .orderedSame, latest.version == identity.version {
                return UpdateDiscoveryResult(availability: .current, release: latest, sourceRelease: source)
            }
        }
        return UpdateDiscoveryResult(availability: source == nil ? .noCompatibleRelease : .sourceOnly,
                                     release: nil, sourceRelease: source)
    }

    private func response(url: URL, limit: Int, asset: Bool) async throws -> Data {
        guard Self.isMetadataURL(url) else { throw UpdateCheckFailure.malformed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue(asset ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tilvero-Update-Check", forHTTPHeaderField: "User-Agent")
        let result = try await transport.fetch(request, maximumBytes: limit)
        try Task.checkCancellation()
        guard result.data.count <= limit else { throw UpdateCheckFailure.responseTooLarge }
        let headers = Dictionary(result.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if result.statusCode == 429 || (result.statusCode == 403 && (headers["x-ratelimit-remaining"] == "0" || headers["retry-after"] != nil)) {
            let retry = headers["retry-after"].flatMap(Double.init).flatMap { seconds -> Date? in
                guard seconds.isFinite, (0...604_800).contains(seconds) else { return nil }
                return now().addingTimeInterval(seconds)
            } ?? headers["x-ratelimit-reset"].flatMap(Double.init).flatMap { epoch -> Date? in
                guard epoch.isFinite else { return nil }
                let date = Date(timeIntervalSince1970: epoch)
                guard date >= now(), date <= now().addingTimeInterval(604_800) else { return nil }
                return date
            }
            throw UpdateCheckFailure.rateLimited(retryAfter: retry)
        }
        guard result.statusCode == 200 else { throw UpdateCheckFailure.unavailable }
        return result.data
    }

    private func classify(manifest data: Data, assetName: String, release: GitHubRelease, page: URL) throws -> UpdateRelease? {
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateCheckFailure.malformed }
            object = value
        } catch { throw UpdateCheckFailure.malformed }
        guard integer(object["schemaVersion"]) == 1,
              let tag = object["tag"] as? String, tag == release.tag_name,
              let version = object["version"] as? String, version == Self.version(from: tag),
              let build = object["build"] as? String, UpdateIdentity.validBuild(build),
              object["channel"] as? String == (release.prerelease ? "beta" : "stable"),
              release.prerelease == tag.contains("-beta."),
              let commit = object["commit"] as? String, Self.matches(commit, "^[0-9a-f]{40}$") else {
            throw UpdateCheckFailure.malformed
        }
        let kind: UpdateReleaseKind
        if assetName == "source-release.json" {
            let required: Set<String> = ["schemaVersion", "artifactType", "commit", "tag", "version", "build", "channel",
                "license", "buildRequirements", "binaryIncluded", "requiresBuild", "createdAt", "sourceZIP"]
            guard Set(object.keys) == required, object["artifactType"] as? String == "source-preview",
                  boolean(object["binaryIncluded"]) == false, boolean(object["requiresBuild"]) == true,
                  object["license"] as? String == "GPL-3.0-only",
                  let createdAt = object["createdAt"] as? String,
                  (createdAt.hasSuffix("Z") || createdAt.hasSuffix("+00:00")), Self.parseDate(createdAt) != nil,
                  let requirements = object["buildRequirements"] as? [String: String],
                  requirements == ["architecture": "arm64", "minimumOS": "26.0"],
                  let zip = object["sourceZIP"] as? [String: Any],
                  validAssetRecord(zip, expectedName: "Tilvero-\(tag.dropFirst())-source.zip", release: release) else {
                throw UpdateCheckFailure.malformed
            }
            kind = .sourcePreview
        } else {
            let required: Set<String> = ["schemaVersion", "commit", "tag", "version", "build", "channel", "architecture",
                "minimumOS", "bundleID", "toolchain", "signingMode", "notarization", "downloadedInstall", "publicationReady",
                "assets", "mode", "teamID", "helperID", "guardianID"]
            guard required.isSubset(of: Set(object.keys)), Set(object.keys).subtracting(required) .isSubset(of: ["createdAt"]),
                  let assets = object["assets"] as? [[String: Any]], assets.count == 2,
                  let toolchain = object["toolchain"] as? String, !toolchain.isEmpty else { throw UpdateCheckFailure.malformed }
            // These declarations describe a public Mac release. Sparkle independently
            // validates the signed appcast/archive and the installed signing identity.
            guard object["mode"] as? String == "monitoring", object["bundleID"] as? String == "io.github.random6913.tilvero",
                  object["architecture"] as? String == "arm64", object["minimumOS"] as? String == "26.0",
                  object["helperID"] as? String == "io.github.random6913.tilvero.helper",
                  object["guardianID"] as? String == "io.github.random6913.tilvero.guardian",
                  object["signingMode"] as? String == "developer-id", object["notarization"] as? String == "accepted-stapled",
                  object["downloadedInstall"] as? String == "accepted", boolean(object["publicationReady"]) == true,
                  let team = object["teamID"] as? String, Self.matches(team, "^[A-Z0-9]{10}$") else { return nil }
            let dmg = "Tilvero-\(tag.dropFirst())-arm64.dmg", zip = "Tilvero-\(tag.dropFirst())-source.zip"
            guard Set(assets.compactMap { $0["name"] as? String }) == [dmg, zip],
                  assets.allSatisfy({ validAssetRecord($0, expectedName: $0["name"] as? String ?? "", release: release) }) else {
                throw UpdateCheckFailure.malformed
            }
            kind = .macApp
        }
        return UpdateRelease(tag: tag, name: String((release.name ?? tag).prefix(256)), version: version, build: build,
                             notes: String((release.body ?? "").prefix(65_536)), releaseURL: page, kind: kind)
    }

    private func validAssetRecord(_ record: [String: Any], expectedName: String, release: GitHubRelease) -> Bool {
        guard Set(record.keys) == ["name", "size", "sha256"], record["name"] as? String == expectedName,
              let size = integer(record["size"]), size > 0,
              let hash = record["sha256"] as? String, Self.matches(hash, "^[0-9a-f]{64}$") else { return false }
        let listed = release.assets.filter { $0.name == expectedName }
        return listed.count == 1 && listed[0].size == size && listed[0].state == "uploaded"
    }

    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue <= Double(Int.max),
              number.doubleValue >= Double(Int.min) else { return nil }
        return number.intValue
    }

    static func releaseURL(tag: String) -> URL? {
        guard matches(tag, "^v[0-9]+\\.[0-9]+\\.[0-9]+(-beta\\.[1-9][0-9]*)?$"), tag.utf8.count <= 128 else { return nil }
        return URL(string: "https://github.com/RaNDoM6913/Tilvero/releases/tag/\(tag)")
    }

    static func isMetadataURL(_ url: URL) -> Bool {
        guard safeHTTPS(url), url.host == "api.github.com" else { return false }
        if url == releasesURL { return true }
        return url.query == nil && matches(url.path, "^/repos/RaNDoM6913/Tilvero/releases/assets/[1-9][0-9]*$")
    }

    static func isResponseURL(_ url: URL) -> Bool {
        safeHTTPS(url) && (isMetadataURL(url) || (url.host == "release-assets.githubusercontent.com" && url.path.hasPrefix("/github-production-release-asset/")))
    }

    private static func safeHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.port == nil && url.user == nil && url.password == nil && url.fragment == nil
    }
    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }
    private static func version(from tag: String) -> String { String(tag.dropFirst()).components(separatedBy: "-beta.")[0] }
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    private static func isLowerBuild(_ lhs: UpdateRelease, _ rhs: UpdateRelease) -> Bool {
        guard let left = lhs.build, let right = rhs.build else { return false }
        return UpdateIdentity.compareBuilds(left, right) == .orderedAscending
    }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let html_url: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let id: Int
    let name: String
    let size: Int
    let state: String
    let url: String
}
