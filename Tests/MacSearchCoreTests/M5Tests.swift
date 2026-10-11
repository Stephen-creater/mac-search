import XCTest
import Foundation
import CMacSearch
@testable import MacSearchCore

final class M5Tests: XCTestCase {
    private func store(_ names: [String], copies: Int = 1) -> IndexStore {
        let records = names.map { Array($0.utf8) }
        let alternatives: [[[UInt8]]] = records.map { name in
            guard name.contains(where: { $0 >= 128 }) else { return [] }
            var full: [UInt8] = [], initials: [UInt8] = []
            if name.withUnsafeBufferPointer({ Pinyin.shared.keys(for: $0, full: &full, initials: &initials) }) { return [full, initials] }
            let lower = Array(String(decoding: name, as: UTF8.self).lowercased().utf8)
            return lower == name ? [] : [lower]
        }
        let count = records.count * copies + 1
        let s = IndexStore(rootPath: "/", count: count, namesLen: copies * records.reduce(0) { $0 + $1.count },
                           altCount: copies * alternatives.reduce(0) { $0 + $1.count },
                           altLen: copies * alternatives.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } },
                           fingerprint: 0, homeIndex: .max, finishedAt: 0)
        s.nameOff[0] = 0; s.parent[0] = 0; s.flags[0] = SiftFlag.dir
        s.depth[0] = 0; s.kind[0] = 1; s.sizeC[0] = 0; s.mtime[0] = 0
        var offset = 0, alt = 0, altOffset = 0
        for i in 1..<count {
            let pattern = (i - 1) % records.count, bytes = records[pattern]
            s.nameOff[i] = UInt32(offset)
            bytes.withUnsafeBufferPointer { s.names.advanced(by: offset).update(from: $0.baseAddress!, count: bytes.count) }
            offset += bytes.count
            s.parent[i] = 0; s.depth[i] = UInt8(i % 20); s.kind[i] = names[pattern].hasSuffix(".md") ? 3 : 7
            s.sizeC[i] = UInt32(i); s.mtime[i] = i % 11 == 0 ? .max : 0
            s.flags[i] = i % 7 == 0 ? SiftFlag.noise : SiftFlag.userArea
            for key in alternatives[pattern] {
                s.altOff[alt] = UInt32(altOffset); s.altOwner[alt] = UInt32(i)
                key.withUnsafeBufferPointer { s.altNames.advanced(by: altOffset).update(from: $0.baseAddress!, count: key.count) }
                altOffset += key.count; alt += 1
            }
        }
        s.nameOff[count] = UInt32(offset); s.altOff[alt] = UInt32(altOffset)
        return s
    }

    private func same(_ a: SearchResult, _ b: SearchResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.items, b.items, file: file, line: line)
        XCTAssertEqual(a.scores, b.scores, file: file, line: line)
        XCTAssertEqual(a.total, b.total, file: file, line: line)
        XCTAssertEqual(a.sortedCount, b.sortedCount, file: file, line: line)
        XCTAssertEqual(a.items.count, a.total, file: file, line: line)
        XCTAssertEqual(a.storeVersion, b.storeVersion, file: file, line: line)
    }

    func testT60NarrowingMatchesFullSearch() throws {
        let s = store(["README.md", "readme.txt", "myreadme", "readme-node_modules", "replay", "abc", "abd",
                       "xml.swift", "xmw.txt", "项目文档.md", "项目文档备份.txt", "ÉCLAIR.md", "unrelated"])
        let sequences = [["r", "re", "rea", "read", "readm", "readme"], ["x", "xm", "xmw", "xmwd"],
                         ["re", "readme", "readme !node_modules"], ["readme", "readme ext:md"],
                         ["项目", "项目文", "项目文档"], ["ad", "readme"], ["r m", "re md"],
                         ["case:R", "case:READ"], ["r", "re ext:md|ext:txt"], ["zz", "zzz"]]
        for sort in [SortKey.relevance, .name, .modified, .size] {
            for ascending in [false, true] {
                for sequence in sequences {
                    var previous: SearchResult?
                    for text in sequence {
                        let q = Query.parse(text), opts = SearchOptions(sort: sort, ascending: ascending)
                        let narrowed = try XCTUnwrap(Searcher.search(q, options: opts, in: s, previous: previous))
                        same(narrowed, try XCTUnwrap(Searcher.search(q, options: opts, in: s)))
                        XCTAssertEqual(narrowed.isNarrowed, previous != nil, text)
                        previous = narrowed
                    }
                }
            }
        }
        let old = try XCTUnwrap(Searcher.search(Query.parse("r"), in: s))
        for sort in [SortKey.name, .modified, .size] {
            let opts = SearchOptions(sort: sort, ascending: true), q = Query.parse("readme")
            let changed = try XCTUnwrap(Searcher.search(q, options: opts, in: s, previous: old))
            XCTAssertTrue(changed.isNarrowed); same(changed, Searcher.search(q, options: opts, in: s)!)
        }
    }

    func testT60LargeResultsAndChunkBoundaries() throws {
        let s = store(["readme.md", "README.txt", "my-readme", "mreadme-extra", "readmeMore", "replay", "r", "other"], copies: 40_001)
        s.write { s.flags[65_536] |= SiftFlag.deleted; s.flags[131_073] |= SiftFlag.deleted; s.deletedCount = 2; s.liveCount -= 2 }
        var previous = try XCTUnwrap(Searcher.search(Query.parse("r"), in: s))
        XCTAssertGreaterThan(previous.total, 200_000)
        for text in ["re", "read", "readme", "readme ext:md"] {
            let q = Query.parse(text)
            let narrowed = try XCTUnwrap(Searcher.search(q, in: s, previous: previous))
            same(narrowed, try XCTUnwrap(Searcher.search(q, in: s)))
            XCTAssertTrue(narrowed.isNarrowed)
            previous = narrowed
        }
        let opts = SearchOptions(sort: .size, ascending: true), q = Query.parse("re")
        let old = Searcher.search(Query.parse("r"), options: .init(sort: .name), in: s)!
        let narrowed = Searcher.search(q, options: opts, in: s, previous: old)!
        XCTAssertTrue(narrowed.isNarrowed); same(narrowed, Searcher.search(q, options: opts, in: s)!)
        XCTAssertNil(Searcher.search(q, in: s, previous: old, isCancelled: { true }))
        let lock = NSLock(); var checks = 0
        XCTAssertNil(Searcher.search(q, in: s, previous: old, isCancelled: {
            lock.lock(); defer { lock.unlock() }; checks += 1
            return checks == 3
        }))
    }

    func testT61UnsafePreviousFallsBack() throws {
        let s = store(["README.md", "readme.txt", "abc", "abd", "项目文档.md", "xml.swift"])
        func fallback(_ old: String, _ new: String, oldOptions: SearchOptions = .init(), options: SearchOptions = .init(), otherStore: IndexStore? = nil) throws {
            let previous = try XCTUnwrap(Searcher.search(Query.parse(old), options: oldOptions, in: otherStore ?? s))
            let q = Query.parse(new), result = try XCTUnwrap(Searcher.search(q, options: options, in: s, previous: previous))
            XCTAssertFalse(result.isNarrowed, "\(old) -> \(new)")
            same(result, try XCTUnwrap(Searcher.search(q, options: options, in: s)))
        }
        for (old, new) in [("!abc", "readme"), ("r !abc", "re !abc"), ("r|abc", "re"), ("r", "re|abc"),
                           ("*.md", "readme"), ("path:src/", "readme"), ("regex:^r", "re"),
                           ("file:r", "file:re"), ("folder:r", "folder:re"), ("r", "!re"), ("r", "*.md"),
                           ("abc", "abd"), ("r m", "re"), ("", "readme"), ("r", ""),
                           ("case:R", "readme"), ("case:R", "case:r"), ("r", "case:READ"), ("case:", "case:READ")] {
            try fallback(old, new)
        }
        try fallback("r", "re", options: .init(kind: 3))
        try fallback("r", "re", oldOptions: .init(kind: 3))
        try fallback("x", "xm", options: .init(pinyin: false))
        try fallback("x", "xm", oldOptions: .init(pinyin: false))
        try fallback("r", "re", otherStore: store(["readme.md"]))
        let old = try XCTUnwrap(Searcher.search(Query.parse("r"), in: s))
        s.write {
            s.buildHash()
            Array("fresh-readme.md".utf8).withUnsafeBufferPointer { _ = s.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0)) }
            s.version &+= 1
        }
        let q = Query.parse("readme"), result = try XCTUnwrap(Searcher.search(q, in: s, previous: old))
        XCTAssertFalse(result.isNarrowed); XCTAssertEqual(result.storeVersion, 1)
        same(result, Searcher.search(q, in: s)!)
        XCTAssertTrue(result.items.contains(UInt32(s.count - 1)))
        let unicode = store(["Éİ.txt"]), ascii = Searcher.search(Query.parse("i"), in: unicode)!
        XCTAssertEqual(ascii.total, 0)
        let mixed = Searcher.search(Query.parse("éi"), in: unicode, previous: ascii)!
        XCTAssertFalse(mixed.isNarrowed); XCTAssertEqual(mixed.total, 1)
        same(mixed, Searcher.search(Query.parse("éi"), in: unicode)!)
    }

    func testT62CacheKeysCapacityAndLRU() throws {
        let s = store(["readme.md", "readme.txt", "my-readme", "alpha", "alphabet", "beta", "betamax"])
        func result(_ text: String, _ opts: SearchOptions = .init()) -> SearchResult { Searcher.search(Query.parse(text), options: opts, in: s)! }
        func lookup(_ cache: SearchCache, _ text: String, _ opts: SearchOptions = .init(), _ target: IndexStore? = nil) -> SearchResult? {
            cache.lookup(query: Query.parse(text), options: opts, store: target ?? s)
        }
        let cache = SearchCache(maxEntries: 3, maxItems: 5), readme = result("readme"), alpha = result("alpha"), beta = result("beta")
        XCTAssertNil(lookup(cache, "readme")); cache.insert(readme)
        XCTAssertTrue(lookup(cache, "readme") === readme)
        for opts in [SearchOptions(sort: .name), .init(ascending: true), .init(kind: 3), .init(pinyin: false)] {
            XCTAssertNil(lookup(cache, "readme", opts))
        }
        XCTAssertNil(lookup(cache, "README")); XCTAssertNil(lookup(cache, "readme", .init(), store(["readme.md"])))
        cache.insert(alpha); _ = lookup(cache, "readme"); cache.insert(beta)
        XCTAssertNil(lookup(cache, "alpha")); XCTAssertTrue(lookup(cache, "readme") === readme); XCTAssertTrue(lookup(cache, "beta") === beta)
        cache.insert(result("a"))
        XCTAssertNil(lookup(cache, "a")); XCTAssertNotNil(lookup(cache, "readme"))
        cache.insert(readme); XCTAssertNotNil(lookup(cache, "beta"))
        s.write { s.version &+= 1 }
        XCTAssertNil(lookup(cache, "readme")); XCTAssertNil(lookup(cache, "beta"))
        cache.insert(readme); XCTAssertNil(lookup(cache, "readme"))
        let fresh = result("readme"); cache.insert(fresh); XCTAssertTrue(lookup(cache, "readme") === fresh)
        cache.removeAll(); XCTAssertNil(lookup(cache, "readme"))
        let bounded = SearchCache(maxEntries: 2, maxItems: 100)
        bounded.insert(result("readme")); bounded.insert(result("alpha")); _ = lookup(bounded, "readme"); bounded.insert(result("beta"))
        XCTAssertNil(lookup(bounded, "alpha")); XCTAssertNotNil(lookup(bounded, "readme")); XCTAssertNotNil(lookup(bounded, "beta"))
        let disabled = SearchCache(maxEntries: 0); disabled.insert(fresh); XCTAssertNil(lookup(disabled, "readme"))
        let noItems = SearchCache(maxItems: 0); noItems.insert(fresh); XCTAssertNil(lookup(noItems, "readme"))
        let empty = result("missing"); noItems.insert(empty); XCTAssertTrue(lookup(noItems, "missing") === empty)
    }

    func testT62ConcurrentCacheAccess() {
        let s = store(["readme.md", "alpha", "beta"]), cache = SearchCache()
        let results = ["readme", "alpha", "beta"].map { Searcher.search(Query.parse($0), in: s)! }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for j in 0..<200 {
                let r = results[(worker + j) % results.count]
                cache.insert(r)
                if let hit = cache.lookup(query: r.query, options: r.options, store: s) { XCTAssertTrue(hit === r) }
                if j % 31 == 0 { cache.removeAll() }
            }
        }
        cache.removeAll()
        for r in results { cache.insert(r); XCTAssertTrue(cache.lookup(query: r.query, options: r.options, store: s) === r) }
    }

    func testT63QualityAgainstOriginalFinder() {
        func original(_ name: [UInt8], _ needle: [UInt8], _ cs: Int32) -> Int32 {
            guard !needle.isEmpty, needle.count <= name.count else { return 0 }
            var from = 0, best: Int32 = 0
            while from <= name.count - needle.count {
                let p = name.withUnsafeBufferPointer { n in needle.withUnsafeBufferPointer { q in
                    Int(sift_find(n.baseAddress, n.count, from, q.baseAddress, q.count, cs))
                } }
                if p < 0 { break }
                var quality: Int32 = 1
                if p == 0 {
                    quality = 3
                    if needle.count == name.count || (name[needle.count] == 46 && !name.dropFirst(needle.count + 1).contains(46)) { quality = 4 }
                } else {
                    let a = name[p - 1], b = name[p]
                    let letterA = (65...90).contains(a) || (97...122).contains(a)
                    let letterB = (65...90).contains(b) || (97...122).contains(b)
                    if [32, 45, 95, 46, 40, 91, 43, 44].contains(a) ||
                       ((97...122).contains(a) && (65...90).contains(b)) || (a < 128 && b >= 128) ||
                       ((48...57).contains(a) && letterB) || ((48...57).contains(b) && letterA) { quality = 2 }
                }
                best = max(best, quality); if best >= 2 { break }; from = p + 1
            }
            return best
        }
        func check(_ name: [UInt8], _ needle: [UInt8], _ cs: Int32) {
            let actual = name.withUnsafeBufferPointer { n in needle.withUnsafeBufferPointer { q in sift_match_quality(n.baseAddress, n.count, q.baseAddress, q.count, cs) } }
            XCTAssertEqual(actual, original(name, needle, cs), "len=\(name.count) nlen=\(needle.count) cs=\(cs)")
        }
        var seed: UInt64 = 0x123456789abcdef
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 32) }
        let alphabet = Array("aaabBB._-+[, (123xyz".utf8) + [0xc3, 0xa9, 0xe9, 0xa1, 0xb9]
        for length in [0, 1, 2, 3, 16, 64, 65, 128, 257] {
            for nlen in [0, 1, 2, 3, 16, 64, 65] {
                for iteration in 0..<50 {
                    var name = (0..<length).map { _ in alphabet[Int(next()) % alphabet.count] }
                    let needle = (0..<nlen).map { _ in alphabet[Int(next()) % alphabet.count] }
                    if nlen <= length && nlen > 0 && iteration % 2 == 0 {
                        let position = Int(next()) % (length - nlen + 1)
                        for j in 0..<nlen { name[position + j] = needle[j] }
                    }
                    for cs: Int32 in [0, 1] {
                        let probe = cs == 0 ? needle.map { (65...90).contains($0) ? $0 + 32 : $0 } : needle
                        check(name, probe, cs)
                    }
                }
            }
        }
        for (name, needle) in [("README.md", "readme"), ("readme.a.b", "readme"), ("z-z-zreadme", "readme"),
                               ("myReadme", "readme"), ("v2Readme", "readme"), ("a项目", "项目"),
                               (String(repeating: "a", count: 70) + "-aaa", "aaa")] {
            check(Array(name.utf8), Array(needle.utf8), 0)
        }
    }
}
