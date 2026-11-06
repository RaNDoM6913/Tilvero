import XCTest
import Foundation
@testable import TilveroApp

final class UpdateDiscoveryTests: XCTestCase {
    func testRealSourcePreviewContractIsNeverAnAppUpdateEvenWithAdditionalZIP() async throws {
        let fixture = UpdateMetadataFixture.source()
        let transport = UpdateFixtureTransport(responses: fixture.responses)
        let result = try await UpdateDiscovery(transport: transport).discover(identity: fixture.identity, channel: .beta)
        XCTAssertEqual(result.availability, .sourceOnly)
        XCTAssertEqual(result.sourceRelease?.kind, .sourcePreview)
        XCTAssertEqual(result.sourceRelease?.build, "2")
        XCTAssertEqual(result.sourceRelease?.releaseURL.absoluteString,
                       "https://github.com/RaNDoM6913/Tilvero/releases/tag/v0.1.0-beta.2")
        XCTAssertNil(result.release)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testStableExcludesPrereleasesAndAllChannelsExcludeDrafts() async throws {
        var fixture = UpdateMetadataFixture.source()
        var result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .stable)
        XCTAssertEqual(result.availability, .noCompatibleRelease)
        fixture.releases[0]["draft"] = true
        fixture.refreshList()
        result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .beta)
        XCTAssertNil(result.sourceRelease)
    }

    func testFilenameAndTagNeverQualifyExecutableAndUnmanifestedBuildIsUnknown() async throws {
        var fixture = UpdateMetadataFixture.source()
        fixture.releases[0]["assets"] = [fixture.asset("Tilvero-9.0-arm64.dmg", id: 25)]
        fixture.refreshList()
        let result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .beta)
        XCTAssertEqual(result.availability, .noCompatibleRelease)
        XCTAssertNil(result.release)
    }

    func testOnlyExplicitCompatiblePublishedManifestCanDescribeNewApp() async throws {
        var fixture = UpdateMetadataFixture.binary(build: "10")
        var result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .beta)
        XCTAssertEqual(result.availability, .appAvailable)
        XCTAssertEqual(result.release?.build, "10")
        XCTAssertEqual(result.release?.kind, .macApp)
        // This is public information, never executable trust or an installer artifact URL.
        for (key, value) in [("mode", "controller"), ("bundleID", "local.tilvero.lab"),
                             ("architecture", "x86_64"), ("notarization", "not-requested")] {
            fixture = .binary(build: "10")
            fixture.manifest[key] = value; fixture.refreshManifest()
            result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
                .discover(identity: fixture.identity, channel: .beta)
            XCTAssertNil(result.release, key)
            XCTAssertNotEqual(result.availability, .current, key)
        }
    }

    func testEqualOlderAndUnknownBuildsCannotClaimNewAppOrFalseCurrent() async throws {
        for (build, availability) in [("2", UpdateAvailability.noCompatibleRelease), ("3", .current), ("4", .appAvailable)] {
            let fixture = UpdateMetadataFixture.binary(build: build)
            let result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
                .discover(identity: fixture.identity, channel: .beta)
            XCTAssertEqual(result.availability, availability)
        }
        var fixture = UpdateMetadataFixture.binary(build: "3")
        fixture.identity = UpdateIdentity(info: ["CFBundleIdentifier": "io.github.random6913.tilvero",
            "TilveroReleaseMode": "monitoring", "TilveroDataScope": "production"])
        let result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .beta)
        XCTAssertEqual(result.availability, .manual)
    }

    func testManifestCannotPromoteDevelopmentBuildAndVersionMismatchCannotClaimCurrent() async throws {
        var fixture = UpdateMetadataFixture.binary(build: "3")
        fixture.identity = UpdateIdentity(info: ["CFBundleIdentifier": "local.tilvero.prototype", "CFBundleVersion": "3"])
        var result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .beta)
        XCTAssertEqual(result.availability, .manual)
        XCTAssertNil(result.release)
        fixture = .binary(build: "3")
        fixture.identity = UpdateIdentity(info: ["CFBundleIdentifier": "io.github.random6913.tilvero",
            "CFBundleVersion": "3", "CFBundleShortVersionString": "0.2.0",
            "TilveroReleaseMode": "monitoring", "TilveroDataScope": "production"])
        result = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            .discover(identity: fixture.identity, channel: .beta)
        XCTAssertEqual(result.availability, .noCompatibleRelease)
    }

    func testMalformedUnsafeOrRateLimitedResponsesFailInsteadOfBecomingCurrent() async throws {
        let fixture = UpdateMetadataFixture.source()
        for response in [UpdateHTTPResponse(data: Data("{}".utf8), statusCode: 200),
                         UpdateHTTPResponse(data: Data(), statusCode: 429, headers: ["retry-after": "60"]),
                         UpdateHTTPResponse(data: Data(), statusCode: 403, headers: ["x-ratelimit-remaining": "0"])] {
            do {
                _ = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: [UpdateDiscovery.releasesURL: response]))
                    .discover(identity: fixture.identity, channel: .beta)
                XCTFail("Expected a failed check")
            } catch let error as UpdateCheckFailure {
                if response.statusCode == 200 { XCTAssertEqual(error, .malformed) }
                else if case .rateLimited = error {} else { XCTFail("Expected rate limit: \(error)") }
            }
        }
        var unsafe = fixture
        var assets = unsafe.releases[0]["assets"] as! [[String: Any]]
        assets[0]["url"] = "https://evil.invalid/manifest"
        unsafe.releases[0]["assets"] = assets; unsafe.refreshList()
        let transport = UpdateFixtureTransport(responses: unsafe.responses)
        do {
            _ = try await UpdateDiscovery(transport: transport).discover(identity: fixture.identity, channel: .beta)
            XCTFail("Unsafe asset endpoint must be rejected")
        } catch { XCTAssertEqual(error as? UpdateCheckFailure, .malformed) }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testMalformedManifestAndExceededResponseBoundFailClosed() async throws {
        var fixture = UpdateMetadataFixture.source()
        fixture.manifest["binaryIncluded"] = true; fixture.refreshManifest()
        do {
            _ = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
                .discover(identity: fixture.identity, channel: .beta)
            XCTFail("Invalid source contract")
        } catch { XCTAssertEqual(error as? UpdateCheckFailure, .malformed) }
        do {
            _ = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses:
                [UpdateDiscovery.releasesURL: UpdateHTTPResponse(data: Data(repeating: 0, count: 2_097_153), statusCode: 200)]))
                .discover(identity: fixture.identity, channel: .beta)
            XCTFail("Oversize response")
        } catch { XCTAssertEqual(error as? UpdateCheckFailure, .responseTooLarge) }
    }

    func testSourceManifestMustKeepTheExistingUTCTimestampContract() async throws {
        var fixture = UpdateMetadataFixture.source()
        fixture.manifest["createdAt"] = "2026-11-02T01:00:00+01:00"
        fixture.refreshManifest()
        do {
            _ = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
                .discover(identity: fixture.identity, channel: .beta)
            XCTFail("Source release timestamps must be UTC, as required by source_release.py")
        } catch { XCTAssertEqual(error as? UpdateCheckFailure, .malformed) }
    }

    func testRateLimitWithNonfiniteRetryHeaderDoesNotExposeAnInvalidDate() async throws {
        let fixture = UpdateMetadataFixture.source()
        do {
            _ = try await UpdateDiscovery(transport: UpdateFixtureTransport(responses: [UpdateDiscovery.releasesURL:
                UpdateHTTPResponse(data: Data(), statusCode: 429, headers: ["retry-after": "nan"])]))
                .discover(identity: fixture.identity, channel: .beta)
            XCTFail("Expected rate limit")
        } catch let error as UpdateCheckFailure {
            guard case .rateLimited(let date) = error else { return XCTFail("Expected rate limit") }
            XCTAssertNil(date)
        }
    }
}

actor UpdateFixtureTransport: UpdateHTTPTransport {
    var responses: [URL: UpdateHTTPResponse]
    var requests: [URLRequest] = []
    var failure: URLError?
    var suspended = false
    init(responses: [URL: UpdateHTTPResponse]) { self.responses = responses }
    func setFailure(_ error: URLError?) { failure = error }
    func suspend() { suspended = true }
    func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        requests.append(request)
        if suspended { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        guard let response = responses[request.url!] else { throw URLError(.badServerResponse) }
        return response
    }
}

struct UpdateMetadataFixture {
    var identity = UpdateIdentity(info: ["CFBundleIdentifier": "io.github.random6913.tilvero",
        "CFBundleVersion": "3", "CFBundleShortVersionString": "0.1.0",
        "TilveroReleaseMode": "monitoring", "TilveroDataScope": "production"])
    var releases: [[String: Any]] = []
    var manifest: [String: Any] = [:]
    var responses: [URL: UpdateHTTPResponse] = [:]
    var manifestURL = URL(string: "https://api.github.com/repos/RaNDoM6913/Tilvero/releases/assets/20")!
    func asset(_ name: String, id: Int, size: Int = 100) -> [String: Any] {
        ["id": id, "name": name, "size": size, "state": "uploaded",
         "url": "https://api.github.com/repos/RaNDoM6913/Tilvero/releases/assets/\(id)",
         "browser_download_url": "https://github.com/RaNDoM6913/Tilvero/releases/download/v0.1.0-beta.2/\(name)"]
    }
    mutating func refreshList() {
        responses[UpdateDiscovery.releasesURL] = UpdateHTTPResponse(data: try! JSONSerialization.data(withJSONObject: releases), statusCode: 200)
    }
    mutating func refreshManifest() {
        responses[manifestURL] = UpdateHTTPResponse(data: try! JSONSerialization.data(withJSONObject: manifest), statusCode: 200)
    }
    static func source() -> Self {
        var value = Self()
        value.releases = [["tag_name": "v0.1.0-beta.2", "name": "Source preview", "body": "Notes <script>plain text</script>",
            "draft": false, "prerelease": true, "published_at": "2026-11-02T00:00:00Z",
            "html_url": "https://github.com/RaNDoM6913/Tilvero/releases/tag/v0.1.0-beta.2",
            "assets": [value.asset("source-release.json", id: 20), value.asset("Tilvero-0.1.0-beta.2-source.zip", id: 21),
                       value.asset("Anything.zip", id: 22)]]]
        value.manifest = ["schemaVersion": 1, "artifactType": "source-preview", "commit": String(repeating: "a", count: 40),
            "tag": "v0.1.0-beta.2", "version": "0.1.0", "build": "2", "channel": "beta", "license": "GPL-3.0-only",
            "buildRequirements": ["architecture": "arm64", "minimumOS": "26.0"], "binaryIncluded": false, "requiresBuild": true,
            "createdAt": "2026-11-02T00:00:00Z", "sourceZIP": ["name": "Tilvero-0.1.0-beta.2-source.zip", "size": 100,
                "sha256": String(repeating: "b", count: 64)]]
        value.refreshList(); value.refreshManifest(); return value
    }
    static func binary(build: String) -> Self {
        var value = source()
        value.releases[0]["assets"] = [value.asset("release.json", id: 20), value.asset("Tilvero-0.1.0-beta.2-arm64.dmg", id: 21),
                                       value.asset("Tilvero-0.1.0-beta.2-source.zip", id: 22)]
        value.manifest = ["schemaVersion": 1, "commit": String(repeating: "a", count: 40), "tag": "v0.1.0-beta.2",
            "version": "0.1.0", "build": build, "channel": "beta", "architecture": "arm64", "minimumOS": "26.0",
            "bundleID": "io.github.random6913.tilvero", "toolchain": "Xcode 27", "signingMode": "developer-id",
            "notarization": "accepted-stapled", "downloadedInstall": "accepted", "publicationReady": true,
            "mode": "monitoring", "teamID": "ABCDE12345", "helperID": "io.github.random6913.tilvero.helper",
            "guardianID": "io.github.random6913.tilvero.guardian", "assets": [
                ["name": "Tilvero-0.1.0-beta.2-arm64.dmg", "size": 100, "sha256": String(repeating: "c", count: 64)],
                ["name": "Tilvero-0.1.0-beta.2-source.zip", "size": 100, "sha256": String(repeating: "d", count: 64)]]]
        value.refreshList(); value.refreshManifest(); return value
    }
}
