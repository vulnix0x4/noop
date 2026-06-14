import XCTest
@testable import StrandImport

final class CSVParsingTests: XCTestCase {

    func testDoubleParsesCommaDecimalLocaleValues() {
        // European WHOOP exports use a DECIMAL COMMA; blanket comma-deletion mangled these 10x
        // ("68,4" -> 684). The parser must read them as the intended fractional values.
        XCTAssertEqual(["v": "68,4"].double("v"), 68.4)      // HRV
        XCTAssertEqual(["v": "33,1"].double("v"), 33.1)      // skin temp
        XCTAssertEqual(["v": "12,5"].double("v"), 12.5)      // day strain
        XCTAssertEqual(["v": "96,0"].double("v"), 96.0)      // blood oxygen
        XCTAssertEqual(["v": "0,95"].double("v"), 0.95)      // two-decimal fraction
        XCTAssertEqual(["v": "2.450,5"].double("v"), 2450.5) // European grouping + decimal
    }

    func testDoubleStillHandlesThousandsAndUSGrouping() {
        // A comma used as a thousands separator must still collapse to the integer, not a decimal,
        // and US "1,234.56" grouping must parse to 1234.56 — so the comma-aware path is no regression.
        XCTAssertEqual(["v": "1,234"].double("v"), 1234)
        XCTAssertEqual(["v": "1,234,567"].double("v"), 1_234_567)
        XCTAssertEqual(["v": "1,234.56"].double("v"), 1234.56)
        XCTAssertEqual(["v": "12.5"].double("v"), 12.5)      // plain dot-decimal (the common export)
    }

    func testDoubleToleratesStrayUnits() {
        XCTAssertEqual(["v": "62 ms"].double("v"), 62)
        XCTAssertEqual(["v": "62,5 ms"].double("v"), 62.5)   // decimal comma + unit
        XCTAssertNil(["v": ""].double("v"))
        XCTAssertNil(["v": "n/a"].double("v"))
    }
}
