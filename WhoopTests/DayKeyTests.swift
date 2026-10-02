import Foundation
import XCTest

@testable import Whoop

final class DayKeyTests: XCTestCase {
    func testStrictParsingRejectsMalformedAndImpossibleDays() {
        XCTAssertNil(DayKey(rawValue: "2026-9-01"))
        XCTAssertNil(DayKey(rawValue: "2026-02-29"))
        XCTAssertEqual(DayKey(rawValue: "2028-02-29")?.rawValue, "2028-02-29")
        XCTAssertNil(DayKey.date(from: "2026-9-01"))
        XCTAssertNil(DayKey.date(from: "2026-02-29"))
        XCTAssertNotNil(DayKey.date(from: "2028-02-29"))
    }

    func testFormattingUsesTheRequestedTimeZone() throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let toronto = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        XCTAssertEqual(DayKey.string(from: instant, timeZone: toronto), "2027-01-15")
        XCTAssertEqual(DayKey.string(from: instant, timeZone: tokyo), "2027-01-15")

        let nearMidnight = Date(timeIntervalSince1970: 1_800_025_200)
        XCTAssertEqual(DayKey.string(from: nearMidnight, timeZone: toronto), "2027-01-15")
        XCTAssertEqual(DayKey.string(from: nearMidnight, timeZone: tokyo), "2027-01-16")
    }

    func testDayGapIsStableAcrossLeapDay() {
        XCTAssertEqual(DayKey.dayGap(from: "2028-02-28", to: "2028-03-01"), 2)
        XCTAssertEqual(DayKey.dayGap(from: "2028-03-01", to: "2028-02-28"), -2)
    }

    func testDayKeyCodableUsesItsValidatedStringRepresentation() throws {
        let key = try XCTUnwrap(DayKey(rawValue: "2028-02-29"))
        let encoded = try JSONEncoder().encode(key)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"2028-02-29\"")
        XCTAssertEqual(try JSONDecoder().decode(DayKey.self, from: encoded), key)
        XCTAssertThrowsError(
            try JSONDecoder().decode(DayKey.self, from: Data("\"2028-02-30\"".utf8))
        )
    }
}
