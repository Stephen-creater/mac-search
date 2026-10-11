import XCTest
import Foundation
import Darwin
import CoreServices
import CMacSearch
@testable import MacSearchCore

final class M6Tests: XCTestCase {
    private func excluded(_ path: String, _ config: IndexConfig) -> Bool {
        Array(path.utf8).withUnsafeBufferPointer { config.isExcluded(path: $0) }
    }
    private func scan(_ config: IndexConfig) throws -> IndexStore {
        IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
    }
    private func paths(_ store: IndexStore) -> Set<String> {
        store.read { Set((0..<store.count).filter { store.isLive(UInt32($0)) }.map { store.path(UInt32($0)) }) }
    }
    private func withTree(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/MacSearchM6Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    func testT53ScopeRulesFingerprintsAndPreferences() throws {
        let home = NSHomeDirectory(), base = IndexConfig.standard()
        let switches: [WritableKeyPath<IndexConfig, Bool>] = [\.indexDependencyDirs, \.indexPackageContents, \.indexUserLibrary, \.indexSystemDirs]
        let omitted = ["\(home)/Desktop/project/node_modules/a.js", "\(home)/Desktop/Demo.app/Contents/a.txt", "\(home)/Library/Application Support/a.txt", "/System/Library/a.txt"]
        for (key, path) in zip(switches, omitted) {
            XCTAssertFalse(base[keyPath: key]); XCTAssertTrue(excluded(path, base), path)
            var enabled = base; enabled[keyPath: key] = true
            XCTAssertNotEqual(base.fingerprint, enabled.fingerprint)
            XCTAssertFalse(excluded(path, enabled), path)
        }
        for name in IndexConfig.dependencyNames {
            XCTAssertTrue(excluded("\(home)/Desktop/a/\(name)", base))
            var full = base; full.indexDependencyDirs = true
            XCTAssertFalse(excluded("\(home)/Desktop/a/\(name)/b", full))
        }
        for path in ["/System", "/System/Applications", "/System/Applications/Demo.app", "\(home)/Library", "\(home)/Library/Mobile Documents/a.txt", "\(home)/Library/CloudStorage/a.txt", "\(home)/Desktop/Demo.app", "\(home)/Desktop/Demo.APP", "\(home)/Desktop/Album.photoslibrary"] {
            XCTAssertFalse(excluded(path, base), path)
        }
        for path in ["/Library", "/usr", "/bin", "/sbin", "/private", "/opt", "/System/Applications-old/a", "\(home)/Library/Mobile Documents-old/a", "\(home)/Desktop/Demo.APP/a", "\(home)/Desktop/Album.photoslibrary/a"] {
            XCTAssertTrue(excluded(path, base), path)
        }
        let limited = IndexConfig.standard(limited: true)
        XCTAssertTrue(excluded("\(home)/Library/Mobile Documents/a", limited))
        XCTAssertTrue(excluded("\(home)/Library/CloudStorage/a", limited))
        let suite = "MacSearchM6-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsPreferences.register(in: defaults)
        for name in ["indexDependencyDirs", "indexPackageContents", "indexUserLibrary", "indexSystemDirs"] {
            XCTAssertFalse(defaults.bool(forKey: name)); defaults.set(true, forKey: name)
        }
        let loaded = SettingsPreferences.indexConfig(limited: false, in: defaults)
        XCTAssertTrue(switches.allSatisfy { loaded[keyPath: $0] })
    }
    func testT53DependencyAndPackageScansAndEvents() throws {
        try withTree { root in
            let fm = FileManager.default
            for dir in ["plain", "node_modules/deep", "Demo.APP/Contents", "Album.photoslibrary/data"] {
                try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
                try Data([65]).write(to: root.appendingPathComponent(dir + "/leaf.txt"))
            }
            var config = IndexConfig.standard(); config.rootPath = root.path
            let initial = try scan(config); initial.write { initial.buildHash() }
            let actual = paths(initial)
            XCTAssertTrue(actual.contains(root.path + "/Demo.APP")); XCTAssertTrue(actual.contains(root.path + "/Album.photoslibrary"))
            XCTAssertFalse(actual.contains { $0.contains("/node_modules") || $0.contains("/Contents") || $0.contains("/data") })
            let denied = ["node_modules/deep/new.txt", "Demo.APP/Contents/new.txt", "Album.photoslibrary/data/new.txt"]
            for file in denied { try Data([65]).write(to: root.appendingPathComponent(file)) }
            let summary = IndexUpdater(config: config).apply(denied.map { FSChange(path: root.path + "/" + $0) }, to: initial)
            XCTAssertEqual(summary.inserted, 0); XCTAssertEqual(summary.updated, 0); XCTAssertEqual(summary.scannedDirs, 0)
            XCTAssertEqual(paths(initial), actual)
            for key in [\IndexConfig.indexDependencyDirs, \IndexConfig.indexPackageContents] {
                var enabled = config; enabled[keyPath: key] = true
                let full = try scan(enabled)
                if key == \IndexConfig.indexDependencyDirs { XCTAssertTrue(paths(full).contains(root.path + "/node_modules/deep/leaf.txt")) }
                else { XCTAssertTrue(paths(full).contains(root.path + "/Demo.APP/Contents/leaf.txt")); XCTAssertTrue(paths(full).contains(root.path + "/Album.photoslibrary/data/leaf.txt")) }
            }
            // A newly inserted package is retained, but its subtree must stay omitted.
            try fm.createDirectory(at: root.appendingPathComponent("New.app/Contents"), withIntermediateDirectories: true)
            try Data([65]).write(to: root.appendingPathComponent("New.app/Contents/new.txt"))
            _ = IndexUpdater(config: config).apply([FSChange(path: root.path + "/New.app")], to: initial)
            XCTAssertTrue(paths(initial).contains(root.path + "/New.app"))
            XCTAssertFalse(paths(initial).contains(root.path + "/New.app/Contents/new.txt"))
        }
    }
    func testT53LibraryAndSystemScansAndEvents() throws {
        try skipIfCI("This test scans host system directories and depends on local permissions.")
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/MacSearchM6Tests-\(UUID().uuidString)")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: library) }
        let leaf = library.appendingPathComponent("leaf.txt")
        try Data([65]).write(to: leaf)
        var config = IndexConfig.standard(); config.rootPath = library.path
        let omitted = try scan(config); omitted.write { omitted.buildHash() }
        XCTAssertEqual(omitted.count, 1)
        XCTAssertEqual(IndexUpdater(config: config).apply([FSChange(path: leaf.path)], to: omitted).inserted, 0)
        config.indexUserLibrary = true
        let included = try scan(config); included.write { included.buildHash() }
        XCTAssertNotNil(included.resolve(path: leaf.path))
        let added = library.appendingPathComponent("added.txt"); try Data([65]).write(to: added)
        XCTAssertEqual(IndexUpdater(config: config).apply([FSChange(path: added.path)], to: included).inserted, 1)
        var system = IndexConfig.standard(); system.rootPath = "/usr/bin"
        XCTAssertEqual(try scan(system).count, 1)
        let blocked = try scan(system); blocked.write { blocked.buildHash() }
        XCTAssertEqual(IndexUpdater(config: system).apply([FSChange(path: "/usr/bin/ls")], to: blocked).updated, 0)
        system.indexSystemDirs = true
        let binaries = try scan(system)
        XCTAssertTrue(paths(binaries).contains("/usr/bin/true"))
        var apps = IndexConfig.standard(); apps.rootPath = "/System/Applications"
        let applications = try scan(apps)
        XCTAssertTrue(Searcher.search(Query.parse("kind:app"), in: applications)!.total > 0)
    }
    func testT54DescendantMasksAgainstWalking() throws {
        var seed: UInt64 = 0x4d36
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        let count = 600, store = IndexStore(rootPath: "/", count: count, namesLen: (count - 1) * 8, altCount: 0, altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0)
        let names = ["src", "xsrc", "docs", "Library", "System", "项目", "Desktop"]
        store.nameOff[0] = 0; store.parent[0] = 0; store.flags[0] = SiftFlag.dir; store.kind[0] = 1; store.depth[0] = 0; store.mtime[0] = 0; store.sizeC[0] = 0; store.altOff[0] = 0
        var dirs = [0], length = 0
        for i in 1..<count {
            let name = Array(names[next(names.count)].utf8), p = dirs[next(dirs.count)]
            store.nameOff[i] = UInt32(length)
            name.withUnsafeBufferPointer { store.names.advanced(by: length).update(from: $0.baseAddress!, count: name.count) }
            length += name.count; store.parent[i] = UInt32(p); store.depth[i] = UInt8(min(255, Int(store.depth[p]) + 1)); store.mtime[i] = 0; store.sizeC[i] = 0
            let isDir = next(3) != 0; store.flags[i] = isDir ? SiftFlag.dir : 0; store.kind[i] = isDir ? 1 : 0
            if isDir { dirs.append(i) }
        }
        store.namesLen = length; store.nameOff[count] = UInt32(length)
        for trial in 0..<200 {
            var components: [[UInt8]] = []
            for _ in 0..<next(5) + 1 { components.append(next(4) == 0 ? [] : Array(names[next(names.count)].lowercased().utf8)) }
            components.append([])
            let query = Query(clauses: [Clause(alternatives: [Atom(negated: false, matcher: .path(components: components))])], raw: "random-\(trial)")
            let result = try XCTUnwrap(Searcher.search(query, in: store))
            let expected = Set((1..<count).filter { Searcher.pathMatchesByWalking(components, id: UInt32($0), in: store) }.map(UInt32.init))
            XCTAssertEqual(Set(result.items), expected, "\(components)")
            let inverse = Query(clauses: [Clause(alternatives: [Atom(negated: true, matcher: .path(components: components))])], raw: "inverse")
            XCTAssertEqual(Set(Searcher.search(inverse, in: store)!.items), Set((1..<count).map(UInt32.init)).subtracting(expected))
        }
    }
    func testT55ExtensionKindsPreserveDirectoryUnknownAndNegation() throws {
        try withTree { root in
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("folder.PNG"), withIntermediateDirectories: true)
            for name in ["photo.PNG", "code.swift", "plain.xyz", "alias.png"] { try Data([65]).write(to: root.appendingPathComponent(name)) }
            var config = IndexConfig.standard(); config.rootPath = root.path
            let store = try scan(config)
            for query in ["ext:png", "ext:png;xyz", "!ext:png", "ext:swift;png", "ext:xyz"] {
                guard case .ext(let keys) = Query.parse(query).clauses[0].alternatives[0].matcher else { return XCTFail() }
                let negate = query.hasPrefix("!")
                let expected = Set((1..<store.count).filter { i in let hit = keys.contains(Classifier.extensionKey(store.nameBytes(UInt32(i)))); return negate ? !hit : hit }.map(UInt32.init))
                XCTAssertEqual(Set(Searcher.search(Query.parse(query), in: store)!.items), expected, query)
            }
        }
    }
    func testT56HashCapacityRebuildAndSearchWithoutHash() throws {
        try withTree { root in
            for i in 0..<900 { try Data().write(to: root.appendingPathComponent("item-\(i).txt")) }
            var config = IndexConfig.standard(); config.rootPath = root.path
            let store = try scan(config)
            XCTAssertFalse(store.hashReady)
            XCTAssertEqual(Searcher.search(Query.parse("ext:txt"), in: store)!.total, 900)
            store.write { store.buildHash() }
            XCTAssertTrue(store.hashReady); XCTAssertEqual(store.tableCapacity, max(1024, store.count * 5 / 4))
            store.write {
                for i in 900..<2000 {
                    Array("item-\(i).txt".utf8).withUnsafeBufferPointer { _ = store.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
                }
                XCTAssertLessThanOrEqual(store.tableUsed * 100, store.tableCapacity * 85)
                for i in 0..<2000 { XCTAssertNotNil(store.resolve(path: root.path + "/item-\(i).txt")) }
            }
        }
    }
    func testT57LoadedStoreSearchesBeforeHashBuild() throws {
        try skipIfCI("Loaded-index scheduling depends on host timing.")
        try withTree { root in
            try Data([65]).write(to: root.appendingPathComponent("readme.txt"))
            var config = IndexConfig.standard(); config.rootPath = root.path
            let db = root.appendingPathComponent("index.macsearch")
            let first = IndexManager(config: config, dbURL: db)
            first.start()
            func eventually(_ body: () -> Bool) -> Bool {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    if body() { return true }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
                } while Date() < deadline
                return body()
            }
            XCTAssertTrue(eventually { first.state == .ready }); first.stop()
            let blocked = DispatchSemaphore(value: 0), started = expectation(description: "loaded hash build queued")
            let second = IndexManager(config: config, dbURL: db)
            second.onBeforeLoadedHashBuild = { started.fulfill(); _ = blocked.wait(timeout: .now() + 5) }
            second.start()
            wait(for: [started], timeout: 5)
            let loaded = try XCTUnwrap(second.store)
            XCTAssertEqual(second.state, .ready)
            XCTAssertFalse(loaded.read { loaded.hashReady })
            XCTAssertEqual(Searcher.search(Query.parse("readme"), in: loaded)?.total, 1)
            blocked.signal()
            XCTAssertTrue(eventually { loaded.read { loaded.hashReady } })
            second.stop()
        }
    }

    func testT53FileWithDependencyNameAndPackageRoot() throws {
        try withTree { root in
            let file = root.appendingPathComponent("node_modules")
            try Data([65]).write(to: file)
            var config = IndexConfig.standard(); config.rootPath = root.path
            let store = try scan(config); store.write { store.buildHash() }
            XCTAssertNotNil(store.resolve(path: file.path))
            try FileManager.default.removeItem(at: file)
            _ = IndexUpdater(config: config).apply([FSChange(path: file.path)], to: store)
            XCTAssertNil(store.resolve(path: file.path))
            try Data([65]).write(to: file)
            _ = IndexUpdater(config: config).apply([FSChange(path: file.path)], to: store)
            XCTAssertNotNil(store.resolve(path: file.path))
            let package = root.appendingPathComponent("Root.app")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data([65]).write(to: package.appendingPathComponent("direct.txt"))
            config.rootPath = package.path
            let omitted = try scan(config); omitted.write { omitted.buildHash() }
            XCTAssertEqual(omitted.count, 1)
            _ = IndexUpdater(config: config).apply([FSChange(path: package.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))], to: omitted)
            XCTAssertEqual(omitted.liveCount, 1)
            config.indexPackageContents = true
            XCTAssertTrue(paths(try scan(config)).contains(package.path + "/direct.txt"))
        }
    }
    func testT58FirmlinkBulkIdentityMatchesOpenedDirectory() throws {
        try skipIfCI("This test checks host filesystem firmlinks.")
        let fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 262144, alignment: 8)
        let entries = UnsafeMutablePointer<macsearch_dirent>.allocate(capacity: 8192)
        defer { scratch.deallocate(); entries.deallocate() }
        var found = false
        while true {
            let count = sift_read_dir(fd, scratch, 262144, entries, 8192)
            if count <= 0 { break }
            for i in 0..<Int(count) where String(cString: entries[i].name) == "Users" {
                var expected = stat(); XCTAssertEqual(lstat("/Users", &expected), 0)
                XCTAssertEqual(entries[i].fileid, UInt64(expected.st_ino))
                XCTAssertEqual(entries[i].dev, expected.st_dev); found = true
            }
        }
        XCTAssertTrue(found)
    }

}
