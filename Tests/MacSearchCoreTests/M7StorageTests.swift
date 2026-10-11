import XCTest
import Foundation
@testable import MacSearchCore

final class M7StorageTests: XCTestCase {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacSearchM7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func packageFlags(_ name: String, type: UInt32 = 1) -> UInt8 {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { Classifier.flags(name: $0, type: type, bsdFlags: 0, inherited: 0) }
    }

    private func emptyStore(caseSensitive: Bool) -> IndexStore {
        let store = IndexStore(rootPath: "/", count: 1, namesLen: 0, altCount: 0, altLen: 0,
                               fingerprint: 0, homeIndex: .max, finishedAt: 0,
                               caseSensitiveNames: caseSensitive)
        store.nameOff[0] = 0; store.nameOff[1] = 0; store.parent[0] = 0
        store.sizeC[0] = 0; store.mtime[0] = 0; store.flags[0] = SiftFlag.dir
        store.depth[0] = 0; store.kind[0] = 1; store.altOff[0] = 0
        store.buildHash()
        return store
    }

    private func persistenceStore() -> IndexStore {
        let store = IndexStore(rootPath: "/", count: 3, namesLen: 2, altCount: 2, altLen: 2,
                               fingerprint: 17, homeIndex: 1, finishedAt: 123)
        store.nameOff[0] = 0; store.nameOff[1] = 0; store.nameOff[2] = 1; store.nameOff[3] = 2
        store.parent[0] = 0; store.parent[1] = 0; store.parent[2] = 0
        store.sizeC[0] = 0; store.sizeC[1] = 1; store.sizeC[2] = 2
        store.mtime[0] = 0; store.mtime[1] = 1; store.mtime[2] = 2
        store.flags[0] = SiftFlag.dir; store.flags[1] = SiftFlag.dir; store.flags[2] = 0
        store.depth[0] = 0; store.depth[1] = 1; store.depth[2] = 1
        store.kind[0] = 1; store.kind[1] = 1; store.kind[2] = 0
        store.names[0] = 120; store.names[1] = 121
        store.altOff[0] = 0; store.altOff[1] = 1; store.altOff[2] = 2
        store.altOwner[0] = 1; store.altOwner[1] = 2
        store.altNames[0] = 97; store.altNames[1] = 98
        return store
    }

    private func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    private func put64(_ value: UInt64, at offset: Int, in data: inout Data) {
        for byte in 0..<8 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    func testT71PersistenceRejectsMalformedStructure() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("valid.idx")
            let store = persistenceStore()
            try store.save(to: url.path)
            let original = try Data(contentsOf: url)
            XCTAssertEqual(original[8], 3)
            XCTAssertNotNil(IndexStore.load(from: url.path))

            let count = 3, namesLen = 2, altCount = 2
            let nameOffStart = 257
            let parentStart = nameOffStart + (count + 1) * 4
            let namesStart = 256 + 1 + (count + 1) * 4 + count * 12 + count * 3
            let kindStart = namesStart - count
            let altOffStart = namesStart + namesLen
            let altOwnerStart = altOffStart + (altCount + 1) * 4

            func rejects(_ label: String, _ mutate: (inout Data) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
                var damaged = original
                mutate(&damaged)
                try damaged.write(to: url)
                XCTAssertNil(IndexStore.load(from: url.path), label, file: file, line: line)
            }

            try rejects("nameOff[0] must be zero") { data in self.put32(1, at: nameOffStart, in: &data) }
            try rejects("nameOff must be monotone") { data in
                self.put32(1, at: nameOffStart + 4, in: &data)
                self.put32(0, at: nameOffStart + 2 * 4, in: &data)
            }
            try rejects("parent[0] must be zero") { data in self.put32(1, at: parentStart, in: &data) }
            try rejects("each non-root parent must precede its child") { data in self.put32(1, at: parentStart + 4, in: &data) }
            try rejects("parent[1] must not be UInt32.max") { data in self.put32(UInt32.max, at: parentStart + 4, in: &data) }
            try rejects("altOff[0] must be zero") { data in self.put32(1, at: altOffStart, in: &data) }
            try rejects("altOff must be monotone") { data in self.put32(3, at: altOffStart + 4, in: &data) }
            try rejects("altOwner must be within count") { data in self.put32(3, at: altOwnerStart, in: &data) }
            try rejects("altOwner must be monotone") { data in
                self.put32(2, at: altOwnerStart, in: &data); self.put32(1, at: altOwnerStart + 4, in: &data)
            }
            try rejects("homeIndex must be valid") { data in self.put32(3, at: 104, in: &data) }
            try rejects("deletedCount must not exceed count") { data in self.put32(4, at: 108, in: &data) }
            try rejects("kind must be in the supported range") { data in data[kindStart + 2] = 9 }
            try rejects("case sensitivity byte must be 0 or 1") { data in data[112] = 2 }
            try rejects("name length must convert to Int safely") { data in self.put64(UInt64.max, at: 16, in: &data) }
            try rejects("alternate name length must convert to Int safely") { data in self.put64(UInt64.max, at: 32, in: &data) }
            try rejects("format version 1 must be rebuilt") { data in self.put32(1, at: 8, in: &data) }
        }
    }

    func testT76PackageExtensionsUseFullCaseFoldedBytes() {
        for ext in Classifier.packages {
            XCTAssertNotEqual(packageFlags("folder.\(ext)") & SiftFlag.package, 0, ext)
        }
        for ext in ["ramework", "enstudio", "app2", "ap"] {
            XCTAssertEqual(packageFlags("folder.\(ext)") & SiftFlag.package, 0, ext)
        }
        XCTAssertNotEqual(packageFlags("folder.FrameWork") & SiftFlag.package, 0)
        XCTAssertEqual(packageFlags("folder.app", type: 0) & SiftFlag.package, 0)
        for ext in ["pages", "numbers", "key"] {
            XCTAssertNotEqual(packageFlags("folder.\(ext)", type: 1) & SiftFlag.package, 0)
            XCTAssertEqual(packageFlags("file.\(ext)", type: 0) & SiftFlag.package, 0)
        }
        let appName = Array("Example.APP".utf8)
        let appFlags = appName.withUnsafeBufferPointer { Classifier.flags(name: $0, type: 1, bsdFlags: 0, inherited: 0) }
        XCTAssertEqual(appName.withUnsafeBufferPointer { Classifier.kind(name: $0, flags: appFlags) }, 2)
    }

    func testT78CaseSensitiveLookupAndPersistence() throws {
        let sensitive = emptyStore(caseSensitive: true)
        var lower: UInt32 = 0, upper: UInt32 = 0
        Array("a.txt".utf8).withUnsafeBufferPointer { lower = sensitive.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
        Array("A.txt".utf8).withUnsafeBufferPointer { upper = sensitive.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
        XCTAssertNotEqual(lower, upper)
        XCTAssertEqual(sensitive.resolve(path: "/a.txt"), lower)
        XCTAssertEqual(sensitive.resolve(path: "/A.txt"), upper)
        sensitive.write { _ = sensitive.remove(lower); sensitive.sweep() }
        XCTAssertNil(sensitive.resolve(path: "/a.txt"))
        XCTAssertEqual(sensitive.resolve(path: "/A.txt"), upper)

        let insensitive = emptyStore(caseSensitive: false)
        var existing: UInt32 = 0
        Array("a.txt".utf8).withUnsafeBufferPointer { existing = insensitive.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
        XCTAssertEqual(insensitive.resolve(path: "/A.txt"), existing)

        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("sensitive.idx")
            try sensitive.save(to: url.path)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(bytes[112], 1)
            XCTAssertEqual(try XCTUnwrap(IndexStore.load(from: url.path)).caseSensitiveNames, true)
        }
    }

    func testT80ScannerCancellationIsStickyAndResponsive() throws {
        try skipIfCI("Scanner cancellation responsiveness depends on host scheduling.")
        try withTempDirectory { root in
            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let preCancelled = Scanner(config: config, threads: 2)
            preCancelled.cancel()
            XCTAssertNil(preCancelled.run())
            XCTAssertNil(preCancelled.run())

            let fm = FileManager.default
            for directory in 0..<80 {
                let folder = root.appendingPathComponent("d\(directory)")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in 0..<80 {
                    try Data().write(to: folder.appendingPathComponent("f\(file).txt"))
                }
            }
            let scanner = Scanner(config: config, threads: 2)
            let done = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var result: ScanOutput?
            DispatchQueue.global().async {
                let output = scanner.run()
                resultLock.lock(); result = output; resultLock.unlock()
                done.signal()
            }
            let progressDeadline = Date().addingTimeInterval(2)
            while scanner.scannedCount <= 1 && Date() < progressDeadline { Thread.sleep(forTimeInterval: 0.002) }
            XCTAssertGreaterThan(scanner.scannedCount, 1, "scanner should have started reading batches")
            scanner.cancel()
            XCTAssertEqual(done.wait(timeout: .now() + 1), .success, "cancelled scan should finish within one second")
            resultLock.lock(); let output = result; resultLock.unlock()
            XCTAssertNil(output)
            XCTAssertNil(scanner.run(), "a Scanner instance may run only once")
        }
    }

    func testT81ScannerDoesNotFollowSymlinkDirectories() throws {
        try withTempDirectory { container in
            let ancestor = container.appendingPathComponent("ancestor")
            let root = ancestor.appendingPathComponent("root")
            let outside = container.appendingPathComponent("outside")
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("ancestor".utf8).write(to: ancestor.appendingPathComponent("ancestor-only.txt"))
            try Data("outside".utf8).write(to: outside.appendingPathComponent("outside-only.txt"))
            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let initialOutput = try XCTUnwrap(Scanner(config: config, threads: 2).run())
            let indexed = IndexStore(scan: initialOutput, config: config)
            indexed.write { indexed.buildHash() }

            let added = root.appendingPathComponent("newdir")
            try fm.createDirectory(at: added, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: added.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
            try fm.createSymbolicLink(atPath: added.appendingPathComponent("ancestor-link").path, withDestinationPath: ancestor.path)
            _ = IndexUpdater(config: config).apply([FSChange(path: added.path, eventId: 1)], to: indexed)

            let scanner = Scanner(config: config, threads: 2)
            let output = try XCTUnwrap(scanner.run())
            let fullScan = IndexStore(scan: output, config: config)
            let paths = (0..<indexed.count).map { indexed.path(UInt32($0)) }
            let expected = (0..<fullScan.count).map { fullScan.path(UInt32($0)) }
            XCTAssertEqual(Set(paths), Set(expected), "subtree update must match a full scan")
            XCTAssertTrue(paths.contains(added.path + "/outside-link"))
            XCTAssertTrue(paths.contains(added.path + "/ancestor-link"))
            XCTAssertFalse(paths.contains { $0.hasPrefix(added.path + "/outside-link/") })
            XCTAssertFalse(paths.contains { $0.hasPrefix(added.path + "/ancestor-link/") })
            XCTAssertFalse(paths.contains { $0.hasSuffix("outside-only.txt") })
            XCTAssertFalse(paths.contains { $0.hasSuffix("ancestor-only.txt") })
            XCTAssertNil(scanner.run(), "a Scanner instance may run only once")
        }
    }

    func testT81ScannerRejectsSymlinkedIntermediateAncestor() throws {
        try withTempDirectory { container in
            let root = container.appendingPathComponent("root")
            let originalParent = root.appendingPathComponent("replace")
            let originalChild = originalParent.appendingPathComponent("child")
            let movedParent = container.appendingPathComponent("moved-replace")
            let external = container.appendingPathComponent("external")
            let targetChild = external.appendingPathComponent("child")
            let fm = FileManager.default
            try fm.createDirectory(at: originalChild, withIntermediateDirectories: true)
            try fm.createDirectory(at: targetChild, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: originalChild.appendingPathComponent("original-only.txt"))
            try Data("external".utf8).write(to: targetChild.appendingPathComponent("external-only.txt"))

            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let scanner = Scanner(config: config, threads: 1)
            var hookFired = false
            var hookError: Error?
            scanner.installDirectoryOpenHook { relativePath in
                guard relativePath == "replace/child" else { return }
                hookFired = true
                do {
                    try fm.moveItem(at: originalParent, to: movedParent)
                    try fm.createSymbolicLink(atPath: originalParent.path, withDestinationPath: external.path)
                } catch { hookError = error }
            }
            let output = try XCTUnwrap(scanner.run())
            XCTAssertTrue(hookFired, "scanner hook should run immediately before opening the queued descendant")
            XCTAssertNil(hookError)
            let store = IndexStore(scan: output, config: config)
            let paths = (0..<store.count).map { store.path(UInt32($0)) }
            XCTAssertFalse(paths.contains { $0.hasSuffix("external-only.txt") })
        }
    }

    func testT81UpdaterRejectsSymlinkedIntermediateAncestor() throws {
        try withTempDirectory { container in
            let root = container.appendingPathComponent("root")
            let originalParent = root.appendingPathComponent("replace")
            let target = container.appendingPathComponent("external")
            let eventRoot = originalParent.appendingPathComponent("newdir")
            let externalEventRoot = target.appendingPathComponent("newdir")
            let movedParent = container.appendingPathComponent("moved-replace")
            let fm = FileManager.default
            try fm.createDirectory(at: originalParent, withIntermediateDirectories: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            var config = IndexConfig.standard()
            config.rootPath = root.path
            config.indexSystemDirs = true
            let initialOutput = try XCTUnwrap(Scanner(config: config, threads: 1).run())
            let store = IndexStore(scan: initialOutput, config: config)
            store.write { store.buildHash() }

            try fm.createDirectory(at: eventRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: externalEventRoot, withIntermediateDirectories: true)
            try Data("external".utf8).write(to: externalEventRoot.appendingPathComponent("updater-target-only.txt"))
            let updater = IndexUpdater(config: config)
            var hookFired = false
            var hookError: Error?
            let eventPath = Array(eventRoot.path.utf8)
            updater.onSubtreeDirectoryOpen = { bytes in
                guard bytes.elementsEqual(eventPath) else { return }
                hookFired = true
                do {
                    try fm.moveItem(at: originalParent, to: movedParent)
                    try fm.createSymbolicLink(atPath: originalParent.path, withDestinationPath: target.path)
                } catch { hookError = error }
            }
            _ = updater.apply([FSChange(path: eventRoot.path, eventId: 1)], to: store)
            XCTAssertTrue(hookFired, "updater hook should run before resolving the subtree root")
            XCTAssertNil(hookError)
            XCTAssertFalse((0..<store.count).contains { store.name(UInt32($0)) == "updater-target-only.txt" })
        }
    }
}
