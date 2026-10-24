// Updates, the same way Relay and Task Notes do them: ask GitHub for the newest release of this app, and
// if it is newer, download its .dmg. Unlike them we also install it: verify the new app is signed by the
// same team with the same bundle id, swap it into place and relaunch.
//
// CONTRACT (Lead): the UI (Settings → Updates, the "Check for Updates…" menu item) builds against this
// surface only. The packaging worker owns the implementation and may add private members freely.

import Foundation
import Combine
import AppKit
import Security
import CryptoKit

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, notes: String)
    case downloading(progress: Double)      // 0...1
    case installing
    case failed(String)
}

public final class Updater: ObservableObject {
    public static let shared = Updater()

    /// GitHub `owner/repo` whose latest release is checked.
    public static let repo = "aahannp/gazehop"

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastChecked: Date?

    /// CFBundleShortVersionString of the running app.
    public var currentVersion: String {
        versionOverride ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Check on launch and every few hours (defaults key `glance.update.auto`, default on).
    public var automaticallyChecks: Bool {
        get { UserDefaults.standard.object(forKey: "glance.update.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "glance.update.auto") }
    }

    /// Start the periodic background check (call once at launch). Never shows UI by itself.
    public func start() {
        guard timer == nil else { return }
        if automaticallyChecks { runCheck(silent: true) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self, self.automaticallyChecks else { return }
            self.runCheck(silent: true)
        }
    }

    /// Check GitHub now; result lands in `state`.
    public func checkNow() { runCheck(silent: false) }

    /// Download, verify (same Team ID + bundle id), replace the installed app and relaunch.
    public func installUpdate() {
        guard busy == false, case .available = state, let release = latest, let asset = release.asset else { return }
        busy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(release: release, asset: asset)
            } catch {
                await self.set(.failed(Self.message(error)))
            }
            self.busy = false
        }
    }

    // MARK: Internals

    static let checkInterval: TimeInterval = 6 * 3600
    static let cacheTTL: TimeInterval = 10 * 60
    static let installPath = "/Applications/GazeHop.app"

    private let session: URLSession
    private let apiBase: String
    private let webBase: String
    private let versionOverride: String?
    private var timer: Timer?
    private var busy = false
    private var latest: UpdateRelease?
    private var cache: (at: Date, release: UpdateRelease?)?
    private var checking = false

    init(session: URLSession = .shared,
         apiBase: String = "https://api.github.com",
         webBase: String = "https://github.com",
         version: String? = nil) {
        self.session = session
        self.apiBase = apiBase
        self.webBase = webBase
        self.versionOverride = version
    }

    private func set(_ s: UpdateState) async { await MainActor.run { self.state = s } }

    private func runCheck(silent: Bool) {
        guard !busy, !checking else { return }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            await self.refresh(silent: silent)
            self.checking = false
        }
    }

    /// One check, result into `state`. `silent` (background checks) leaves the state alone on a network error.
    func refresh(silent: Bool) async {
        let before = state
        if !silent { await set(.checking) }
        do {
            let release = try await fetchLatest(force: false)
            latest = release
            await MainActor.run { self.lastChecked = Date() }
            if let r = release, UpdateLogic.isNewer(r.tag, than: currentVersion) {
                await set(.available(version: UpdateLogic.cleanVersion(r.tag), notes: r.notes))
            } else {
                await set(.upToDate)
            }
        } catch {
            await set(silent ? before : .failed(Self.message(error)))
        }
    }

    /// Latest release, or nil when the repo has none. Cached for ten minutes: GitHub rate-limits callers without a login.
    func fetchLatest(force: Bool) async throws -> UpdateRelease? {
        if !force, let c = cache, Date().timeIntervalSince(c.at) < Self.cacheTTL { return c.release }
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GazeHop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw UpdateError.network(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { cache = (Date(), nil); return nil }
        guard (200..<300).contains(status), let release = UpdateLogic.parseRelease(data) else {
            // Rate-limited (60 calls/hour per address) or anything else: the release page's redirect isn't counted.
            return try await viaReleasePage(why: "GitHub answered \(status)")
        }
        cache = (Date(), release)
        return release
    }

    private func viaReleasePage(why: String) async throws -> UpdateRelease? {
        var req = URLRequest(url: URL(string: "\(webBase)/\(Self.repo)/releases/latest")!, timeoutInterval: 10)
        req.setValue("GazeHop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await session.data(for: req, delegate: NoRedirect()),
              let http = resp as? HTTPURLResponse,
              let tag = UpdateLogic.tag(fromReleaseRedirect: http.value(forHTTPHeaderField: "Location"))
        else { throw UpdateError.network(why) }
        let version = UpdateLogic.cleanVersion(tag)
        let name = "GazeHop-\(version).dmg"
        let release = UpdateRelease(
            tag: tag, notes: "", page: "\(webBase)/\(Self.repo)/releases/tag/\(tag)",
            asset: UpdateAsset(name: name, url: "\(webBase)/\(Self.repo)/releases/download/\(tag)/\(name)", size: 0))
        cache = (Date(), release)
        return release
    }

    // MARK: Install

    private func install(release: UpdateRelease, asset: UpdateAsset) async throws {
        let target = URL(fileURLWithPath: Self.installPath)
        guard Bundle.main.bundleURL.standardizedFileURL.path == target.path else {
            throw UpdateError.msg("GazeHop is running from \(Bundle.main.bundleURL.path), not \(Self.installPath). Move it to Applications to update in place.")
        }
        guard let url = URL(string: asset.url), UpdateLogic.isAllowedDownloadURL(url) else {
            throw UpdateError.msg("The download isn't hosted on GitHub, so it was refused.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("gazehop-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        await set(.downloading(progress: 0))
        let dmg = work.appendingPathComponent((asset.name as NSString).lastPathComponent)
        try await Downloader(progress: { [weak self] p in Task { await self?.set(.downloading(progress: p)) } })
            .download(url, to: dmg, expectedSize: asset.size)

        await set(.installing)
        let mount = try Self.attach(dmg)
        var detached = false
        func detach() { if !detached { detached = true; Self.detach(mount) } }
        defer { detach() }

        let mountedApp = mount.appendingPathComponent("GazeHop.app")
        guard fm.fileExists(atPath: mountedApp.path) else { throw UpdateError.msg("The disk image doesn't contain GazeHop.app.") }

        // Copy off the image first and verify the copy, so what we check is what we install.
        let stageDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: stageDir) }
        let staged = stageDir.appendingPathComponent("GazeHop.app")
        try Self.run("/usr/bin/ditto", ["--norsrc", "--noextattr", mountedApp.path, staged.path])
        try CodeIdentity.verifyUpdate(staged, against: Bundle.main.bundleURL)

        let tag = UpdateLogic.cleanVersion(release.tag)
        let stagedVersion = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard stagedVersion == tag else {
            throw UpdateError.msg("The downloaded app is version \(stagedVersion ?? "unknown"), not \(tag).")
        }

        _ = try fm.replaceItemAt(target, withItemAt: staged)
        detach()
        Self.relaunch(target)
    }

    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec /usr/bin/open -g \"$1\"", "sh", app.path]
        try? p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func attach(_ dmg: URL) throws -> URL {
        let out = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mp = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateError.msg("Couldn't open the disk image.") }
        return URL(fileURLWithPath: mp)
    }

    private static func detach(_ mount: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path])
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.msg("\((tool as NSString).lastPathComponent) failed: \(msg)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? UpdateError {
            switch e {
            case .network(let m): return "Couldn't reach GitHub (\(m))"
            case .msg(let m): return m
            }
        }
        return error.localizedDescription
    }
}

enum UpdateError: Error { case network(String), msg(String) }

// MARK: - Pure logic (unit tested)

struct UpdateAsset: Equatable { let name: String; let url: String; let size: Int }
struct UpdateRelease: Equatable {
    let tag: String; let notes: String; let page: String; let asset: UpdateAsset?
}

enum UpdateLogic {
    /// "v1.10.0" is newer than "1.9.2"; a pre-release ("1.0.0-beta.1") sorts below its release; build metadata is ignored.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.nums.count, b.nums.count) {
            let x = i < a.nums.count ? a.nums[i] : 0, y = i < b.nums.count ? b.nums[i] : 0
            if x != y { return x > y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil), (_?, nil): return false
        case (nil, _?): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedDescending
        }
    }

    static func cleanVersion(_ tag: String) -> String {
        var v = tag.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("v") { v.removeFirst() }
        return v
    }

    private static func parts(_ v: String) -> (nums: [Int], pre: String?) {
        let noBuild = cleanVersion(v).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let halves = noBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = (halves.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (nums, halves.count > 1 ? halves[1] : nil)
    }

    /// The disk image to download: the one named GazeHop-*.dmg, else any .dmg; never a checksum.
    static func pickAsset(_ assets: [UpdateAsset]) -> UpdateAsset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        return dmgs.first { $0.name.hasPrefix("GazeHop") } ?? dmgs.first
    }

    /// Releases and their files live on github.com and *.githubusercontent.com, over https, nowhere else.
    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable { let name: String?; let browser_download_url: String?; let size: Int? }
        let tag_name: String?; let body: String?; let html_url: String?
        let draft: Bool?; let prerelease: Bool?; let assets: [Asset]?
    }

    static func parseRelease(_ data: Data) -> UpdateRelease? {
        guard let r = try? JSONDecoder().decode(APIRelease.self, from: data), let tag = r.tag_name, !tag.isEmpty,
              r.draft != true else { return nil }
        let assets = (r.assets ?? []).compactMap { a -> UpdateAsset? in
            guard let n = a.name, let u = a.browser_download_url else { return nil }
            return UpdateAsset(name: n, url: u, size: a.size ?? 0)
        }
        return UpdateRelease(tag: tag, notes: String((r.body ?? "").prefix(4000)), page: r.html_url ?? "", asset: pickAsset(assets))
    }

    /// `/owner/repo/releases/tag/v1.2.3` → "v1.2.3"
    static func tag(fromReleaseRedirect location: String?) -> String? {
        guard let location, let range = location.range(of: "/releases/tag/") else { return nil }
        let tag = location[range.upperBound...].split(whereSeparator: { "/?#".contains($0) }).first.map(String.init)
        return tag?.removingPercentEncoding
    }
}

// MARK: - Networking helpers

/// Answers every redirect with "don't follow", so the caller can read the Location header.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Downloads a file, following at most 5 redirects and only to GitHub hosts.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double) -> Void
    private var hops = 0
    private var dest: URL!
    private var expected = 0
    private var cont: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func download(_ url: URL, to dest: URL, expectedSize: Int) async throws {
        self.dest = dest; self.expected = expectedSize
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.setValue("GazeHop", forHTTPHeaderField: "User-Agent")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cont = c
            session.downloadTask(with: req).resume()
        }
    }

    private func finish(_ error: Error?) {
        guard let c = cont else { return }
        cont = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        hops += 1
        guard hops <= 5, let url = request.url, UpdateLogic.isAllowedDownloadURL(url) else {
            failure = UpdateError.msg("The download pointed somewhere other than GitHub, so it was stopped.")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : expected
        if total > 0 { progress(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            failure = UpdateError.msg("GitHub answered \(status) for the download.")
            return
        }
        do { try FileManager.default.moveItem(at: location, to: dest) } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(failure ?? error)
    }
}

// MARK: - Code identity

enum CodeIdentity {
    struct Info: Equatable {
        let identifier: String?
        let teamID: String?
        let leafCertHash: Data?     // SHA-256 of the leaf signing certificate (nil when ad-hoc)
    }

    static func info(of url: URL) throws -> Info {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.msg("Couldn't read the code signature of \(url.lastPathComponent).")
        }
        var cf: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &cf) == errSecSuccess,
              let dict = cf as? [String: Any] else { throw UpdateError.msg("Couldn't read the code signature.") }
        let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let leaf = certs?.first.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)) }
        return Info(identifier: dict[kSecCodeInfoIdentifier as String] as? String,
                    teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String,
                    leafCertHash: leaf)
    }

    /// Valid signature (strict, nested, all architectures), same bundle id, and the same signer as the running app.
    static func verifyUpdate(_ new: URL, against running: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(new as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.msg("Couldn't read the new app's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        var err: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, nil, &err) == errSecSuccess else {
            throw UpdateError.msg("The downloaded app's signature is invalid, so it was not installed.")
        }
        try check(new: try info(of: new), running: try info(of: running))
    }

    static func check(new: Info, running: Info) throws {
        guard new.identifier == running.identifier, running.identifier != nil else {
            throw UpdateError.msg("The downloaded app has a different bundle id, so it was not installed.")
        }
        if let t = running.teamID {
            guard new.teamID == t else { throw UpdateError.msg("The downloaded app is signed by a different team, so it was not installed.") }
        } else {
            // Self-signed builds have no Team ID: require the very same signing certificate. Ad-hoc can't be verified.
            guard let leaf = running.leafCertHash, new.leafCertHash == leaf else {
                throw UpdateError.msg("The downloaded app isn't signed by the same certificate as this one, so it was not installed.")
            }
        }
    }
}
