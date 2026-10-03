import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore

final class ResponseMetadataParserTests: XCTestCase {
    func testRejectsInvalidTokenCountsIndependently() {
        let metadata = ResponseMetadataParser.parse(
            model: "reported-model",
            inputTokens: true,
            outputTokens: 2.5,
            totalTokens: NSNumber(value: UInt64.max),
            costUSD: nil
        )

        XCTAssertEqual(metadata, ResponseMetadata(detectedModel: "reported-model"))

        XCTAssertNil(ResponseMetadataParser.parse(
            model: nil,
            inputTokens: -1,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        ))
    }

    func testAcceptsZeroAndMaximumIntegerCounts() {
        let metadata = ResponseMetadataParser.parse(
            model: nil,
            inputTokens: 0,
            outputTokens: NSNumber(value: Int.max),
            totalTokens: Int.max,
            costUSD: nil
        )

        XCTAssertEqual(metadata, ResponseMetadata(inputTokens: 0, outputTokens: Int.max, totalTokens: Int.max))
    }

    func testPreservesIntegerCountsBeyondDoublePrecision() {
        let count: Int64 = 9_007_199_254_740_993
        let metadata = ResponseMetadataParser.parse(
            model: nil,
            inputTokens: NSNumber(value: count),
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        )

        XCTAssertEqual(metadata?.inputTokens, Int(exactly: count))
    }

    func testRejectsUnsignedCountJustAboveIntMax() {
        let count = UInt64(Int.max) + 1

        XCTAssertNil(ResponseMetadataParser.parse(
            model: nil,
            inputTokens: NSNumber(value: count),
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        ))
    }

    func testAcceptsOnlyIntegralInRangeFloatingPointCounts() {
        let metadata = ResponseMetadataParser.parse(
            model: nil,
            inputTokens: NSNumber(value: 42.0),
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        )

        XCTAssertEqual(metadata?.inputTokens, 42)

        for count in [42.5, Double.infinity, Double.nan, Double(Int.max)] {
            XCTAssertNil(ResponseMetadataParser.parse(
                model: nil,
                inputTokens: NSNumber(value: count),
                outputTokens: nil,
                totalTokens: nil,
                costUSD: nil
            ))
        }
    }

    func testPreservesDecimalIntegersAndRejectsPreciseFractionalCounts() {
        let integer = NSDecimalNumber(string: "9007199254740993")
        let metadata = ResponseMetadataParser.parse(
            model: nil,
            inputTokens: integer,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        )
        XCTAssertEqual(metadata?.inputTokens, 9_007_199_254_740_993)

        let fraction = NSDecimalNumber(string: "1.0000000000000000000000000001")
        XCTAssertNil(ResponseMetadataParser.parse(
            model: nil,
            inputTokens: fraction,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        ))
    }

    func testRejectsInvalidCostAndModelValues() {
        for cost in [NSNumber(value: true), NSNumber(value: -0.01), NSNumber(value: Double.infinity), NSNumber(value: Double.nan)] {
            XCTAssertEqual(ResponseMetadataParser.parse(
                model: "reported-model",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: cost
            ), ResponseMetadata(detectedModel: "reported-model"))
        }

        XCTAssertNil(ResponseMetadataParser.parse(
            model: "",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        ))
        XCTAssertNil(ResponseMetadataParser.parse(
            model: "reported\nmodel",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil
        ))
    }

    func testAcceptsFiniteNonnegativeCost() {
        let metadata = ResponseMetadataParser.parse(
            model: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: 0.125
        )

        XCTAssertEqual(metadata?.costUSD, 0.125)
    }
}
