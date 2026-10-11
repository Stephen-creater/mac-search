import XCTest
import Foundation
import CMacSearch
@testable import MacSearchCore

final class M7SearchTests: XCTestCase {
    private func store(_ names: [String], mtime: UInt32 = 1_750_000_000) -> IndexStore {
        let records = names.map { Array($0.utf8) }
        let byteCount = records.reduce(0) { $0 + $1.count }
        let result = IndexStore(rootPath: "/", count: records.count + 1, namesLen: byteCount,
                                altCount: 0, altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0)
        result.nameOff[0] = 0; result.parent[0] = 0; result.flags[0] = SiftFlag.dir
        result.depth[0] = 0; result.kind[0] = 1; result.sizeC[0] = 0; result.mtime[0] = 0
        result.altOff[0] = 0
        var offset = 0
        for i in records.indices {
            let id = i + 1, bytes = records[i]
            result.nameOff[id] = UInt32(offset)
            bytes.withUnsafeBufferPointer { result.names.advanced(by: offset).update(from: $0.baseAddress!, count: $0.count) }
            offset += bytes.count
            result.parent[id] = 0; result.depth[id] = 1; result.kind[id] = 3
            result.sizeC[id] = IndexStore.encodeSize(UInt64(bytes.count)); result.mtime[id] = mtime
            result.flags[id] = SiftFlag.userArea
        }
        result.nameOff[records.count + 1] = UInt32(offset)
        return result
    }

    private func isPlainTextFallback(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let query = Query.parse(text, now: Date(timeIntervalSince1970: 1_780_000_000), home: "/")
        guard query.clauses.count == 1, query.clauses[0].alternatives.count == 1 else {
            XCTFail("Expected one plain-text atom for \(text)", file: file, line: line)
            return
        }
        let atom = query.clauses[0].alternatives[0]
        XCTAssertFalse(atom.negated, file: file, line: line)
        if case .name = atom.matcher { return }
        XCTFail("Expected plain-text matcher for \(text)", file: file, line: line)
    }

    func testT70InvalidNumericQueriesAndFixedSeedUnicodeFuzz() throws {
        let overflowSize = "size:18446744073709551615"
        let overflowRelativeDate = "dm:9223372036854775807w"
        let reversedDateRange = "dm:2026-12-01..2026-01-01"
        let clampedReversedDateRange = "dm:2200-12-01..2200-01-01"
        for text in [overflowSize, overflowRelativeDate, reversedDateRange, clampedReversedDateRange,
                     "size:1*", "dm:bad/", "foo:bar*", "dm:>2200", "dm:2026--01"] {
            isPlainTextFallback(text)
        }
        let local1970Start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 1970, month: 1, day: 1)))
        let beforeLocal1970 = local1970Start.addingTimeInterval(-1)
        if beforeLocal1970.timeIntervalSince1970 < 0 {
            isPlainTextFallback("dm:<1970")
        } else {
            let beforeQuery = Query.parse("dm:<1970", home: "/")
            guard beforeQuery.clauses.count == 1,
                  case .modified(let range) = beforeQuery.clauses[0].alternatives[0].matcher else {
                XCTFail("Expected the representable part of dm:<1970 to remain a date query")
                return
            }
            XCTAssertEqual(range.lowerBound, 0)
            XCTAssertEqual(range.upperBound, UInt32(beforeLocal1970.timeIntervalSince1970))
        }

        var seed: UInt64 = 0x8f3d_91a2_5c77_04e1
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return seed
        }
        func randomScalar() -> Unicode.Scalar {
            switch next() % 3 {
            case 0: return Unicode.Scalar(UInt32(next() % 0xD800))!
            case 1: return Unicode.Scalar(0xE000 + UInt32(next() % (0xFFFE - 0xE000)))!
            default: return Unicode.Scalar(0x10000 + UInt32(next() % (0x110000 - 0x10000)))!
            }
        }
        func randomUnicode(_ count: Int) -> String {
            var value = String.UnicodeScalarView()
            for _ in 0..<count { value.append(randomScalar()) }
            return String(value)
        }

        let prefixes = ["", "size:", "dm:", "ext:", "kind:", "file:", "folder:", "regex:", "path:", "case:", "!", "|", ">", "<"]
        let numericAndRangeParts = ["", "0", "18446744073709551615", "9223372036854775807w", "2026-12-01..2026-01-01", "..", ">", "<", "0..1", "1..0", "-1", "999999999999999999999999999999d"]
        let s = store(["readme.txt", "alpha.png", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX"])
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        for iteration in 0..<20_000 {
            let prefix = prefixes[Int(next() % UInt64(prefixes.count))]
            let body: String
            if iteration % 997 == 0 {
                body = String(repeating: "x", count: 8_192)
            } else if iteration % 5 == 0 {
                body = numericAndRangeParts[Int(next() % UInt64(numericAndRangeParts.count))]
            } else {
                body = randomUnicode(Int(next() % 33))
            }
            var token = prefix + body
            if iteration % 7 == 0 { token += ["..", ">", "<", "", "\"", "|", " "][Int(next() % 7)] }
            let query = Query.parse(token, now: now, home: "/")
            XCTAssertNotNil(Searcher.search(query, in: s), "iteration=\(iteration)")
        }
    }

    func testT72RegexCancellationAndPerEntryBudget() throws {
        try skipIfCI("Regex cancellation and per-entry latency limits depend on host scheduling.")
        let pathologicalName = String(repeating: "a", count: 30) + "X"
        let cancelledStore = store(Array(repeating: pathologicalName, count: 16))
        let query = Query.parse("regex:^(a+)+$")
        let start = DispatchTime.now().uptimeNanoseconds
        let cancelled = Searcher.search(query, in: cancelledStore, isCancelled: {
            DispatchTime.now().uptimeNanoseconds &- start >= 50_000_000
        })
        let cancellationMs = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        XCTAssertNil(cancelled)
        XCTAssertLessThan(cancellationMs, 300)
        print("T72 cancellation elapsed: \(cancellationMs) ms")

        let callbackLock = NSLock()
        var callbackCount = 0
        let oneShotCancelled = Searcher.search(query, in: cancelledStore, isCancelled: {
            callbackLock.lock(); defer { callbackLock.unlock() }
            callbackCount += 1
            return callbackCount == 2
        })
        XCTAssertNil(oneShotCancelled, "An observed one-shot cancellation must remain latched for the whole search")

        let uncancelledStore = store([pathologicalName])
        let uncancelledStart = DispatchTime.now().uptimeNanoseconds
        let result = try XCTUnwrap(Searcher.search(query, in: uncancelledStore))
        let budgetMs = Double(DispatchTime.now().uptimeNanoseconds &- uncancelledStart) / 1_000_000
        XCTAssertEqual(result.total, 0)
        XCTAssertLessThan(budgetMs, 1_000)
        print("T72 uncancelled budget elapsed: \(budgetMs) ms")

        let negated = try XCTUnwrap(Searcher.search(Query.parse("!regex:^(a+)+$"), in: uncancelledStore))
        XCTAssertEqual(negated.total, 0, "A timed-out regex entry is skipped even for a negated matcher")
    }

    func testT77TimeDependentQueryCacheAndPreviousResultFreshness() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let lateNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 59)))
        let nextMorning = try XCTUnwrap(calendar.date(byAdding: .minute, value: 2, to: lateNight))
        let text = "readme dm:today"
        let queryAtLateNight = Query.parse(text, now: lateNight, home: "/")
        let queryNextMorning = Query.parse(text, now: nextMorning, home: "/")
        XCTAssertTrue(queryAtLateNight.isTimeDependent)
        XCTAssertTrue(queryNextMorning.isTimeDependent)

        let s = store(["readme.txt"], mtime: UInt32(lateNight.timeIntervalSince1970))
        let oldResult = try XCTUnwrap(Searcher.search(queryAtLateNight, in: s))
        XCTAssertEqual(oldResult.total, 1)
        let refreshed = try XCTUnwrap(Searcher.search(queryNextMorning, in: s, previous: oldResult))
        XCTAssertFalse(refreshed.isNarrowed)
        XCTAssertEqual(refreshed.total, 0)
        XCTAssertEqual(refreshed.total, Searcher.search(queryNextMorning, in: s)!.total)

        var clockNow = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = SearchCache(clock: { clockNow })
        cache.insert(oldResult)
        XCTAssertNil(cache.lookup(query: queryAtLateNight, options: .init(), store: s))
        XCTAssertNil(cache.lookup(query: queryNextMorning, options: .init(), store: s))

        let staticQuery = Query.parse("readme", home: "/")
        let staticResult = try XCTUnwrap(Searcher.search(staticQuery, in: s))
        cache.insert(staticResult)
        XCTAssertTrue(cache.lookup(query: staticQuery, options: .init(), store: s) === staticResult)
        clockNow.addTimeInterval(600)
        XCTAssertTrue(cache.lookup(query: staticQuery, options: .init(), store: s) === staticResult)
        clockNow.addTimeInterval(0.001)
        XCTAssertNil(cache.lookup(query: staticQuery, options: .init(), store: s))
    }
}
