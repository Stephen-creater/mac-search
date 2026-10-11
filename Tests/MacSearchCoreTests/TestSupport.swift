import Foundation
import XCTest

extension XCTestCase {
    func skipIfCI(_ reason: String) throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip(reason)
        }
    }
}
