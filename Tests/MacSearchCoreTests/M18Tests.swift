import XCTest
import CryptoKit
@testable import MacSearchCore

final class M18Tests: XCTestCase {
    private let current = UpdateVersion("1.2.0", build: 5)!
    private func manifest(version: String = "1.3.0", build: Int = 6, hash: String = String(repeating: "a", count: 64), size: Int64 = 3, minimum: String = "14.0") throws -> UpdateManifest {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": version, "build": build, "url": "https://updates.example.invalid/downloads/test.zip", "size": size, "sha256": hash,
            "minimumSystemVersion": minimum, "published": "2026-10-04", "notes": ["zh": ["官网新增更新日志。"], "en": ["A changelog is now on the website."]]
        ])
        return try UpdateManifest.parse(data)
    }
    func testSemanticVersionOrderingAndBuildFallback() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0"]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(SemanticVersion(lower)!, SemanticVersion(higher)!) }
        XCTAssertEqual(SemanticVersion("1.0.0+one"), SemanticVersion("1.0.0+two"))
        XCTAssertLessThan(UpdateVersion("1.2.0", build: 5)!, UpdateVersion("1.2.0", build: 6)!)
        XCTAssertLessThan(UpdateVersion("1.2.0", build: 100)!, UpdateVersion("1.3.0", build: 1)!)
        for invalid in ["1.2", "01.2.0", "1.2.0-01", "1.2.0-", "1.2.0+", "1.2.0+a+b", "v1.2.0", "1.2.0/evil"] { XCTAssertNil(SemanticVersion(invalid)) }
    }
    func testManifestValidationAndSystemEligibility() throws {
        let parsed = try manifest()
        XCTAssertEqual(parsed.version, "1.3.0")
        XCTAssertTrue(parsed.supports(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        XCTAssertFalse(parsed.supports(OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 9)))
        XCTAssertThrowsError(try manifest(hash: "not a hash"))
        XCTAssertThrowsError(try manifest(size: -1))
        XCTAssertThrowsError(try manifest(build: -1))
        XCTAssertThrowsError(try manifest(version: "bad"))
        XCTAssertThrowsError(try manifest(minimum: "14.beta"))
        XCTAssertThrowsError(try UpdateManifest.parse(Data("{}".utf8)))
        var local = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed)) as! [String: Any]
        local["url"] = "http://127.0.0.1:8123/test.zip"
        let data = try JSONSerialization.data(withJSONObject: local)
        XCTAssertThrowsError(try UpdateManifest.parse(data))
        XCTAssertNoThrow(try UpdateManifest.parse(data, allowLocalhost: true))
    }
    func testSkippedVersionPersistsButManualChecksStillOfferIt() throws {
        let suite = "M18-" + UUID().uuidString
        // Use an isolated domain and remove it even when assertions fail.
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let preferences = UpdatePreferences(defaults: isolated), update = try manifest()
        let system = OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
        XCTAssertTrue(preferences.automatic)
        preferences.automatic = false
        XCTAssertFalse(UpdatePreferences(defaults: isolated).automatic)
        preferences.skip(update)
        XCTAssertFalse(UpdatePreferences(defaults: isolated).shouldOffer(update, current: current, system: system, manual: false))
        XCTAssertTrue(preferences.shouldOffer(update, current: current, system: system, manual: true))
        XCTAssertTrue(preferences.shouldOffer(try manifest(version: "1.4.0"), current: current, system: system, manual: false))
        XCTAssertFalse(preferences.shouldOffer(try manifest(minimum: "15.0"), current: current, system: system, manual: true))
    }

    private final class Files: UpdateFileOperations {
        var paths: Set<String> = ["/test/Mac Search.app"]
        var writable = true, badHash = false, failReplacement = false, failReceipt = false
        var candidateVersion = UpdateVersion("1.3.0", build: 6)!
        var moves: [(String, String)] = []
        func isWritableApplication(_ app: URL) -> Bool { writable }
        func createWorkspace(beside app: URL) throws -> URL { URL(fileURLWithPath: "/test/.macsearch-update-test") }
        func verifyArchive(_ archive: URL, manifest: UpdateManifest) throws { if badHash { throw UpdateFailure.integrity } }
        func extractArchive(_ archive: URL, into workspace: URL) throws -> URL {
            let candidate = workspace.appendingPathComponent("unpacked/Mac Search.app"); paths.insert(candidate.path); return candidate
        }
        func version(of app: URL) throws -> UpdateVersion { candidateVersion }
        func move(_ source: URL, to destination: URL) throws {
            if failReplacement && source.path.contains("unpacked") { throw UpdateFailure.other }
            guard paths.remove(source.path) != nil, !paths.contains(destination.path) else { throw UpdateFailure.other }
            paths.insert(destination.path); moves.append((source.path, destination.path))
        }
        func remove(_ url: URL) throws { paths = paths.filter { !$0.hasPrefix(url.path) } }
        func writeReceipt(_ installation: UpdateInstallation, manifest: UpdateManifest) throws { if failReceipt { throw UpdateFailure.other } }
    }
    private final class Signature: UpdateSignatureValidating {
        var valid = true
        func validate(_ app: URL) throws { if !valid { throw UpdateFailure.signature } }
    }
    private func install(_ files: Files, _ signature: Signature = Signature()) throws -> UpdateInstallation {
        try UpdateInstaller(application: URL(fileURLWithPath: "/test/Mac Search.app"), current: current, files: files, signature: signature)
            .install(archive: URL(fileURLWithPath: "/test/update.zip"), manifest: manifest())
    }
    private func assertRejected(_ files: Files, _ signature: Signature = Signature(), failure: UpdateFailure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try install(files, signature), file: file, line: line) { XCTAssertEqual($0 as? UpdateFailure, failure, file: file, line: line) }
        XCTAssertEqual(files.paths, ["/test/Mac Search.app"], file: file, line: line)
    }
    func testHashMismatchKeepsOldApp() { let files = Files(); files.badHash = true; assertRejected(files, failure: .integrity) }
    func testSignatureRequirementMismatchKeepsOldApp() {
        let files = Files(), signature = Signature(); signature.valid = false; assertRejected(files, signature, failure: .signature)
    }
    func testCandidateMustBeNewerAndMatchManifest() {
        for version in [current, UpdateVersion("1.1.0", build: 99)!, UpdateVersion("1.4.0", build: 6)!] {
            let files = Files(); files.candidateVersion = version; assertRejected(files, failure: .other)
        }
    }
    func testUnwritableTargetDoesNotMoveAnything() {
        let files = Files(); files.writable = false; assertRejected(files, failure: .permission); XCTAssertTrue(files.moves.isEmpty)
    }
    func testFailureBetweenMovesImmediatelyRestoresBackup() {
        let files = Files(); files.failReplacement = true; assertRejected(files, failure: .other)
        XCTAssertEqual(files.moves.count, 2)
        XCTAssertEqual(files.moves.last?.0, "/test/.macsearch-update-test/previous.app")
    }
    func testReceiptFailureHappensBeforeReplacement() {
        let files = Files(); files.failReceipt = true; assertRejected(files, failure: .other); XCTAssertTrue(files.moves.isEmpty)
    }
    func testSuccessRetainsBackupAndRelaunchFailureCanRollback() throws {
        let files = Files(), installation = try install(files)
        XCTAssertTrue(files.paths.contains(installation.target.path)); XCTAssertTrue(files.paths.contains(installation.backup.path))
        try UpdateInstaller(application: installation.target, current: current, files: files, signature: Signature()).rollback(installation)
        XCTAssertEqual(files.paths, [installation.target.path])
    }
    func testActualArchiveSizeAndStreamingHashVerification() throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("m18-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        let data = Data("abc".utf8); try data.write(to: archive)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try SystemUpdateFiles().verifyArchive(archive, manifest: manifest(hash: hash)))
        XCTAssertThrowsError(try SystemUpdateFiles().verifyArchive(archive, manifest: manifest()))
        XCTAssertThrowsError(try SystemUpdateFiles().verifyArchive(archive, manifest: manifest(hash: hash, size: 4)))
    }
    func testStartupReceiptOnlyCleansMatchingConfirmedOrRestoredVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m18-launch-" + UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Mac Search.app", isDirectory: true), files = SystemUpdateFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "local.stephen.macsearch", "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "5"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let workspace = try files.createWorkspace(beside: app), installation = UpdateInstallation(target: app, workspace: workspace)
        try files.writeReceipt(installation, manifest: manifest())
        XCTAssertNil(files.cleanupAfterLaunch(application: app, current: current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        files.registerLaunch(application: app, current: UpdateVersion("1.3.0", build: 6)!)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("launch.pid")), String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNil(files.cleanupAfterLaunch(application: app, current: UpdateVersion("1.3.0", build: 6)!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("launch-confirmed").path))
        // A subsequent launch can retry cleanup independently of the successful startup.
        XCTAssertNil(files.cleanupAfterLaunch(application: app, current: UpdateVersion("1.3.0", build: 6)!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        let failed = try files.createWorkspace(beside: app)
        try files.writeReceipt(UpdateInstallation(target: app, workspace: failed), manifest: manifest())
        try Data().write(to: failed.appendingPathComponent("relaunch-failed"))
        XCTAssertEqual(files.cleanupAfterLaunch(application: app, current: current), .other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }
}
