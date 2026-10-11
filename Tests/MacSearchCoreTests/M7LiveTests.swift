import XCTest
import Foundation
import Darwin
import CoreServices
@testable import MacSearchCore

final class M7LiveTests: XCTestCase {
    private final class Fixture {
        let base: URL, root: URL, db: URL, config: IndexConfig
        init() throws {
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("MacSearchM7Live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let resolved = try XCTUnwrap(realpath(raw.path, nil)); defer { free(resolved) }
            base = URL(fileURLWithPath: String(cString: resolved))
            root = base.appendingPathComponent("tree"); db = base.appendingPathComponent("index.macsearch")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            config = IndexConfig(rootPath: root.path, indexDependencyDirs: true, indexPackageContents: true, indexSystemDirs: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func mkdir(_ name: String) throws { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        func file(_ name: String) throws { try Data([65]).write(to: root.appendingPathComponent(name)) }
        func remove(_ name: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        func move(_ a: String, _ b: String) throws { try FileManager.default.moveItem(at: root.appendingPathComponent(a), to: root.appendingPathComponent(b)) }
        func scan() throws -> IndexStore {
            let s = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
            s.write { s.buildHash() }; return s
        }
        func events(_ names: [String], flags: UInt32 = 0, id: UInt64 = 1) -> [FSChange] {
            names.map { FSChange(path: $0.isEmpty ? root.path : root.path + "/" + $0, flags: flags, eventId: id) }
        }
    }
    private struct Attributes: Equatable {
        let size: UInt32, mtime: UInt32, flags: UInt8, depth: UInt8, kind: UInt8
    }
    private func contents(_ s: IndexStore) -> [String: Attributes] {
        s.read {
            var out: [String: Attributes] = [:]
            for i in 0..<s.count where s.isLive(UInt32(i)) {
                out[s.path(UInt32(i))] = Attributes(size: s.sizeC[i], mtime: s.mtime[i], flags: s.flags[i], depth: s.depth[i], kind: s.kind[i])
            }
            return out
        }
    }
    @discardableResult private func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return predicate()
    }
    func testT73RootRescanSkipsApply() throws {
        try skipIfCI("Live rescan scheduling is timing-sensitive in CI.")
        let f = try Fixture(); try f.mkdir("dir"); try f.file("dir/leaf.txt")
        let manager = IndexManager(config: f.config, dbURL: f.db)
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.state == .ready })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let original = try XCTUnwrap(manager.store)
        var applies = 0, replacements = 0
        manager.onApply = { _ in applies += 1 }
        manager.onIndexChange = { replacements += 1 }
        manager.injectEvents(f.events([""], flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)), mustRescanAll: true)
        XCTAssertTrue(eventually { manager.store !== original && !manager.isRescanning })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(applies, 0); XCTAssertEqual(replacements, 1)
        print("T73 apply=\(applies) rescan=\(replacements)")
    }
    func testT73LostEventsDuringRescanQueueRecovery() throws {
        try skipIfCI("Live rescan recovery scheduling is timing-sensitive in CI.")
        let f = try Fixture(); try f.file("leaf.txt")
        let manager = IndexManager(config: f.config, dbURL: f.db)
        let countLock = NSLock()
        var starts = 0, applies = 0
        manager.onRescanStart = { [weak manager] in
            countLock.lock(); starts += 1; let current = starts; countLock.unlock()
            if current == 1 { manager?.injectEvents(f.events([""], flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)), mustRescanAll: true) }
        }
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.state == .ready })
        // Drain startup replay before observing the explicitly injected loss.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        manager.onApply = { _ in applies += 1 }
        manager.rescan()
        XCTAssertTrue(eventually {
            countLock.lock(); let count = starts; countLock.unlock()
            return count == 2 && !manager.isRescanning
        })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(applies, 0)
        XCTAssertEqual(contents(try XCTUnwrap(manager.store)), contents(try f.scan()))
        print("T73 loss during rescan: recovery scans=2 apply=0")
    }
    func testT74Phase2InvalidatesCacheAndNarrowing() throws {
        let f = try Fixture(); try f.file("leaf-old.txt")
        let s = try f.scan(), updater = IndexUpdater(config: f.config), options = SearchOptions()
        let previous = try XCTUnwrap(Searcher.search(Query.parse("leaf"), options: options, in: s))
        let cache = SearchCache(); cache.insert(previous)
        try f.remove("leaf-old.txt"); try f.mkdir("fresh/deep"); try f.file("fresh/deep/leaf-new.txt")
        var phase3Visited = false
        updater.onPhase3 = {
            phase3Visited = true
            XCTAssertGreaterThan(s.read { s.version }, previous.storeVersion)
            XCTAssertEqual(s.read { s.lastEventId }, 0)
            XCTAssertNil(cache.lookup(query: Query.parse("leaf"), options: options, store: s))
            let q = Query.parse("leaf ext:txt")
            let narrow = Searcher.search(q, options: options, in: s, previous: previous)
            let full = Searcher.search(q, options: options, in: s)
            XCTAssertEqual(narrow?.items, full?.items); XCTAssertEqual(narrow?.scores, full?.scores)
            XCTAssertFalse(narrow?.isNarrowed ?? true); XCTAssertEqual(full?.total, 0)
        }
        _ = updater.apply(f.events(["leaf-old.txt", "fresh"], id: 42), to: s)
        XCTAssertTrue(phase3Visited); XCTAssertEqual(s.lastEventId, 42)
        XCTAssertEqual(contents(s), contents(try f.scan()))
        print("T74 phase3 version advanced; cache miss; narrow/full equal")
    }
    func testT75InheritedFlagsMatchFullScan() throws {
        let f = try Fixture(); try f.mkdir("Caches/deep"); try f.file("Caches/deep/leaf.txt")
        let s = try f.scan(), updater = IndexUpdater(config: f.config)
        func check(_ names: [String]) throws {
            _ = updater.apply(f.events(names), to: s)
            XCTAssertEqual(contents(s), contents(try f.scan()))
        }
        let path = f.root.path + "/Caches"
        XCTAssertEqual(chflags(path, UInt32(UF_HIDDEN)), 0); try check(["Caches"])
        XCTAssertEqual(chflags(path, 0), 0); try check(["Caches"])
        try f.move("Caches", "data"); try check(["Caches", "data"])
        try f.move("data", "node_modules"); try check(["data", "node_modules"])
        try f.move("node_modules", "plain"); try check(["node_modules", "plain"])
        try f.move("plain", "x.framework"); try check(["plain", "x.framework"])
        try f.move("x.framework", "plain"); try check(["x.framework", "plain"])
        // A case-only rename keeps the existing entry on an insensitive volume.
        try f.move("plain", "Caches"); try check(["plain", "Caches"])
        if !s.caseSensitiveNames {
            let before = s.resolve(path: f.root.path + "/Caches")
            try f.move("Caches", "CACHES"); try check(["Caches", "CACHES"])
            XCTAssertEqual(s.resolve(path: f.root.path + "/CACHES"), before)
        }
        print("T75 hidden/unhidden/noise/package/case-only flags match full scan")
    }
    func testT79ManyReconcileRootsUseTwoPasses() throws {
        let f = try Fixture()
        for i in 0..<100 { try f.mkdir("root-\(i)/deep"); try f.file("root-\(i)/deep/old.txt") }
        let s = try f.scan(), updater = IndexUpdater(config: f.config)
        for i in 0..<100 { try f.remove("root-\(i)/deep/old.txt"); try f.file("root-\(i)/new.txt") }
        var passes = 0; updater.onReconcilePass = { passes += 1 }
        let summary = updater.apply(f.events((0..<100).map { "root-\($0)" }, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)), to: s)
        XCTAssertEqual(summary.scannedDirs, 100); XCTAssertEqual(passes, 2)
        XCTAssertEqual(contents(s), contents(try f.scan()))
        print("T79 roots=100 full-index passes=\(passes) removed=\(summary.removed)")
    }
    func testT79MergeChunksReleaseWriteLock() throws {
        try skipIfCI("The 20,000-entry merge stress test is performance-sensitive in CI.")
        let f = try Fixture(), s = try f.scan(), updater = IndexUpdater(config: f.config)
        try f.mkdir("large")
        for i in 0..<20_001 { try f.file("large/item-\(i).txt") }
        var chunks = 0, previousCount = 0, previousVersion: UInt64 = 0
        updater.onPhase3 = {
            s.read { previousCount = s.count; previousVersion = s.version }
        }
        updater.onMergeChunk = {
            // A fresh read lock is acquired after each chunk's write lock is released.
            s.read {
                XCTAssertLessThanOrEqual(s.count - previousCount, 20_000)
                XCTAssertGreaterThan(s.version, previousVersion)
                previousCount = s.count; previousVersion = s.version
            }
            chunks += 1
        }
        _ = updater.apply(f.events(["large"]), to: s)
        XCTAssertEqual(chunks, 2)
        XCTAssertEqual(contents(s), contents(try f.scan()))
        print("T79 large subtree chunks=\(chunks), read lock available and version advanced at each boundary")
    }
    func testT80ManagerImmediateStop() throws {
        try skipIfCI("The shutdown latency assertion is timing-sensitive in CI.")
        let f = try Fixture(), manager = IndexManager(config: f.config, dbURL: f.db)
        let start = Date(); manager.start(); manager.stop()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2); XCTAssertEqual(manager.state, .idle)
        print("T80 immediate manager stop=\(elapsed)s")
    }
}
