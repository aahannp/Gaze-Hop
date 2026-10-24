import XCTest
@testable import GlanceKit

/// Serves canned responses; no network. Records the paths it was asked for.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var requests = [String]()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.url!.absoluteString)
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UpdaterTests: XCTestCase {
    func makeUpdater(version: String = "0.2.0") -> Updater {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requests = []
        return Updater(session: URLSession(configuration: cfg), apiBase: "https://api.test", webBase: "https://web.test", version: version)
    }

    func release(tag: String, assets: String = #"[{"name":"GazeHop-0.3.0.dmg","browser_download_url":"https://github.com/aahannp/gazehop/releases/download/v0.3.0/GazeHop-0.3.0.dmg","size":1234}]"#) -> Data {
        Data(#"{"tag_name":"\#(tag)","body":"Fixes","html_url":"https://github.com/x","draft":false,"assets":\#(assets)}"#.utf8)
    }

    // MARK: semver

    func testSemverCompare() {
        XCTAssertTrue(UpdateLogic.isNewer("v1.10.0", than: "1.9.2"))
        XCTAssertTrue(UpdateLogic.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(UpdateLogic.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateLogic.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateLogic.isNewer("v0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateLogic.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertTrue(UpdateLogic.isNewer("1.0.0", than: "1.0.0-beta.1"))
        XCTAssertFalse(UpdateLogic.isNewer("1.0.0-beta.1", than: "1.0.0"))
        XCTAssertTrue(UpdateLogic.isNewer("1.0.0-beta.10", than: "1.0.0-beta.2"))
        XCTAssertFalse(UpdateLogic.isNewer("1.0.0+5", than: "1.0.0"))
        XCTAssertEqual(UpdateLogic.cleanVersion("v1.2.3"), "1.2.3")
    }

    // MARK: asset picking

    func testPickAssetPrefersGazeHopDmgAndSkipsChecksums() {
        let a = [UpdateAsset(name: "GazeHop-0.3.0.dmg.sha256", url: "u1", size: 1),
                 UpdateAsset(name: "Other.dmg", url: "u2", size: 1),
                 UpdateAsset(name: "GazeHop-0.3.0.dmg", url: "u3", size: 1)]
        XCTAssertEqual(UpdateLogic.pickAsset(a)?.url, "u3")
        XCTAssertEqual(UpdateLogic.pickAsset(Array(a.prefix(2)))?.url, "u2")
        XCTAssertNil(UpdateLogic.pickAsset([a[0]]))
        XCTAssertNil(UpdateLogic.pickAsset([]))
    }

    // MARK: host allow-list

    func testDownloadHostAllowList() {
        func ok(_ s: String) -> Bool { UpdateLogic.isAllowedDownloadURL(URL(string: s)!) }
        XCTAssertTrue(ok("https://github.com/aahannp/gazehop/releases/download/v1/x.dmg"))
        XCTAssertTrue(ok("https://objects.githubusercontent.com/abc"))
        XCTAssertTrue(ok("https://release-assets.githubusercontent.com/abc"))
        XCTAssertFalse(ok("http://github.com/x.dmg"))
        XCTAssertFalse(ok("https://evilgithub.com/x.dmg"))
        XCTAssertFalse(ok("https://github.com.evil.com/x.dmg"))
        XCTAssertFalse(ok("https://evil.com/github.com/x.dmg"))
        XCTAssertFalse(ok("https://githubusercontent.com.evil.io/x"))
        XCTAssertFalse(ok("file:///etc/passwd"))
    }

    func testRedirectTagParsing() {
        XCTAssertEqual(UpdateLogic.tag(fromReleaseRedirect: "https://github.com/aahannp/gazehop/releases/tag/v0.3.0"), "v0.3.0")
        XCTAssertEqual(UpdateLogic.tag(fromReleaseRedirect: "/aahannp/gazehop/releases/tag/v0.3.0?x=1"), "v0.3.0")
        XCTAssertNil(UpdateLogic.tag(fromReleaseRedirect: "https://github.com/aahannp/gazehop/releases"))
        XCTAssertNil(UpdateLogic.tag(fromReleaseRedirect: nil))
    }

    func testSignerCheck() throws {
        let team = CodeIdentity.Info(identifier: "com.aahan.glanceswitch", teamID: "TEAM1", leafCertHash: Data([1]))
        XCTAssertNoThrow(try CodeIdentity.check(new: team, running: team))
        // renewed certificate, same team: fine
        XCTAssertNoThrow(try CodeIdentity.check(new: .init(identifier: team.identifier, teamID: "TEAM1", leafCertHash: Data([2])), running: team))
        XCTAssertThrowsError(try CodeIdentity.check(new: .init(identifier: team.identifier, teamID: "OTHER", leafCertHash: Data([1])), running: team))
        XCTAssertThrowsError(try CodeIdentity.check(new: .init(identifier: "com.evil", teamID: "TEAM1", leafCertHash: Data([1])), running: team))
        // self-signed (no team): same certificate required
        let selfSigned = CodeIdentity.Info(identifier: team.identifier, teamID: nil, leafCertHash: Data([9]))
        XCTAssertNoThrow(try CodeIdentity.check(new: selfSigned, running: selfSigned))
        XCTAssertThrowsError(try CodeIdentity.check(new: .init(identifier: team.identifier, teamID: nil, leafCertHash: Data([8])), running: selfSigned))
        // ad-hoc running app can't be verified
        let adhoc = CodeIdentity.Info(identifier: team.identifier, teamID: nil, leafCertHash: nil)
        XCTAssertThrowsError(try CodeIdentity.check(new: adhoc, running: adhoc))
    }

    // MARK: mock-server check

    func testCheckFindsNewerRelease() async {
        let u = makeUpdater()
        MockURLProtocol.handler = { _ in (200, [:], self.release(tag: "v0.3.0")) }
        await u.refresh(silent: false)
        XCTAssertEqual(u.state, .available(version: "0.3.0", notes: "Fixes"))
        XCTAssertNotNil(u.lastChecked)
        XCTAssertEqual(MockURLProtocol.requests, ["https://api.test/repos/aahannp/gazehop/releases/latest"])
    }

    func testCheckUpToDateAndCache() async {
        let u = makeUpdater(version: "0.3.0")
        MockURLProtocol.handler = { _ in (200, [:], self.release(tag: "v0.3.0")) }
        await u.refresh(silent: false)
        XCTAssertEqual(u.state, .upToDate)
        await u.refresh(silent: false)
        XCTAssertEqual(MockURLProtocol.requests.count, 1, "second check inside ten minutes comes from the cache")
    }

    func testNoReleasesYetIsUpToDate() async {
        let u = makeUpdater()
        MockURLProtocol.handler = { _ in (404, [:], Data(#"{"message":"Not Found"}"#.utf8)) }
        await u.refresh(silent: false)
        XCTAssertEqual(u.state, .upToDate)
    }

    func testRateLimitFallsBackToReleasePageRedirect() async {
        let u = makeUpdater()
        MockURLProtocol.handler = { req in
            if req.url!.host == "api.test" { return (403, [:], Data(#"{"message":"rate limit"}"#.utf8)) }
            return (302, ["Location": "https://web.test/aahannp/gazehop/releases/tag/v0.4.0"], Data())
        }
        await u.refresh(silent: false)
        XCTAssertEqual(u.state, .available(version: "0.4.0", notes: ""))
        let r = try? await u.fetchLatest(force: false)
        XCTAssertEqual(r?.asset?.url, "https://web.test/aahannp/gazehop/releases/download/v0.4.0/GazeHop-0.4.0.dmg")
    }

    func testFailureReportsAndSilentCheckKeepsState() async {
        let u = makeUpdater()
        MockURLProtocol.handler = { _ in (500, [:], Data()) }
        await u.refresh(silent: true)
        XCTAssertEqual(u.state, .idle, "background check stays quiet")
        await u.refresh(silent: false)
        if case .failed = u.state {} else { XCTFail("expected .failed, got \(u.state)") }
    }

    func testDraftReleaseIsIgnored() {
        let d = Data(#"{"tag_name":"v9.0.0","draft":true,"assets":[]}"#.utf8)
        XCTAssertNil(UpdateLogic.parseRelease(d))
    }
}
