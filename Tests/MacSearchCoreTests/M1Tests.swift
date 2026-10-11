import XCTest
import Foundation
import CMacSearch
@testable import MacSearchCore

final class M1Tests: XCTestCase {
    private struct Fixture {
        let root: URL, store: IndexStore
        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("MacSearchTests-\(UUID().uuidString)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let dirs = ["src", "docs", "node_modules", ".hiddenDir", "Demo.app/Contents", "empty", "项目", "src/deep"]
            for d in dirs { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
            var deep = "src/deep"
            for _ in 0..<12 { deep += "/level"; try fm.createDirectory(at: root.appendingPathComponent(deep), withIntermediateDirectories: true) }
            let files: [(String,String)] = [("README.md","readme"),("src/ReadMe.txt","readme"),("docs/report final.pdf","pdf"),("src/shared.txt","one"),("docs/shared.txt","two"),(".hidden","secret"),(".hiddenDir/secret.txt","secret"),("node_modules/readme.js","noise"),("Demo.app/Contents/Info.plist","app"),("项目/项目文档.md","han"),("cafe\u{301}.txt","nfd"),("photo10.jpg","img"),("photo2.jpg","img"),("src/known.bin",String(repeating:"x",count:1234)),("\(deep)/leaf.txt","leaf")]
            for (p,body) in files { try Data(body.utf8).write(to: root.appendingPathComponent(p)) }
            try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("README.md"))
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: root.appendingPathComponent("src/known.bin").path)
            var config = IndexConfig.standard(); config.rootPath = root.path
            config.indexDependencyDirs = true; config.indexPackageContents = true; config.indexSystemDirs = true
            guard let output = Scanner(config: config, threads: 2).run() else { throw NSError(domain:"scan",code:1) }
            store = IndexStore(scan: output, config: config)
        }
        func ids(_ query: String, _ options: SearchOptions = .init()) -> Set<String> {
            let result = Searcher.search(Query.parse(query, home: root.path), options: options, in: store)!
            return Set(result.items.map { store.path($0) })
        }
        func id(_ suffix: String) -> UInt32 { UInt32((0..<store.count).first { store.path(UInt32($0)).hasSuffix(suffix) }!) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func withFixture(_ body: (Fixture) throws -> Void) throws { let f = try Fixture(); defer { f.cleanup() }; try body(f) }
    private func find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0, cs: Int32 = 0) -> Int {
        hay.withUnsafeBufferPointer { h in needle.withUnsafeBufferPointer { n in Int(sift_find(h.baseAddress, h.count, from, n.baseAddress, n.count, cs)) } }
    }
    func testT1FindAgainstNaive() {
        var seed: UInt64 = 0x12345678
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 32) }
        for len in [1,2,3,15,16,17,33] {
            for position in [0,1,14,15,16,31,127-len] {
                var hay = (0..<127).map { _ in UInt8(97 + next() % 26) }
                let needle = (0..<len).map { _ in UInt8(97 + next() % 26) }
                for j in 0..<len { hay[position+j] = needle[j] }
                for from in [0, position, position+1] {
                    let expected = from <= hay.count-len ? ((from...(hay.count-len)).first { p in hay[p..<(p+len)].elementsEqual(needle) } ?? -1) : -1
                    XCTAssertEqual(find(hay,needle,from:from),expected)
                }
            }
        }
        XCTAssertEqual(find(Array("aBcDe".utf8),Array("bc".utf8)),1)
        XCTAssertEqual(find(Array("aBcDe".utf8),Array("bc".utf8),cs:1),-1)
        XCTAssertEqual(find(Array("abcdefgh".utf8),Array("zz".utf8)),-1)
    }
    func testT2ScanEntries() {
        let names = Array("abcaab".utf8); let off: [UInt32] = [0,2,4,6]
        var out = [UInt32](repeating:0,count:3), resume: UInt32 = 0
        let n = names.withUnsafeBufferPointer { b in off.withUnsafeBufferPointer { o in Array("bc".utf8).withUnsafeBufferPointer { p in sift_scan_entries(b.baseAddress,o.baseAddress,0,3,p.baseAddress,p.count,0,&out,3,&resume) } } }
        XCTAssertEqual(n,0); XCTAssertEqual(resume,3)
        let repeated = Array("aaaaaa".utf8), offsets: [UInt32] = [0,3,6]
        let n2 = repeated.withUnsafeBufferPointer { b in offsets.withUnsafeBufferPointer { o in Array("a".utf8).withUnsafeBufferPointer { p in sift_scan_entries(b.baseAddress,o.baseAddress,0,2,p.baseAddress,p.count,0,&out,1,&resume) } } }
        XCTAssertEqual(n2,1); XCTAssertEqual(out[0],0); XCTAssertEqual(resume,1)
        let n3 = repeated.withUnsafeBufferPointer { b in offsets.withUnsafeBufferPointer { o in Array("a".utf8).withUnsafeBufferPointer { p in sift_scan_entries(b.baseAddress,o.baseAddress,resume,2,p.baseAddress,p.count,0,&out,1,&resume) } } }
        XCTAssertEqual(n3,1); XCTAssertEqual(out[0],1); XCTAssertEqual(resume,2)
    }
    func testT3CMatchGlobCompare() {
        func quality(_ n:String,_ p:String) -> Int32 { let a=Array(n.utf8),b=Array(p.utf8); return a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in sift_match_quality(x.baseAddress,x.count,y.baseAddress,y.count,0) } } }
        XCTAssertEqual(quality("README.md","readme"),4)
        XCTAssertEqual(quality("readmeExtra","readme"),3)
        XCTAssertEqual(quality("my-readme","readme"),2)
        XCTAssertEqual(quality("myreadme","readme"),1)
        XCTAssertEqual(quality("other","readme"),0)
        XCTAssertEqual(quality("myReadme","readme"),2)
        XCTAssertEqual(quality("v2Readme","readme"),2)
        func glob(_ p:String,_ s:String)->Bool { let a=Array(p.utf8),b=Array(s.utf8); return a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in sift_glob_match(x.baseAddress,x.count,y.baseAddress,y.count,0) != 0 } } }
        XCTAssertTrue(glob("*.pdf","x.pdf")); XCTAssertTrue(glob("项?文*","项目文档.md")); XCTAssertFalse(glob("项?文","项目文档.md"))
        func compare(_ a:String,_ b:String)->Int32 { let x=Array(a.utf8),y=Array(b.utf8); return x.withUnsafeBufferPointer { p in y.withUnsafeBufferPointer { q in sift_name_compare(p.baseAddress,p.count,q.baseAddress,q.count) } } }
        XCTAssertLessThan(compare("file2","file10"),0)
    }
    func testT4ScanMatchesFileManager() throws { try withFixture { f in
        let fm=FileManager.default
        let enumerator=fm.enumerator(at:f.root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey],options:[] )!
        var expected=Set<String>([f.root.path])
        for case let url as URL in enumerator { expected.insert(url.path.replacingOccurrences(of: "/private/var/", with: "/var/").precomposedStringWithCanonicalMapping) }
        let actual=Set((0..<f.store.count).map { f.store.path(UInt32($0)) })
        XCTAssertEqual(actual,expected)
        for i in 1..<f.store.count {
            let path=f.store.path(UInt32(i)); let attrs=try fm.attributesOfItem(atPath:path)
            let isDir=attrs[.type] as? FileAttributeType == .typeDirectory
            XCTAssertEqual(f.store.flags[i] & SiftFlag.dir != 0,isDir,path)
            if !isDir && f.store.flags[i] & SiftFlag.symlink == 0 { XCTAssertEqual(f.store.size(UInt32(i)),UInt64(attrs[.size] as? Int ?? -1),path) }
            if let d=attrs[.modificationDate] as? Date { XCTAssertEqual(Int(f.store.mtime[i]),Int(d.timeIntervalSince1970),path) }
        }
    } }
    func testT5Invariants() throws { try withFixture { f in
        XCTAssertEqual(f.store.nameOff[f.store.count],UInt32(f.store.namesLen))
        for i in 1..<f.store.count {
            XCTAssertLessThan(f.store.parent[i],UInt32(i))
            XCTAssertLessThanOrEqual(f.store.nameOff[i],f.store.nameOff[i+1])
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.store.path(UInt32(i))) || f.store.flags[i] & SiftFlag.symlink != 0)
        }
    } }
    func testT6Flags() throws { try withFixture { f in
        XCTAssertNotEqual(f.store.flags[Int(f.id("/.hidden"))] & SiftFlag.hidden,0)
        XCTAssertNotEqual(f.store.flags[Int(f.id("/.hiddenDir/secret.txt"))] & SiftFlag.noise,0)
        XCTAssertNotEqual(f.store.flags[Int(f.id("/node_modules/readme.js"))] & SiftFlag.noise,0)
        XCTAssertNotEqual(f.store.flags[Int(f.id("/Demo.app/Contents/Info.plist"))] & SiftFlag.inPackage,0)
        XCTAssertNotEqual(f.store.flags[Int(f.id("/Demo.app"))] & SiftFlag.package,0)
        XCTAssertEqual(f.store.kind[Int(f.id("/Demo.app"))],2)
        XCTAssertNotEqual(f.store.flags[Int(f.id("/alias"))] & SiftFlag.symlink,0)
        let library = Array("Library".utf8), users = Array("Users".utf8)
        let inherited = library.withUnsafeBufferPointer { n in users.withUnsafeBufferPointer { p in Classifier.inheritedForChildren(dirFlags: SiftFlag.dir, dirName: n, dirDepth: 3, parentName: p, isHome: false) } }
        XCTAssertNotEqual(inherited & SiftFlag.noise,0)
    } }
    func testT7Persistence() throws { try withFixture { f in
        let db=f.root.appendingPathComponent("index.macsearch")
        try f.store.save(to:db.path)
        let loaded=try XCTUnwrap(IndexStore.load(from:db.path))
        XCTAssertEqual(loaded.count,f.store.count)
        XCTAssertEqual(loaded.namesLen,f.store.namesLen)
        XCTAssertEqual(loaded.altCount,f.store.altCount)
        for i in 0..<f.store.count { XCTAssertEqual(loaded.path(UInt32(i)),f.store.path(UInt32(i))); XCTAssertEqual(loaded.flags[i],f.store.flags[i]); XCTAssertEqual(loaded.sizeC[i],f.store.sizeC[i]); XCTAssertEqual(loaded.mtime[i],f.store.mtime[i]) }
        func same<T>(_ a: UnsafePointer<T>, _ b: UnsafePointer<T>, _ n: Int) -> Bool { memcmp(a,b,n*MemoryLayout<T>.stride) == 0 }
        XCTAssertTrue(same(loaded.nameOff,f.store.nameOff,f.store.count+1))
        XCTAssertTrue(same(loaded.parent,f.store.parent,f.store.count))
        XCTAssertTrue(same(loaded.sizeC,f.store.sizeC,f.store.count))
        XCTAssertTrue(same(loaded.mtime,f.store.mtime,f.store.count))
        XCTAssertTrue(same(loaded.flags,f.store.flags,f.store.count))
        XCTAssertTrue(same(loaded.depth,f.store.depth,f.store.count))
        XCTAssertTrue(same(loaded.kind,f.store.kind,f.store.count))
        XCTAssertTrue(same(loaded.names,f.store.names,f.store.namesLen))
        XCTAssertTrue(same(loaded.altOff,f.store.altOff,f.store.altCount+1))
        XCTAssertTrue(same(loaded.altOwner,f.store.altOwner,f.store.altCount))
        XCTAssertTrue(same(loaded.altNames,f.store.altNames,f.store.altLen))
        var data=try Data(contentsOf:db); let original=data; data.removeLast(); try data.write(to:db); XCTAssertNil(IndexStore.load(from:db.path))
        data=original
        data[0]=0; try data.write(to:db); XCTAssertNil(IndexStore.load(from:db.path))
    } }
    func testT8QueryParsing() {
        let q=Query.parse("\"report final\"|readme !node_modules")
        XCTAssertEqual(q.clauses.count,2); XCTAssertEqual(q.clauses[0].alternatives.count,2)
        XCTAssertTrue(q.clauses[1].alternatives[0].negated)
        for s in ["ext:pdf;docx","kind:image","file:","file:report","folder:","folder:src","size:>10mb","size:1mb..10mb","dm:today","dm:yesterday","dm:week","dm:month","dm:year","dm:7d","dm:12h","dm:2w","dm:2026","dm:2026-03","dm:2026-03-12","dm:>2026-03-12","dm:<2026-03-12","dm:2026-01-01..2026-06-30","path:src/","case:README","regex:^IMG_\\d+"] {
            let matcher = Query.parse(s).clauses[0].alternatives[0].matcher
            if case .name(_, let sensitive) = matcher, !sensitive { XCTFail("failed to parse \(s)") }
        }
        for s in ["foo:bar","size:abc","dm:not-a-date"] { if case .name = Query.parse(s).clauses[0].alternatives[0].matcher {} else { XCTFail("expected fallback \(s)") } }
    }
    func testT9SearchMatchers() throws { try withFixture { f in
        let all=(0..<f.store.count).map { f.store.path(UInt32($0)) }
        func isDirectory(_ path: String) -> Bool { ((try? FileManager.default.attributesOfItem(atPath:path)[.type]) as? FileAttributeType) == .typeDirectory }
        XCTAssertEqual(f.ids("readme"),Set(all.filter { ($0 as NSString).lastPathComponent.lowercased().contains("readme") }))
        XCTAssertEqual(f.ids("ext:pdf"),Set(all.filter { ($0 as NSString).pathExtension.lowercased() == "pdf" }))
        XCTAssertEqual(f.ids("kind:image"),Set(all.filter { ["jpg","png"].contains(($0 as NSString).pathExtension.lowercased()) }))
        XCTAssertEqual(f.ids("*.jpg"),Set(all.filter { $0.lowercased().hasSuffix(".jpg") }))
        XCTAssertEqual(f.ids("size:>1000b"),Set(all.filter { (try? FileManager.default.attributesOfItem(atPath:$0)[.size] as? Int) ?? 0 > 1000 && !$0.hasSuffix(".app") }))
        XCTAssertEqual(f.ids("case:README"),Set(all.filter { ($0 as NSString).lastPathComponent.contains("README") }))
        XCTAssertEqual(f.ids("regex:^photo[0-9]+"),Set(all.filter { ($0 as NSString).lastPathComponent.range(of:"^photo[0-9]+",options:.regularExpression) != nil }))
        for pattern in ["^photo?|^README", "^photos?", "^phot.*", "^photo{0,1}"] {
            // Construct the atom directly so the query's OR operator does not consume regex alternation.
            let regex = try NSRegularExpression(pattern: pattern)
            let query = Query(clauses: [Clause(alternatives: [Atom(negated: false, matcher: .regex(regex, onPath: false))])], raw: pattern)
            let result = Searcher.search(query, in: f.store)!
            let expected = all.filter { $0 != f.root.path && ($0 as NSString).lastPathComponent.range(of: pattern, options: .regularExpression) != nil }
            XCTAssertEqual(Set(result.items.map { f.store.path($0) }), Set(expected), pattern)
        }
        XCTAssertEqual(f.ids("path:src"),Set(all.filter { $0.split(separator:"/").contains { $0.lowercased().contains("src") } }))
        let dateFormatter=DateFormatter(); dateFormatter.dateFormat="yyyy-MM-dd"
        XCTAssertEqual(f.ids("dm:\(dateFormatter.string(from: Date(timeIntervalSince1970: 1_700_000_000)))"),Set([f.root.appendingPathComponent("src/known.bin").path]))
        XCTAssertEqual(f.ids("file:readme"),Set(all.filter { ($0 as NSString).lastPathComponent.lowercased().contains("readme") && !isDirectory($0) }))
        XCTAssertEqual(f.ids("folder:src"),Set(all.filter { ($0 as NSString).lastPathComponent.lowercased().contains("src") && isDirectory($0) }))
        XCTAssertEqual(f.ids("!ext:jpg"),Set(all.filter { $0 != f.root.path && ($0 as NSString).pathExtension.lowercased() != "jpg" }))
        XCTAssertEqual(f.ids("readme|shared"),Set(all.filter { path in ["readme","shared"].contains { term in (path as NSString).lastPathComponent.lowercased().contains(term) } }))
    } }
    func testT10Pinyin() throws { try withFixture { f in
        for q in ["xmwd","xiangmu","wendang"] { XCTAssertTrue(f.ids(q).contains(f.root.appendingPathComponent("项目/项目文档.md").path)) }
        XCTAssertFalse(f.ids("xmwd",SearchOptions(pinyin:false)).contains(f.root.appendingPathComponent("项目/项目文档.md").path))
    } }
    func testT11Sort() throws { try withFixture { f in
        for sort in [SortKey.relevance,.name,.modified,.size] {
            let r=Searcher.search(Query.parse("readme"),options:.init(sort:sort,ascending:sort == .name),in:f.store)!
            XCTAssertEqual(r.sortedCount,r.total)
            XCTAssertEqual(r.scores.count,sort == .relevance ? r.sortedCount : 0)
            for j in 1..<r.items.count {
                let a=r.items[j-1], b=r.items[j]
                switch sort {
                case .relevance: XCTAssertGreaterThanOrEqual(r.scores[j-1],r.scores[j])
                case .name:
                    let x=f.store.nameBytes(a), y=f.store.nameBytes(b)
                    XCTAssertLessThanOrEqual(sift_name_compare(x.baseAddress,x.count,y.baseAddress,y.count),0)
                case .modified: XCTAssertGreaterThanOrEqual(f.store.mtime[Int(a)],f.store.mtime[Int(b)])
                case .size: XCTAssertGreaterThanOrEqual(f.store.size(a),f.store.size(b))
                }
            }
        }
        let r=Searcher.search(Query.parse("readme"),in:f.store)!
        XCTAssertEqual(f.store.name(r.items[0]),"README.md")
        XCTAssertGreaterThan(r.scores[r.items.firstIndex(of:f.id("/README.md"))!],r.scores[r.items.firstIndex(of:f.id("/node_modules/readme.js"))!])
    } }
    func testT12Path() throws { try withFixture { f in
        XCTAssertTrue(f.ids("src/").contains(f.root.appendingPathComponent("src/known.bin").path))
        XCTAssertFalse(f.ids("src/").contains(f.root.appendingPathComponent("docs/shared.txt").path))
        XCTAssertTrue(f.ids("/src/Read").contains(f.root.appendingPathComponent("src/ReadMe.txt").path))
        XCTAssertTrue(f.ids("~/src/").contains(f.root.appendingPathComponent("src/known.bin").path))
    } }
    func testT13NFD() throws { try withFixture { f in XCTAssertTrue(f.ids("café").contains(f.root.appendingPathComponent("café.txt").path)) } }
    func testT14Empty() throws { try withFixture { f in
        f.store.write { for i in 1..<f.store.count { f.store.flags[i] |= SiftFlag.userArea } }
        let r=Searcher.search(Query.parse(""),in:f.store)!
        XCTAssertTrue(r.items.allSatisfy { id in let flags=f.store.flags[Int(id)]; return flags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) == 0 && f.store.kind[Int(id)] != 1 })
        for j in 1..<r.items.count { XCTAssertGreaterThanOrEqual(f.store.mtime[Int(r.items[j-1])],f.store.mtime[Int(r.items[j])]) }
    } }
    func testExcludedByteCacheTracksMutations() {
        var config = IndexConfig(excludedPaths: ["/one"])
        func excluded(_ path: String) -> Bool { Array(path.utf8).withUnsafeBufferPointer { config.isExcluded(path: $0) } }
        XCTAssertTrue(excluded("/one/child")); XCTAssertFalse(excluded("/one-more"))
        config.excludedPaths = ["/two"]
        config.userExcludedPaths.append("/three")
        XCTAssertFalse(excluded("/one")); XCTAssertTrue(excluded("/two")); XCTAssertTrue(excluded("/three/child"))
    }
    func testParallelHeapMergeAndAlignedScores() {
        let count = 262_146, bytes = Array("alpha.txt".utf8)
        let store = IndexStore(rootPath: "/", count: count, namesLen: (count-1)*bytes.count, altCount: 0, altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0)
        store.nameOff[0] = 0; store.parent[0] = 0; store.flags[0] = SiftFlag.dir
        store.depth[0] = 0; store.kind[0] = 1; store.sizeC[0] = 0; store.mtime[0] = 0; store.altOff[0] = 0
        for i in 1..<count {
            store.nameOff[i] = UInt32((i-1)*bytes.count)
            bytes.withUnsafeBufferPointer { store.names.advanced(by: (i-1)*bytes.count).update(from: $0.baseAddress!, count: bytes.count) }
            store.parent[i] = 0; store.depth[i] = 2; store.kind[i] = 3; store.sizeC[i] = UInt32(i)
            store.flags[i] = i % 7 == 0 ? SiftFlag.userArea : 0
            store.mtime[i] = i % 11 == 0 ? .max : 0
        }
        store.nameOff[count] = UInt32(store.namesLen)
        func score(_ id: UInt32) -> Int32 { 774 + (id % 7 == 0 ? 60 : 0) + (id % 11 == 0 ? 60 : 0) }
        let expected = (1..<count).map(UInt32.init).sorted { score($0) == score($1) ? $0 < $1 : score($0) > score($1) }
        let result = Searcher.search(Query.parse("a"), in: store)!
        XCTAssertEqual(result.total,count-1); XCTAssertEqual(result.sortedCount,5000)
        XCTAssertEqual(result.scores.count,5000)
        XCTAssertEqual(Array(result.items.prefix(5000)),Array(expected.prefix(5000)))
        XCTAssertEqual(result.scores,result.items.prefix(5000).map(score))
        XCTAssertEqual(Set(result.items).count,count-1)
        XCTAssertTrue(zip(result.items.dropFirst(5000),result.items.dropFirst(5001)).allSatisfy { $0 < $1 })
        let modified = Searcher.search(Query.parse("a"),options: .init(sort: .modified),in: store)!
        XCTAssertTrue(modified.scores.isEmpty)
        XCTAssertTrue(modified.items.prefix(5000).allSatisfy { store.mtime[Int($0)] == .max })
        store.write { for i in 150_001..<count { store.flags[i] |= SiftFlag.deleted } }
        let smaller = Searcher.search(Query.parse("a"), in: store)!
        let smallerExpected = expected.filter { $0 <= 150_000 }
        XCTAssertEqual(smaller.sortedCount,150_000)
        XCTAssertEqual(smaller.items,smallerExpected)
        XCTAssertEqual(smaller.scores,smaller.items.map(score))
        XCTAssertNil(Searcher.search(Query.parse("a"),in: store,isCancelled: { true }))
        let lock = NSLock(); var checks = 0
        XCTAssertNil(Searcher.search(Query.parse("a"),in: store,isCancelled: {
            lock.lock(); defer { lock.unlock() }; checks += 1
            return checks == 3
        }))
    }
    func testAltOwnersAcrossChunkBoundaries() {
        let count = 131_075
        let hanIDs: Set<UInt32> = [65_536,65_537,131_073]
        let ascii = Array("ascii.txt".utf8), han = Array("项目文档.md".utf8)
        let folded = Array("ÉABC.txt".utf8), unchanged = Array("caféABC.txt".utf8)
        var buffers = [ScanBuffer(),ScanBuffer()]
        for i in 1..<count {
            let id = UInt32(i)
            let bytes = hanIDs.contains(id) ? han : i == 1 ? folded : i == 2 ? unchanged : ascii
            bytes.withUnsafeBufferPointer { buffers[i % 2].append(id: id, parent: 0, size: 0, mtime: 0, flags: 0, depth: 1, kind: 3, name: $0) }
        }
        let store = IndexStore(scan: ScanOutput(buffers: buffers, count: count, homeIndex: .max, elapsed: 0, finishedAt: 0),config: IndexConfig())
        XCTAssertEqual(store.altCount,7)
        for i in 1..<store.altCount { XCTAssertLessThanOrEqual(store.altOwner[i-1],store.altOwner[i]) }
        let result = Searcher.search(Query.parse("xmwd|xiangmu"),in: store)!
        XCTAssertEqual(Set(result.items),hanIDs); XCTAssertEqual(result.total,hanIDs.count)
        XCTAssertEqual(Searcher.search(Query.parse("ascii|xmwd"),in: store)!.total,count-3)
        XCTAssertEqual(Set(Searcher.search(Query.parse("éabc"),options: .init(pinyin: false),in: store)!.items),[1,2])
    }
}
