import XCTest
import Foundation
import Darwin
import CoreServices
@testable import MacSearchCore

final class M2Tests: XCTestCase {
    private final class Fixture {
        let base: URL, root: URL, db: URL
        var config: IndexConfig
        init() throws {
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("MacSearchM2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let resolved = try XCTUnwrap(realpath(raw.path, nil)); defer { free(resolved) }
            base = URL(fileURLWithPath: String(cString: resolved)); root = base.appendingPathComponent("tree"); db = base.appendingPathComponent("index.macsearch")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            config = IndexConfig(rootPath: root.path, indexDependencyDirs: true, indexPackageContents: true, indexSystemDirs: true)
            for d in ["src/deep", "docs", "Demo.app/Contents", "项目", "empty"] { try mkdir(d) }
            for name in ["src/deep/leaf.txt", "src/a.swift", "docs/readme.md", "Demo.app/Contents/a.txt", "项目/项目文档.md", "cafe\u{301}.txt"] { try file(name) }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("docs"))
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func mkdir(_ relative: String) throws { try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true) }
        func file(_ relative: String, _ content: String = "sample") throws { try Data(content.utf8).write(to: root.appendingPathComponent(relative)) }
        func remove(_ relative: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(relative)) }
        func move(_ a: String, _ b: String) throws { try FileManager.default.moveItem(at: root.appendingPathComponent(a), to: root.appendingPathComponent(b)) }
        func scan() throws -> IndexStore {
            let s = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
            s.write { s.buildHash() }; return s
        }
        func changes(_ relatives: [String], flags: UInt32 = 0, id: UInt64 = 1) -> [FSChange] {
            relatives.map { FSChange(path: $0.isEmpty ? root.path : root.path + "/" + $0, flags: flags, eventId: id) }
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
    private func invariants(_ s: IndexStore, file: StaticString = #filePath, line: UInt = #line) {
        s.read {
            XCTAssertEqual(s.name(0), "", file: file, line: line); XCTAssertEqual(s.parent[0], 0, file: file, line: line)
            XCTAssertEqual(s.nameOff[s.count], UInt32(s.namesLen), file: file, line: line)
            XCTAssertEqual(s.altOff[s.altCount], UInt32(s.altLen), file: file, line: line)
            XCTAssertEqual(s.liveCount + Int(s.deletedCount), s.count, file: file, line: line)
            for i in 1..<s.count {
                XCTAssertLessThan(s.parent[i], UInt32(i), file: file, line: line)
                XCTAssertLessThanOrEqual(s.nameOff[i], s.nameOff[i+1], file: file, line: line)
                XCTAssertEqual(s.name(UInt32(i)), s.name(UInt32(i)).precomposedStringWithCanonicalMapping, file: file, line: line)
                if s.isLive(UInt32(i)) { XCTAssertEqual(s.resolve(path: s.path(UInt32(i))), UInt32(i), file: file, line: line) }
            }
            for a in 0..<s.altCount {
                XCTAssertLessThan(s.altOwner[a], UInt32(s.count), file: file, line: line)
                if a > 0 { XCTAssertLessThanOrEqual(s.altOwner[a-1], s.altOwner[a], file: file, line: line) }
            }
        }
    }
    @discardableResult private func eventually(_ seconds: Double = 5, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return predicate()
    }
    private func equalToScan(_ s: IndexStore, _ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(contents(s), contents(try f.scan()), file: file, line: line); invariants(s, file: file, line: line)
    }
    func testT20HashAndResolve() throws {
        let f = try Fixture(), s = try f.scan()
        s.read {
            for i in 1..<s.count {
                XCTAssertEqual(s.lookup(parent: s.parent[i], name: s.nameBytes(UInt32(i))), UInt32(i))
                let upper = s.nameBytes(UInt32(i)).map { $0 >= 97 && $0 <= 122 ? $0 - 32 : $0 }
                upper.withUnsafeBufferPointer { XCTAssertEqual(s.lookup(parent: s.parent[i], name: $0), UInt32(i)) }
            }
            XCTAssertNil(s.resolve(path: f.root.path + "-else/src")); XCTAssertNil(s.resolve(path: "relative"))
        }
        invariants(s)
    }
    func testT21MutationsAndSweep() throws {
        let f = try Fixture(), s = try f.scan()
        s.write {
            var dir: UInt32 = 0
            Array("new".utf8).withUnsafeBufferPointer { dir = s.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 1)) }
            for j in 0..<300 {
                Array("item-\(j).txt".utf8).withUnsafeBufferPointer { _ = s.insert(parent: dir, name: $0, attrs: EntryAttrs(type: 0, size: UInt64(j), mtime: -10)) }
            }
            Array("项目.md".utf8).withUnsafeBufferPointer { _ = s.insert(parent: dir, name: $0, attrs: EntryAttrs(type: 0)) }
            let id = s.resolve(path: f.root.path + "/new/item-0.txt")!
            Array("ITEM-0.txt".utf8).withUnsafeBufferPointer { XCTAssertEqual(s.update(id, name: $0, attrs: EntryAttrs(type: 0, size: 4096, mtime: Int64.max)), id) }
            XCTAssertEqual(s.name(id), "ITEM-0.txt"); XCTAssertEqual(s.mtime[Int(id)], UInt32.max)
            let replaced = Array("ITEM-0.txt".utf8).withUnsafeBufferPointer { s.update(id, name: $0, attrs: EntryAttrs(type: 1)) }
            XCTAssertGreaterThan(replaced, id); XCTAssertFalse(s.isLive(id))
            XCTAssertTrue(s.remove(dir)); s.sweep()
            XCTAssertNil(s.resolve(path: f.root.path + "/new/ITEM-0.txt"))
            let deleted = s.deletedCount; _ = s.remove(dir); s.sweep(); XCTAssertEqual(s.deletedCount, deleted)
        }
        invariants(s)
        XCTAssertNil(Searcher.search(Query.parse("item-"), in: s)?.items.first)
    }
    func testT22Compaction() throws {
        let f = try Fixture(), s = try f.scan()
        s.write {
            _ = s.remove(s.resolve(path: f.root.path + "/项目")!); s.sweep()
            s.lastEventId = 123; s.version = 9; s.fsEventsUUID = "test"; s.homeIndex = s.resolve(path: f.root.path + "/docs")!
        }
        let expected = contents(s), compact = s.write { s.compacted() }
        XCTAssertEqual(contents(compact), expected); invariants(compact)
        XCTAssertEqual(compact.deletedCount, 0); XCTAssertEqual(compact.lastEventId, 123); XCTAssertEqual(compact.version, 9)
        XCTAssertEqual(compact.scanFinishedAt, s.scanFinishedAt); XCTAssertEqual(compact.fsEventsUUID, "test")
        XCTAssertEqual(compact.path(compact.homeIndex), s.path(s.homeIndex))
        for a in 0..<compact.altCount { XCTAssertTrue(compact.isLive(compact.altOwner[a])) }
        let held = Searcher.search(Query.parse("readme"), in: s)!
        XCTAssertTrue(held.store === s); XCTAssertFalse(held.store === compact)
        try compact.save(to: f.db.path); XCTAssertEqual(contents(try XCTUnwrap(IndexStore.load(from: f.db.path))), expected)
    }
    private func operations(_ f: Fixture, check: ([String]) throws -> Void) throws {
        try f.file("new.txt"); try check(["new.txt", ""])
        try f.mkdir("fresh/a/b"); try f.file("fresh/a/b/leaf.txt"); try check(["fresh", ""])
        try f.remove("new.txt"); try check(["new.txt", ""])
        try f.remove("fresh"); try check(["fresh", ""])
        try f.move("docs/readme.md", "docs/renamed.md"); try check(["docs/readme.md", "docs/renamed.md", "docs"])
        try f.move("src/deep", "src/renamed"); try check(["src/deep", "src/renamed", "src"])
        try f.move("src/renamed", "docs/moved"); try check(["src/renamed", "docs/moved", "src", "docs"])
        try f.move("docs/renamed.md", "docs/RENAMED.md"); try check(["docs/renamed.md", "docs/RENAMED.md", "docs"])
        try f.file("docs/RENAMED.md", String(repeating: "x", count: 2048)); try check(["docs/RENAMED.md", "docs"])
    }
    func testT23DiskChangesMatchScan() throws {
        let f = try Fixture(), s = try f.scan(), updater = IndexUpdater(config: f.config)
        var id: UInt64 = 1
        try operations(f) { paths in
            _ = updater.apply(f.changes(paths, id: id), to: s); id += 1; try equalToScan(s, f)
        }
    }
    func testT24Idempotence() throws {
        let f = try Fixture(), s = try f.scan(), updater = IndexUpdater(config: f.config)
        try f.mkdir("fresh/a"); try f.file("fresh/a/项目.txt"); try f.remove("docs/readme.md")
        let changes = f.changes(["fresh/a/项目.txt", "docs/readme.md", "docs", ""], id: 345)
        _ = updater.apply(changes, to: s); let before = contents(s), count = s.count
        let twice = updater.apply(changes, to: s)
        XCTAssertEqual(contents(s), before); XCTAssertEqual(s.count, count); XCTAssertEqual(twice.inserted, 0); XCTAssertEqual(twice.removed, 0)
        XCTAssertEqual(s.lastEventId, 345); try equalToScan(s, f)
    }
    func testT25MissingAncestors() throws {
        let f = try Fixture(), s = try f.scan(), updater = IndexUpdater(config: f.config)
        try f.mkdir("fresh/a/b"); try f.file("fresh/a/b/leaf.txt"); try f.file("fresh/sibling.txt")
        let summary = updater.apply(f.changes(["fresh/a/b/leaf.txt"]), to: s)
        XCTAssertEqual(summary.scannedDirs, 1); try equalToScan(s, f)
    }
    func testT26Reconcile() throws {
        let f = try Fixture(), s = try f.scan(), updater = IndexUpdater(config: f.config)
        try f.remove("src/deep"); try f.file("src/new.txt"); try f.file("src/a.swift", "larger content")
        _ = updater.apply(f.changes(["src"], flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)), to: s)
        try equalToScan(s, f)
    }
    func testT27ExcludedEvents() throws {
        let f = try Fixture(); f.config.excludedPaths = [f.root.path + "/skip"]; f.config.excludedNames = ["ignored"]
        let s = try f.scan(), updater = IndexUpdater(config: f.config)
        try f.mkdir("skip/sub"); try f.file("skip/sub/secret.txt"); try f.mkdir("src/ignored"); try f.file("src/ignored/secret.txt")
        let before = contents(s)
        let result = updater.apply(f.changes(["skip/sub/secret.txt", "src/ignored/secret.txt", "skip/"]), to: s)
        XCTAssertEqual(result.inserted, 0); XCTAssertEqual(contents(s), before); XCTAssertEqual(s.lastEventId, 1)
        _ = updater.apply(f.changes(["src"], flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)), to: s)
        try equalToScan(s, f)
    }
    func testT28RealFSEvents() throws {
        try skipIfCI("Real FSEvents delivery is timing-sensitive in CI.")
        let f = try Fixture(), manager = IndexManager(config: f.config, dbURL: f.db)
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.state == .ready })
        try operations(f) { paths in
            let expected = contents(try f.scan())
            let matched = eventually { manager.store.map { contents($0) == expected } ?? false }
            let actual = manager.store.map(contents) ?? [:]
            let diffs = Set(actual.keys).union(expected.keys).filter { actual[$0] != expected[$0] }.sorted().map { "\($0.dropFirst(f.root.path.count)): \(String(describing: actual[$0])) -> \(String(describing: expected[$0]))" }
            XCTAssertTrue(matched, "events \(paths): \(diffs)")
        }
        invariants(try XCTUnwrap(manager.store))
    }
    func testT29OfflineReplay() throws {
        try skipIfCI("Offline FSEvents replay depends on host event timing.")
        let f = try Fixture(), first = IndexManager(config: f.config, dbURL: f.db)
        first.start(); XCTAssertTrue(eventually { first.state == .ready }); first.stop()
        let offlineStart = FSWatcher.currentEventId()
        try f.file("offline.txt"); try f.move("src/deep", "docs/offline"); try f.remove("docs/readme.md")
        XCTAssertTrue(eventually(2) { FSWatcher.currentEventId() > offlineStart })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let second = IndexManager(config: f.config, dbURL: f.db); var states: [IndexManager.State] = []
        second.onStateChange = { states.append($0) }; second.start(); defer { second.stop() }
        let expected = contents(try f.scan())
        XCTAssertTrue(eventually { second.state == .ready && second.store.map { contents($0) == expected } ?? false })
        XCTAssertFalse(states.contains(.scanning)); XCTAssertGreaterThan(second.replayedEventCount, 0)
        print("T29 offline replayedEvents=\(second.replayedEventCount) dataPrefix=\(second.reportedDataPrefix)")
    }
    func testT30FingerprintInvalidation() throws {
        try skipIfCI("IndexManager rebuild timing is covered locally.")
        let f = try Fixture(), first = IndexManager(config: f.config, dbURL: f.db)
        first.start(); XCTAssertTrue(eventually { first.state == .ready }); first.stop()
        f.config.userExcludedPaths = [f.root.path + "/src"]
        let second = IndexManager(config: f.config, dbURL: f.db); var states: [IndexManager.State] = []
        second.onStateChange = { states.append($0) }; second.start(); defer { second.stop() }
        XCTAssertTrue(eventually { second.state == .ready }); XCTAssertTrue(states.contains(.scanning))
        try equalToScan(try XCTUnwrap(second.store), f)
        XCTAssertEqual(second.store?.configFingerprint, f.config.fingerprint)
        let old = try XCTUnwrap(second.store)
        second.rescan(); second.rescan()
        XCTAssertTrue(eventually { !second.isRescanning && second.store !== old })
        XCTAssertEqual(states.filter { $0 == .scanning }.count, 1)
        try equalToScan(try XCTUnwrap(second.store), f)
        invariants(old)
    }
    func testT31ConcurrentSaveSearchAndApply() throws {
        try skipIfCI("Concurrent index stress timing is covered locally.")
        let f = try Fixture(), s = try f.scan(), updater = IndexUpdater(config: f.config)
        let group = DispatchGroup(), queue = DispatchQueue(label: "MacSearchM2Tests.concurrent", attributes: .concurrent)
        for kind in 0..<3 {
            group.enter(); queue.async {
                defer { group.leave() }
                for j in 0..<40 {
                    if kind == 0 { do { try s.save(to: f.db.path) } catch { XCTFail("save: \(error)") } }
                    else if kind == 1 { XCTAssertNotNil(Searcher.search(Query.parse("readme|项目"), in: s)) }
                    else {
                        do {
                            try f.file("concurrent.txt", String(repeating: "x", count: j))
                            _ = updater.apply(f.changes(["concurrent.txt"]), to: s)
                            // The sole writer builds a compact snapshot while save/search readers run.
                            if j % 5 == 0 {
                                let compact = s.read { s.compacted() }
                                XCTAssertEqual(self.contents(compact), self.contents(s))
                                XCTAssertNotNil(Searcher.search(Query.parse("readme|项目"), in: compact))
                            }
                        }
                        catch { XCTFail("mutation: \(error)") }
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now()+10), .success)
        invariants(s); try s.save(to: f.db.path)
        XCTAssertEqual(contents(try XCTUnwrap(IndexStore.load(from: f.db.path))), contents(s))
    }
}
